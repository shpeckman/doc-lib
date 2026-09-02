# src/mcp/client.cr
require "json"

module MCP
  class ClientSubscription
    getter id : RequestId

    def initialize(@id : RequestId, @client : Client)
    end

    def cancel(reason : String? = nil) : Nil
      @client.session.cancel_request(@id, reason)
    end
  end

  class Client
    getter info : Implementation
    getter capabilities : ClientCapabilities
    getter protocol_version : String
    getter session : Session

    @sampling_handler : Proc(CreateMessageParams, CreateMessageResult)?
    @elicitation_handler : Proc(ElicitParams, ElicitResult)?
    @roots_handler : Proc(ListRootsResult)?
    @progress_handlers = Hash(ProgressToken, Proc(ProgressParams, Nil)).new
    @progress_mutex = Mutex.new

    def initialize(@transport : Transport, @info : Implementation,
                   @capabilities : ClientCapabilities = ClientCapabilities.new,
                   @protocol_version : String = PROTOCOL_VERSION)
      @session = Session.new(@transport)
      register_peer_handlers
    end

    def self.connect_stdio(command : String, args : Array(String) = [] of String,
                           env : Hash(String, String)? = nil, chdir : String? = nil,
                           info : Implementation = default_info,
                           capabilities : ClientCapabilities = ClientCapabilities.new,
                           protocol_version : String = PROTOCOL_VERSION) : Client
      client = new(StdioClientTransport.new(command, args, env, chdir), info, capabilities, protocol_version)
      client.start
      client
    end

    def self.connect_http(url : String, headers : Hash(String, String) = Hash(String, String).new,
                          info : Implementation = default_info,
                          capabilities : ClientCapabilities = ClientCapabilities.new,
                          protocol_version : String = PROTOCOL_VERSION) : Client
      transport = HttpClientTransport.new(url, headers)
      transport.protocol_version = protocol_version
      client = new(transport, info, capabilities, protocol_version)
      client.start
      client
    end

    def self.default_info : Implementation
      Implementation.new(name: "crystal-mcp-client", version: MCP::VERSION)
    end

    def start : Nil
      transport = @transport
      if transport.is_a?(HttpClientTransport)
        transport.start
      end
      spawn @session.run
    end

    def close : Nil
      @session.close
    end

    def on_sampling(&handler : CreateMessageParams -> CreateMessageResult) : Nil
      @sampling_handler = handler
    end

    def on_elicitation(&handler : ElicitParams -> ElicitResult) : Nil
      @elicitation_handler = handler
    end

    def on_roots(&handler : -> ListRootsResult) : Nil
      @roots_handler = handler
    end

    def on_notification(method : String, &handler : String, JSON::Any? -> Nil) : Nil
      @session.on_notification(method, &handler)
    end

    def on_tools_changed(&handler : String, JSON::Any? -> Nil) : Nil
      on_notification(Methods::NOTIF_TOOLS_CHANGED, &handler)
    end

    def on_resources_changed(&handler : String, JSON::Any? -> Nil) : Nil
      on_notification(Methods::NOTIF_RESOURCES_CHANGED, &handler)
    end

    def on_prompts_changed(&handler : String, JSON::Any? -> Nil) : Nil
      on_notification(Methods::NOTIF_PROMPTS_CHANGED, &handler)
    end

    def on_resource_updated(&handler : String, JSON::Any? -> Nil) : Nil
      on_notification(Methods::NOTIF_RESOURCE_UPDATED, &handler)
    end

    def on_log(&handler : LoggingMessageParams -> Nil) : Nil
      on_notification(Methods::NOTIF_MESSAGE) do |_, params|
        if params
          handler.call(LoggingMessageParams.from_json(params.to_json))
        end
      end
    end

    def discover(timeout : Time::Span? = nil) : DiscoverResult
      raw = invoke(Methods::DISCOVER, DiscoverParams.new(meta: request_meta), timeout)
      DiscoverResult.from_json(raw.to_json)
    end

    def list_tools(cursor : String? = nil, timeout : Time::Span? = nil) : ListToolsResult
      raw = invoke(Methods::LIST_TOOLS, PaginatedParams.new(meta: request_meta, cursor: cursor), timeout)
      ListToolsResult.from_json(raw.to_json)
    end

    def list_all_tools(timeout : Time::Span? = nil) : Array(Tool)
      collect_pages { |cursor| list_tools(cursor, timeout) }
    end

    def call_tool(name : String, arguments = nil, timeout : Time::Span? = nil) : CallToolResult
      call_tool_impl(name, arguments, timeout, nil)
    end

    def call_tool(name : String, arguments = nil, timeout : Time::Span? = nil,
                  &on_progress : ProgressParams -> Nil) : CallToolResult
      call_tool_impl(name, arguments, timeout, on_progress)
    end

    def list_resources(cursor : String? = nil, timeout : Time::Span? = nil) : ListResourcesResult
      raw = invoke(Methods::LIST_RESOURCES, PaginatedParams.new(meta: request_meta, cursor: cursor), timeout)
      ListResourcesResult.from_json(raw.to_json)
    end

    def list_all_resources(timeout : Time::Span? = nil) : Array(Resource)
      collect_pages { |cursor| list_resources(cursor, timeout) }
    end

    def list_resource_templates(cursor : String? = nil, timeout : Time::Span? = nil) : ListResourceTemplatesResult
      raw = invoke(Methods::LIST_RESOURCE_TEMPLATES, PaginatedParams.new(meta: request_meta, cursor: cursor), timeout)
      ListResourceTemplatesResult.from_json(raw.to_json)
    end

    def list_all_resource_templates(timeout : Time::Span? = nil) : Array(ResourceTemplate)
      collect_pages { |cursor| list_resource_templates(cursor, timeout) }
    end

    def read_resource(uri : String, timeout : Time::Span? = nil) : ReadResourceResult
      raw = invoke(Methods::READ_RESOURCE, ReadResourceParams.new(uri: uri, meta: request_meta), timeout)
      ReadResourceResult.from_json(raw.to_json)
    end

    def list_prompts(cursor : String? = nil, timeout : Time::Span? = nil) : ListPromptsResult
      raw = invoke(Methods::LIST_PROMPTS, PaginatedParams.new(meta: request_meta, cursor: cursor), timeout)
      ListPromptsResult.from_json(raw.to_json)
    end

    def list_all_prompts(timeout : Time::Span? = nil) : Array(Prompt)
      collect_pages { |cursor| list_prompts(cursor, timeout) }
    end

    def get_prompt(name : String, arguments : Hash(String, String)? = nil,
                   timeout : Time::Span? = nil) : GetPromptResult
      raw = invoke(Methods::GET_PROMPT,
        GetPromptParams.new(name: name, meta: request_meta, arguments: arguments), timeout)
      GetPromptResult.from_json(raw.to_json)
    end

    def complete(ref : CompletionReference, argument_name : String, argument_value : String,
                 context : CompletionContext? = nil, timeout : Time::Span? = nil) : CompleteResult
      params = CompleteParams.new(ref: ref, argument: CompletionArgument.new(argument_name, argument_value),
        meta: request_meta, context: context)
      raw = invoke(Methods::COMPLETE, params, timeout)
      CompleteResult.from_json(raw.to_json)
    end

    def listen(filter : SubscriptionFilter, &handler : String, JSON::Any? -> Nil) : ClientSubscription
      id = @session.allocate_id
      listen_handler = ->(method : String, params : JSON::Any?) do
        if params
          hash = params.as_h?
          meta = hash.try { |h| h["_meta"]?.try(&.as_h?) }
          sub_value = meta.try { |m| m[META_SUBSCRIPTION_ID]? }
          sub_id : RequestId? = nil
          if sub_value
            sub_id = sub_value.as_s? || sub_value.as_i64?
          end
          if sub_id && sub_id == id
            handler.call(method, params)
          end
        end
      end
      subscription = ClientSubscription.new(id, self)
      [
        Methods::NOTIF_TOOLS_CHANGED, Methods::NOTIF_RESOURCES_CHANGED,
        Methods::NOTIF_RESOURCE_UPDATED, Methods::NOTIF_PROMPTS_CHANGED,
        Methods::NOTIF_SUBS_ACKNOWLEDGED, Methods::NOTIF_MESSAGE, Methods::NOTIF_PROGRESS,
      ].each do |method|
        @session.on_notification(method, &listen_handler)
      end
      spawn do
        @session.request_raw(id, Methods::LISTEN,
          SubscriptionsListenParams.new(notifications: filter, meta: request_meta))
      rescue RpcError
      ensure
        remove_listen_handler(listen_handler)
      end
      subscription
    end

    private def remove_listen_handler(handler : Proc(String, JSON::Any?, Nil)) : Nil
      [
        Methods::NOTIF_TOOLS_CHANGED, Methods::NOTIF_RESOURCES_CHANGED,
        Methods::NOTIF_RESOURCE_UPDATED, Methods::NOTIF_PROMPTS_CHANGED,
        Methods::NOTIF_SUBS_ACKNOWLEDGED, Methods::NOTIF_MESSAGE, Methods::NOTIF_PROGRESS,
      ].each do |method|
        @session.remove_notification_handler(method, handler)
      end
    end

    protected def request_meta(progress_token : ProgressToken? = nil) : RequestMeta
      RequestMeta.new(protocol_version: @protocol_version, client_capabilities: @capabilities,
        client_info: @info, progress_token: progress_token)
    end

    private def call_tool_impl(name : String, arguments, timeout : Time::Span?,
                               on_progress : Proc(ProgressParams, Nil)?) : CallToolResult
      token : String? = nil
      if handler = on_progress
        token = "crystal-mcp-progress-#{Random::Secure.hex(8)}"
        @progress_mutex.synchronize { @progress_handlers[token] = handler }
      end
      args : Hash(String, JSON::Any)? = nil
      unless arguments.nil?
        args = MCP.to_any(arguments).as_h
      end
      params = CallToolParams.new(name: name, meta: request_meta(token), arguments: args)
      raw = invoke(Methods::CALL_TOOL, params, timeout)
      CallToolResult.from_json(raw.to_json)
    ensure
      if token
        @progress_mutex.synchronize { @progress_handlers.delete(token) }
      end
    end

    private def invoke(method : String, params : P, timeout : Time::Span? = nil) : JSON::Any forall P
      raw = @session.request_raw(method, params, timeout)
      attempts = 0
      while MCP.input_required?(raw)
        attempts += 1
        if attempts > 8
          raise RpcError.new(ErrorCodes::INTERNAL_ERROR, "too many input-required round trips")
        end
        required = InputRequiredResult.from_json(raw.to_json)
        responses = fulfill_inputs(required.input_requests)
        retry_params = JSON.parse(params.to_json).as_h
        retry_params["inputResponses"] = MCP.to_any(responses)
        if state = required.request_state
          retry_params["requestState"] = JSON::Any.new(state)
        end
        raw = @session.request_raw(method, retry_params, timeout)
      end
      raw
    end

    private def fulfill_inputs(requests : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)
      responses = Hash(String, JSON::Any).new
      return responses unless requests
      requests.each do |key, value|
        hash = value.as_h?
        next unless hash
        method = hash["method"]?.try(&.as_s?)
        params_value = hash["params"]?
        case method
        when Methods::CREATE_MESSAGE
          handler = @sampling_handler
          raise RpcError.new(ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY,
            "server requires sampling but no sampling handler is registered") unless handler
          params = CreateMessageParams.from_json(params_value.try(&.to_json) || "{}")
          responses[key] = MCP.to_any(handler.call(params))
        when Methods::LIST_ROOTS
          handler = @roots_handler
          raise RpcError.new(ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY,
            "server requires roots but no roots handler is registered") unless handler
          responses[key] = MCP.to_any(handler.call)
        when Methods::ELICIT
          handler = @elicitation_handler
          raise RpcError.new(ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY,
            "server requires elicitation but no elicitation handler is registered") unless handler
          params = parse_elicit_params(params_value)
          responses[key] = MCP.to_any(handler.call(params))
        end
      end
      responses
    end

    private def parse_elicit_params(value : JSON::Any?) : ElicitParams
      raw = value.try(&.to_json) || "{}"
      hash = JSON.parse(raw).as_h?
      if hash && hash["mode"]?.try(&.as_s?) == "url"
        ElicitURLParams.from_json(raw)
      else
        ElicitFormParams.from_json(raw)
      end
    end

    private def collect_pages(& : String? -> R) forall R
      cursor : String? = nil
      page = yield cursor
      items = page_items(page).dup
      loop do
        cursor = page_next_cursor(page)
        break if cursor.nil?
        page = yield cursor
        items.concat(page_items(page))
      end
      items
    end

    private def page_items(page : ListToolsResult) : Array(Tool)
      page.tools
    end

    private def page_items(page : ListResourcesResult) : Array(Resource)
      page.resources
    end

    private def page_items(page : ListResourceTemplatesResult) : Array(ResourceTemplate)
      page.resource_templates
    end

    private def page_items(page : ListPromptsResult) : Array(Prompt)
      page.prompts
    end

    private def page_next_cursor(page : ListToolsResult | ListResourcesResult | ListResourceTemplatesResult | ListPromptsResult) : String?
      page.next_cursor
    end

    private def register_peer_handlers : Nil
      @session.on_request(Methods::CREATE_MESSAGE) do |request|
        handler = @sampling_handler
        raise RpcError.new(ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY,
          "sampling not supported by this client") unless handler
        MCP.to_any(handler.call(request.params_as(CreateMessageParams)))
      end

      @session.on_request(Methods::LIST_ROOTS) do |_request|
        handler = @roots_handler
        raise RpcError.new(ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY,
          "roots not supported by this client") unless handler
        MCP.to_any(handler.call)
      end

      @session.on_request(Methods::ELICIT) do |request|
        handler = @elicitation_handler
        raise RpcError.new(ErrorCodes::MISSING_REQUIRED_CLIENT_CAPABILITY,
          "elicitation not supported by this client") unless handler
        MCP.to_any(handler.call(parse_elicit_params(request.raw_params)))
      end

      @session.on_notification(Methods::NOTIF_PROGRESS) do |_, params|
        next unless params
        begin
          progress = ProgressParams.from_json(params.to_json)
        rescue JSON::SerializableError | JSON::ParseException
          next
        end
        handler = @progress_mutex.synchronize { @progress_handlers[progress.progress_token]? }
        handler.try(&.call(progress))
      end
    end
  end
end
