# src/mcp/server.cr
require "http/server"

module MCP
  alias ToolReturn = String | ContentBlock | Array(ContentBlock) | CallToolResult
  alias ResourceReturn = String | TextResourceContents | BlobResourceContents | Array(ResourceContents) | ReadResourceResult
  alias PromptReturn = String | PromptMessage | Array(PromptMessage) | GetPromptResult
  alias CompleteReturn = Array(String) | CompleteResult

  class Server
    alias ToolHandler = Proc(Hash(String, JSON::Any), RequestContext, ToolReturn)
    alias ResourceHandler = Proc(RequestContext, ResourceReturn)
    alias TemplateHandler = Proc(Hash(String, String), RequestContext, ResourceReturn)
    alias PromptHandler = Proc(Hash(String, String), RequestContext, PromptReturn)
    alias CompleteHandler = Proc(CompleteParams, RequestContext, CompleteReturn)

    DEFAULT_PAGE_SIZE = 100

    private struct ToolEntry
      getter definition : Tool
      getter handler : ToolHandler

      def initialize(@definition : Tool, @handler : ToolHandler)
      end
    end

    private struct ResourceEntry
      getter definition : Resource
      getter handler : ResourceHandler

      def initialize(@definition : Resource, @handler : ResourceHandler)
      end
    end

    private struct TemplateEntry
      getter definition : ResourceTemplate
      getter variables : Array(String)
      getter pattern : Regex
      getter handler : TemplateHandler

      def initialize(@definition : ResourceTemplate, @handler : TemplateHandler)
        variables = [] of String
        source = Regex.escape(@definition.uri_template).gsub(/\\\{([a-zA-Z_][a-zA-Z0-9_]*)\\\}/) do |_|
          variables << $1
          "([^/]+)"
        end
        @variables = variables
        @pattern = Regex.new("\\A#{source}\\z")
      end

      def match(uri : String) : Hash(String, String)?
        m = @pattern.match(uri)
        return nil unless m
        result = Hash(String, String).new
        @variables.each_with_index do |name, index|
          result[name] = m[index + 1]
        end
        result
      end
    end

    private struct PromptEntry
      getter definition : Prompt
      getter handler : PromptHandler

      def initialize(@definition : Prompt, @handler : PromptHandler)
      end
    end

    private struct ServerSubscription
      getter session : Session
      getter id : RequestId
      getter filter : SubscriptionFilter
      getter inbound : InboundRequest

      def initialize(@session : Session, @id : RequestId, @filter : SubscriptionFilter, @inbound : InboundRequest)
      end
    end

    getter info : Implementation
    getter instructions : String?
    getter protocol_version : String
    getter page_size : Int32

    @tools = Hash(String, ToolEntry).new
    @resources = Hash(String, ResourceEntry).new
    @templates = [] of TemplateEntry
    @prompts = Hash(String, PromptEntry).new
    @complete_handler : CompleteHandler?
    @sessions = [] of Session
    @sessions_mutex = Mutex.new
    @subscriptions = Hash(Tuple(Session, RequestId), ServerSubscription).new
    @subscriptions_mutex = Mutex.new
    @http_sessions = Hash(String, Session).new
    @http_mutex = Mutex.new
    @anonymous_http_session : Session?
    @anonymous_http_session_id : String?

    def initialize(@info : Implementation, @instructions : String? = nil,
                   @protocol_version : String = PROTOCOL_VERSION, @page_size : Int32 = DEFAULT_PAGE_SIZE)
    end

    def tool(name : String, description : String? = nil, input_schema = nil,
             output_schema = nil, annotations : ToolAnnotations? = nil, title : String? = nil,
             icons : Array(Icon)? = nil, &handler : ToolHandler) : Nil
      definition = Tool.new(name: name,
        input_schema: schema_hash(input_schema) || default_input_schema,
        output_schema: schema_hash(output_schema), description: description,
        annotations: annotations, title: title, icons: icons)
      @tools[name] = ToolEntry.new(definition, handler)
    end

    def resource(uri : String, name : String, mime_type : String? = nil, description : String? = nil,
                 title : String? = nil, size : Int64? = nil, annotations : Annotations? = nil,
                 icons : Array(Icon)? = nil, &handler : ResourceHandler) : Nil
      definition = Resource.new(uri: uri, name: name, title: title, description: description,
        mime_type: mime_type, size: size, annotations: annotations, icons: icons)
      @resources[uri] = ResourceEntry.new(definition, handler)
    end

    def resource_template(uri_template : String, name : String, mime_type : String? = nil,
                          description : String? = nil, title : String? = nil,
                          annotations : Annotations? = nil, icons : Array(Icon)? = nil,
                          &handler : TemplateHandler) : Nil
      definition = ResourceTemplate.new(uri_template: uri_template, name: name, title: title,
        description: description, mime_type: mime_type, annotations: annotations, icons: icons)
      @templates << TemplateEntry.new(definition, handler)
    end

    def prompt(name : String, description : String? = nil, arguments : Array(PromptArgument)? = nil,
               title : String? = nil, icons : Array(Icon)? = nil, &handler : PromptHandler) : Nil
      definition = Prompt.new(name: name, title: title, description: description,
        arguments: arguments, icons: icons)
      @prompts[name] = PromptEntry.new(definition, handler)
    end

    def on_complete(&handler : CompleteHandler) : Nil
      @complete_handler = handler
    end

    def run_stdio(input : IO = STDIN, output : IO = STDOUT) : Nil
      serve(StdioServerTransport.new(input, output))
    end

    def serve(transport : Transport) : Session
      session = Session.new(transport)
      attach(session)
      session.on_close { remove_session(session) }
      @sessions_mutex.synchronize { @sessions << session }
      session.run
      session
    end

    def open_session(transport : Transport) : Session
      session = Session.new(transport)
      attach(session)
      session.on_close { remove_session(session) }
      @sessions_mutex.synchronize { @sessions << session }
      spawn session.run
      session
    end

    def notify_tool_list_changed : Nil
      broadcast(Methods::NOTIF_TOOLS_CHANGED, ->(f : SubscriptionFilter) { f.tools_list_changed == true })
    end

    def notify_prompt_list_changed : Nil
      broadcast(Methods::NOTIF_PROMPTS_CHANGED, ->(f : SubscriptionFilter) { f.prompts_list_changed == true })
    end

    def notify_resource_list_changed : Nil
      broadcast(Methods::NOTIF_RESOURCES_CHANGED, ->(f : SubscriptionFilter) { f.resources_list_changed == true })
    end

    def notify_resource_updated(uri : String) : Nil
      each_session do |session|
        begin
          delivered = false
          each_subscription(session) do |subscription|
            uris = subscription.filter.resource_subscriptions
            next unless uris && uris.includes?(uri)
            session.notify(Methods::NOTIF_RESOURCE_UPDATED,
              notification_params(uri: uri, subscription_id: subscription.id))
            delivered = true
          end
          unless delivered
            unless has_subscriptions?(session)
              session.notify(Methods::NOTIF_RESOURCE_UPDATED, notification_params(uri: uri))
            end
          end
        rescue RpcError
        end
      end
    end

    def log(level : LoggingLevel, data : JSON::Any, logger : String? = nil) : Nil
      each_session do |session|
        begin
          session.notify(Methods::NOTIF_MESSAGE, LoggingMessageParams.new(level: level, data: data, logger: logger))
        rescue RpcError
        end
      end
    end

    def log(level : LoggingLevel, message : String, logger : String? = nil) : Nil
      log(level, JSON::Any.new(message), logger)
    end

    def close : Nil
      each_session do |session|
        each_subscription(session) do |subscription|
          subscription.inbound.respond(SubscriptionsListenResult.new(
            meta: ResultMeta.new(server_info: @info, subscription_id: subscription.id)))
        rescue RpcError
        end
        session.close
      end
      @subscriptions_mutex.synchronize { @subscriptions.clear }
    end

    private def attach(session : Session) : Nil
      session.request_filter = ->check_request(Envelope)

      session.on_request(Methods::DISCOVER) do |request|
        request.params_as(DiscoverParams)
        MCP.to_any(DiscoverResult.new(capabilities: capabilities, instructions: @instructions,
          meta: ResultMeta.new(server_info: @info)))
      end

      session.on_request(Methods::LIST_TOOLS) do |request|
        params = request.params_as(PaginatedParams)
        page, next_cursor = paginate(@tools.values.map(&.definition), params.cursor)
        MCP.to_any(ListToolsResult.new(tools: page, next_cursor: next_cursor,
          meta: ResultMeta.new(server_info: @info)))
      end

      session.on_request(Methods::CALL_TOOL) do |request|
        params = request.params_as(CallToolParams)
        entry = @tools[params.name]?
        unless entry
          raise RpcError.new(ErrorCodes::INVALID_PARAMS, "unknown tool: #{params.name}")
        end
        result = entry.handler.call(params.arguments || Hash(String, JSON::Any).new, request.context)
        MCP.to_any(normalize_tool(result))
      end

      session.on_request(Methods::LIST_RESOURCES) do |request|
        params = request.params_as(PaginatedParams)
        page, next_cursor = paginate(@resources.values.map(&.definition), params.cursor)
        MCP.to_any(ListResourcesResult.new(resources: page, next_cursor: next_cursor,
          meta: ResultMeta.new(server_info: @info)))
      end

      session.on_request(Methods::LIST_RESOURCE_TEMPLATES) do |request|
        params = request.params_as(PaginatedParams)
        page, next_cursor = paginate(@templates.map(&.definition), params.cursor)
        MCP.to_any(ListResourceTemplatesResult.new(resource_templates: page, next_cursor: next_cursor,
          meta: ResultMeta.new(server_info: @info)))
      end

      session.on_request(Methods::READ_RESOURCE) do |request|
        params = request.params_as(ReadResourceParams)
        if entry = @resources[params.uri]?
          MCP.to_any(normalize_resource(params.uri, entry.definition.mime_type, entry.handler.call(request.context)))
        else
          matched : TemplateEntry? = nil
          variables : Hash(String, String)? = nil
          @templates.each do |template|
            if vars = template.match(params.uri)
              matched = template
              variables = vars
              break
            end
          end
          template = matched
          vars = variables
          unless template && vars
            raise RpcError.new(ErrorCodes::INVALID_PARAMS, "resource not found: #{params.uri}")
          end
          MCP.to_any(normalize_resource(params.uri, template.definition.mime_type, template.handler.call(vars, request.context)))
        end
      end

      session.on_request(Methods::LIST_PROMPTS) do |request|
        params = request.params_as(PaginatedParams)
        page, next_cursor = paginate(@prompts.values.map(&.definition), params.cursor)
        MCP.to_any(ListPromptsResult.new(prompts: page, next_cursor: next_cursor,
          meta: ResultMeta.new(server_info: @info)))
      end

      session.on_request(Methods::GET_PROMPT) do |request|
        params = request.params_as(GetPromptParams)
        entry = @prompts[params.name]?
        unless entry
          raise RpcError.new(ErrorCodes::INVALID_PARAMS, "unknown prompt: #{params.name}")
        end
        result = entry.handler.call(params.arguments || Hash(String, String).new, request.context)
        MCP.to_any(normalize_prompt(entry.definition, result))
      end

      session.on_request(Methods::COMPLETE) do |request|
        params = request.params_as(CompleteParams)
        handler = @complete_handler
        unless handler
          raise RpcError.new(ErrorCodes::METHOD_NOT_FOUND, "completions not supported")
        end
        case result = handler.call(params, request.context)
        in Array(String)
          MCP.to_any(CompleteResult.values(result))
        in CompleteResult
          MCP.to_any(result)
        end
      end

      session.on_request(Methods::LISTEN) do |request|
        params = request.params_as(SubscriptionsListenParams)
        request.defer!
        key = {session, request.id}
        subscription = ServerSubscription.new(session, request.id, params.notifications, request)
        @subscriptions_mutex.synchronize { @subscriptions[key] = subscription }
        session.notify(Methods::NOTIF_SUBS_ACKNOWLEDGED,
          SubscriptionsAcknowledgedParams.new(notifications: params.notifications,
            meta: NotificationMeta.new(subscription_id: request.id)))
        nil
      end

      session.on_notification(Methods::NOTIF_CANCELLED) do |_, params|
        next unless params
        begin
          cancelled = CancelledParams.from_json(params.to_json)
        rescue JSON::SerializableError
          next
        end
        end_subscription(session, cancelled.request_id)
      end
    end

    private def check_request(envelope : Envelope) : Nil
      params = envelope.params
      return unless params
      hash = params.as_h?
      return unless hash
      meta_value = hash["_meta"]?
      return unless meta_value
      meta = RequestMeta.from_json(meta_value.to_json)
      version = meta.protocol_version
      return unless version
      return if SUPPORTED_PROTOCOL_VERSIONS.includes?(version)
      raise RpcError.new(ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION,
        "unsupported protocol version: #{version}",
        MCP.to_any({requested: version, supported: SUPPORTED_PROTOCOL_VERSIONS}))
    rescue JSON::ParseException | JSON::SerializableError
    end

    def end_subscription(session : Session, id : RequestId) : Nil
      key = {session, id}
      subscription = @subscriptions_mutex.synchronize { @subscriptions.delete(key) }
      return unless subscription
      subscription.inbound.respond(SubscriptionsListenResult.new(
        meta: ResultMeta.new(server_info: @info, subscription_id: subscription.id)))
    end

    private def remove_session(session : Session) : Nil
      @sessions_mutex.synchronize { @sessions.delete(session) }
      @subscriptions_mutex.synchronize do
        @subscriptions.reject! { |key, _| key[0] == session }
      end
    end

    private def capabilities : ServerCapabilities
      ServerCapabilities.new(
        tools: @tools.empty? ? nil : ServerCapabilities::Tools.new(list_changed: true),
        resources: (@resources.empty? && @templates.empty?) ? nil : ServerCapabilities::Resources.new(list_changed: true, subscribe: true),
        prompts: @prompts.empty? ? nil : ServerCapabilities::Prompts.new(list_changed: true),
        completions: @complete_handler ? Hash(String, JSON::Any).new : nil,
        logging: Hash(String, JSON::Any).new)
    end

    private def normalize_tool(result : ToolReturn) : CallToolResult
      case result
      in CallToolResult      then result
      in String              then CallToolResult.text(result)
      in ContentBlock        then CallToolResult.new(content: [result])
      in Array(ContentBlock) then CallToolResult.new(content: result)
      end
    end

    private def normalize_resource(uri : String, mime_type : String?, result : ResourceReturn) : ReadResourceResult
      contents : Array(ResourceContents) = [] of ResourceContents
      case result
      in ReadResourceResult    then return result
      in String                then contents << TextResourceContents.new(uri: uri, text: result, mime_type: mime_type)
      in TextResourceContents  then contents << result
      in BlobResourceContents  then contents << result
      in Array(ResourceContents) then contents.concat(result)
      end
      ReadResourceResult.new(contents: contents)
    end

    private def normalize_prompt(definition : Prompt, result : PromptReturn) : GetPromptResult
      case result
      in GetPromptResult       then result
      in String                then GetPromptResult.new(messages: [PromptMessage.user(result)], description: definition.description)
      in PromptMessage         then GetPromptResult.new(messages: [result], description: definition.description)
      in Array(PromptMessage)  then GetPromptResult.new(messages: result, description: definition.description)
      end
    end

    private def paginate(items : Array(T), cursor : String?) : Tuple(Array(T), String?) forall T
      offset = 0
      if c = cursor
        offset = c.to_i?
        unless offset
          raise RpcError.new(ErrorCodes::INVALID_PARAMS, "invalid cursor: #{c}")
        end
      end
      slice = items[offset, @page_size]? || [] of T
      next_offset = offset + slice.size
      next_cursor = next_offset < items.size ? next_offset.to_s : nil
      {slice, next_cursor}
    end

    private def schema_hash(schema) : Hash(String, JSON::Any)?
      return nil if schema.nil?
      MCP.to_any(schema).as_h
    end

    private def default_input_schema : Hash(String, JSON::Any)
      JSON.parse(%({"type":"object"})).as_h
    end

    private def notification_params(uri : String? = nil, subscription_id : RequestId? = nil) : Hash(String, JSON::Any)
      meta = Hash(String, JSON::Any).new
      if id = subscription_id
        meta[META_SUBSCRIPTION_ID] = JSON.parse(id.to_json)
      end
      params = Hash(String, JSON::Any).new
      params["_meta"] = JSON.parse(meta.to_json) unless meta.empty?
      params["uri"] = JSON::Any.new(uri) if uri
      params
    end

    private def broadcast(method : String, matcher : SubscriptionFilter -> Bool) : Nil
      each_session do |session|
        begin
          delivered = false
          each_subscription(session) do |subscription|
            next unless matcher.call(subscription.filter)
            session.notify(method, notification_params(subscription_id: subscription.id))
            delivered = true
          end
          unless delivered
            unless has_subscriptions?(session)
              session.notify(method)
            end
          end
        rescue RpcError
        end
      end
    end

    private def each_session(& : Session ->) : Nil
      @sessions_mutex.synchronize { @sessions.dup }.each do |session|
        yield session
      end
    end

    private def each_subscription(session : Session, & : ServerSubscription ->) : Nil
      matching = @subscriptions_mutex.synchronize do
        @subscriptions.select { |key, _| key[0] == session }.values
      end
      matching.each do |subscription|
        yield subscription
      end
    end

    private def has_subscriptions?(session : Session) : Bool
      @subscriptions_mutex.synchronize do
        @subscriptions.any? { |key, _| key[0] == session }
      end
    end

    def run_http(host : String = "127.0.0.1", port : Int32 = 3000, path : String = "/mcp") : Nil
      http = HTTP::Server.new do |context|
        handle_http(context, path)
      end
      http.bind_tcp(host, port)
      STDERR.puts "crystal-mcp: listening on http://#{host}:#{port}#{path}" if ENV.has_key?("MCP_DEBUG")
      http.listen
    end

    private def handle_http(context : HTTP::Server::Context, path : String) : Nil
      request = context.request
      response = context.response
      unless request.path == path
        response.status = :not_found
        return
      end
      case request.method
      when "POST"   then handle_http_post(context)
      when "GET"    then handle_http_get(context)
      when "DELETE" then handle_http_delete(context)
      else
        response.status = :method_not_allowed
        response.headers["Allow"] = "POST, GET, DELETE"
      end
    end

    private def http_session(context : HTTP::Server::Context) : Tuple(String, Session)
      if id = context.request.headers["MCP-Session-Id"]?
        session = @http_mutex.synchronize { @http_sessions[id]? }
        unless session
          raise RpcError.new(ErrorCodes::INVALID_REQUEST, "unknown session: #{id}")
        end
        {id, session}
      else
        @http_mutex.synchronize do
          if existing = @anonymous_http_session
            return {@anonymous_http_session_id.not_nil!, existing}
          end
          id = UUID.random.to_s
          transport = HttpSessionTransport.new
          new_session = Session.new(transport)
          attach(new_session)
          new_session.on_close { remove_session(new_session) }
          @sessions_mutex.synchronize { @sessions << new_session }
          spawn new_session.run
          @http_sessions[id] = new_session
          @anonymous_http_session = new_session
          @anonymous_http_session_id = id
          {id, new_session}
        end
      end
    end

    private def handle_http_post(context : HTTP::Server::Context) : Nil
      response = context.response
      body = context.request.body.try(&.gets_to_end) || ""
      envelope : Envelope? = nil
      begin
        envelope = Envelope.parse(body)
      rescue JSON::ParseException
        respond_http_rpc_error(response, nil, ErrorCodes::PARSE_ERROR, "parse error")
        return
      end
      env = envelope.not_nil!
      resolved = begin
        http_session(context)
      rescue ex : RpcError
        response.status = :not_found
        respond_http_rpc_error(response, env.id, ex.code, ex.message || "unknown session")
        return
      end
      session_id, session = resolved
      transport = session.transport.as(HttpSessionTransport)
      response.headers["MCP-Session-Id"] = session_id.not_nil!
      if env.request?
        unless check_http_protocol_version(context, env)
          return
        end
        id = env.id.not_nil!
        if env.method == Methods::LISTEN
          accept = context.request.headers["Accept"]? || ""
          unless accept.includes?("text/event-stream")
            response.status = :bad_request
            respond_http_rpc_error(response, id, ErrorCodes::HEADER_MISMATCH,
              "subscriptions/listen requires Accept: text/event-stream")
            return
          end
          handle_http_listen(context, transport, id, body)
        else
          waiter = transport.register_waiter(id)
          begin
            transport.push_incoming(body)
            result_message = waiter.receive
            response.status = :ok
            response.content_type = "application/json"
            response.print(result_message)
          ensure
            transport.unregister_waiter(id)
          end
        end
      elsif env.notification? || env.response?
        transport.push_incoming(body)
        response.status = :accepted
      else
        response.status = :bad_request
        respond_http_rpc_error(response, nil, ErrorCodes::INVALID_REQUEST, "invalid JSON-RPC message")
      end
    end

    private def handle_http_listen(context : HTTP::Server::Context, transport : HttpSessionTransport,
                                   id : RequestId, body : String) : Nil
      response = context.response
      stream = transport.register_listen(id)
      transport.push_incoming(body)
      response.status = :ok
      response.content_type = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      begin
        loop do
          message = stream.receive?
          break if message.nil?
          SSE.write(response, message)
          if is_response_for?(message, id)
            break
          end
        end
      rescue IO::Error
      ensure
        transport.unregister_listen(id)
      end
    end

    private def handle_http_get(context : HTTP::Server::Context) : Nil
      response = context.response
      accept = context.request.headers["Accept"]? || ""
      unless accept.includes?("text/event-stream")
        response.status = :not_acceptable
        return
      end
      resolved = begin
        http_session(context)
      rescue RpcError
        response.status = :not_found
        return
      end
      session_id, session = resolved
      transport = session.transport.as(HttpSessionTransport)
      response.headers["MCP-Session-Id"] = session_id.not_nil!
      response.status = :ok
      response.content_type = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      stream = transport.add_get_stream
      begin
        loop do
          message = stream.receive?
          break if message.nil?
          SSE.write(response, message)
        end
      rescue IO::Error
      ensure
        transport.remove_get_stream(stream)
      end
    end

    private def handle_http_delete(context : HTTP::Server::Context) : Nil
      if id = context.request.headers["MCP-Session-Id"]?
        session = @http_mutex.synchronize do
          deleted = @http_sessions.delete(id)
          if deleted && deleted == @anonymous_http_session
            @anonymous_http_session = nil
            @anonymous_http_session_id = nil
          end
          deleted
        end
        if session
          session.close
          context.response.status = :ok
        else
          context.response.status = :not_found
        end
      else
        context.response.status = :method_not_allowed
      end
    end

    private def check_http_protocol_version(context : HTTP::Server::Context, envelope : Envelope) : Bool
      response = context.response
      header = context.request.headers["MCP-Protocol-Version"]?
      id = envelope.id
      if header.nil?
        response.status = :bad_request
        respond_http_rpc_error(response, id, ErrorCodes::HEADER_MISMATCH,
          "missing MCP-Protocol-Version header")
        return false
      end
      unless SUPPORTED_PROTOCOL_VERSIONS.includes?(header)
        response.status = :bad_request
        respond_http_rpc_error(response, id, ErrorCodes::UNSUPPORTED_PROTOCOL_VERSION,
          "unsupported protocol version: #{header}",
          MCP.to_any({requested: header, supported: SUPPORTED_PROTOCOL_VERSIONS}))
        return false
      end
      params = envelope.params
      if params && (hash = params.as_h?) && (meta_value = hash["_meta"]?)
        meta_hash = meta_value.as_h?
        if meta_hash && (pv = meta_hash[META_PROTOCOL_VERSION]?) && (body_version = pv.as_s?)
          unless body_version == header
            response.status = :bad_request
            respond_http_rpc_error(response, id, ErrorCodes::HEADER_MISMATCH,
              "MCP-Protocol-Version header does not match params._meta protocolVersion")
            return false
          end
        end
      end
      true
    end

    private def respond_http_rpc_error(response : HTTP::Server::Response, id : RequestId?,
                                       code : Int32, message : String, data : JSON::Any? = nil) : Nil
      response.status = :bad_request if response.status.success?
      response.content_type = "application/json"
      response.print(MCP.error_json(id, ErrorObject.new(code, message, data)))
    end

    private def is_response_for?(message : String, id : RequestId) : Bool
      env = Envelope.parse(message)
      env.response? && env.id == id
    rescue JSON::ParseException
      false
    end
  end

  struct DiscoverParams
    include JSON::Serializable

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    def initialize(@meta : RequestMeta? = nil)
    end
  end
end
