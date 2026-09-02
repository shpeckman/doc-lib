# src/mcp/session.cr
require "json"

module MCP
  class Session
    alias RequestHandler = Proc(InboundRequest, JSON::Any?)
    alias NotificationHandler = Proc(String, JSON::Any?, Nil)

    getter transport : Transport
    property request_filter : Proc(Envelope, Nil)?

    @request_handlers = Hash(String, RequestHandler).new
    @notification_handlers = Hash(String, Array(NotificationHandler)).new
    @pending = Hash(RequestId, Channel(Envelope)).new
    @pending_mutex = Mutex.new
    @in_flight = Hash(RequestId, InboundRequest).new
    @in_flight_mutex = Mutex.new
    @next_id = Atomic(Int64).new(0_i64)
    @closed = Atomic(Bool).new(false)
    @shutdown = Atomic(Bool).new(false)
    @on_close : Proc(Nil)?

    def initialize(@transport : Transport)
      on_notification(Methods::NOTIF_CANCELLED) do |_, params|
        if params
          begin
            cancelled = CancelledParams.from_json(params.to_json)
            handle_cancelled(cancelled)
          rescue JSON::SerializableError
          end
        end
      end
    end

    def on_request(method : String, &block : InboundRequest -> JSON::Any?) : Nil
      @request_handlers[method] = block
    end

    def on_notification(method : String, &block : String, JSON::Any? -> Nil) : Nil
      (@notification_handlers[method] ||= [] of NotificationHandler) << block
    end

    def remove_notification_handler(method : String, handler : NotificationHandler) : Nil
      if handlers = @notification_handlers[method]?
        handlers.delete(handler)
      end
    end

    def on_close(&block : -> Nil) : Nil
      @on_close = block
    end

    def closed? : Bool
      @closed.get
    end

    def run : Nil
      until closed?
        message = @transport.read_message
        break if message.nil?
        spawn handle_message(message)
      end
    ensure
      shutdown
    end

    def allocate_id : Int64
      @next_id.add(1)
    end

    def request(method : String, params : P = nil, read_timeout : Time::Span? = nil, & : JSON::Any -> T) : T forall P, T
      yield request_raw(method, params, read_timeout)
    end

    def request_raw(method : String, params : P = nil, read_timeout : Time::Span? = nil) : JSON::Any forall P
      request_raw(allocate_id, method, params, read_timeout)
    end

    def request_raw(id : RequestId, method : String, params : P = nil, read_timeout : Time::Span? = nil) : JSON::Any forall P
      channel = Channel(Envelope).new(1)
      @pending_mutex.synchronize { @pending[id] = channel }
      begin
        send_raw MCP.request_json(id, method, params)
        envelope : Envelope
        if span = read_timeout
          select
          when received = channel.receive
            envelope = received
          when timeout(span)
            raise RpcError.new(ErrorCodes::INTERNAL_ERROR, "request timed out: #{method}")
          end
        else
          envelope = channel.receive
        end
        if error = envelope.error
          raise RpcError.new(error.code, error.message, error.data)
        end
        envelope.result || JSON::Any.new(nil)
      rescue Channel::ClosedError
        raise RpcError.new(ErrorCodes::INTERNAL_ERROR, "session closed while awaiting response to #{method}")
      ensure
        @pending_mutex.synchronize { @pending.delete(id) }
      end
    end

    def notify(method : String, params : P = nil) : Nil forall P
      send_raw MCP.notification_json(method, params)
    end

    def send_response(id : RequestId, result : R) : Nil forall R
      send_raw MCP.result_json(id, result)
    end

    def send_error(id : RequestId?, error : ErrorObject) : Nil
      send_raw MCP.error_json(id, error)
    end

    def cancel_request(request_id : RequestId, reason : String? = nil) : Nil
      notify(Methods::NOTIF_CANCELLED, CancelledParams.new(request_id: request_id, reason: reason))
    end

    def create_message(params : CreateMessageParams, read_timeout : Time::Span? = nil) : CreateMessageResult
      request(Methods::CREATE_MESSAGE, params, read_timeout) do |result|
        CreateMessageResult.from_json(result.to_json)
      end
    end

    def list_roots(read_timeout : Time::Span? = nil) : ListRootsResult
      request(Methods::LIST_ROOTS, nil, read_timeout) do |result|
        ListRootsResult.from_json(result.to_json)
      end
    end

    def elicit(params : ElicitParams, read_timeout : Time::Span? = nil) : ElicitResult
      request(Methods::ELICIT, params, read_timeout) do |result|
        ElicitResult.from_json(result.to_json)
      end
    end

    def close : Nil
      return if @closed.swap(true)
      @transport.close
      shutdown
    end

    protected def send_raw(message : String) : Nil
      raise RpcError.new(ErrorCodes::INTERNAL_ERROR, "session is closed") if closed?
      @transport.send(message)
    end

    private def handle_message(message : String) : Nil
      envelope : Envelope
      begin
        envelope = Envelope.parse(message)
      rescue ex : JSON::ParseException
        send_error(nil, ErrorObject.new(ErrorCodes::PARSE_ERROR, "parse error: #{ex.message}"))
        return
      end
      if envelope.request?
        dispatch_request(envelope)
      elsif envelope.notification?
        dispatch_notification(envelope)
      elsif envelope.response?
        dispatch_response(envelope)
      else
        send_error(envelope.id, ErrorObject.new(ErrorCodes::INVALID_REQUEST, "invalid JSON-RPC message"))
      end
    rescue ex
      STDERR.puts "crystal-mcp: message handling failed: #{ex.message}" if ENV.has_key?("MCP_DEBUG")
    end

    private def dispatch_request(envelope : Envelope) : Nil
      id = envelope.id.not_nil!
      method = envelope.method.not_nil!
      handler = @request_handlers[method]?
      unless handler
        send_error(id, ErrorObject.new(ErrorCodes::METHOD_NOT_FOUND, "method not found: #{method}"))
        return
      end
      inbound = InboundRequest.new(self, id, method, envelope.params)
      @in_flight_mutex.synchronize { @in_flight[id] = inbound }
      begin
        @request_filter.try(&.call(envelope))
        result = handler.call(inbound)
        unless inbound.deferred?
          if inbound.context.cancelled?
          elsif result.nil?
            send_response(id, JSON.parse(%({"resultType":"complete"})))
          else
            send_response(id, result)
          end
        end
      rescue ex : RpcError
        send_error(id, ex.to_error_object) unless inbound.deferred?
      rescue ex : JSON::SerializableError | JSON::ParseException
        send_error(id, ErrorObject.new(ErrorCodes::INVALID_PARAMS, ex.message || "invalid params")) unless inbound.deferred?
      rescue ex
        send_error(id, ErrorObject.new(ErrorCodes::INTERNAL_ERROR, ex.message || "internal error")) unless inbound.deferred?
      ensure
        @in_flight_mutex.synchronize { @in_flight.delete(id) }
      end
    end

    private def dispatch_notification(envelope : Envelope) : Nil
      method = envelope.method.not_nil!
      handlers = @notification_handlers[method]?
      return unless handlers
      handlers.each do |handler|
        handler.call(method, envelope.params)
      end
    end

    private def dispatch_response(envelope : Envelope) : Nil
      id = envelope.id
      return if id.nil?
      channel = @pending_mutex.synchronize { @pending[id]? }
      channel.try(&.send(envelope))
    end

    private def handle_cancelled(cancelled : CancelledParams) : Nil
      inbound = @in_flight_mutex.synchronize { @in_flight[cancelled.request_id]? }
      inbound.try(&.context.cancel)
    end

    private def fail_pending : Nil
      @pending_mutex.synchronize do
        @pending.each_value(&.close)
        @pending.clear
      end
    end

    private def shutdown : Nil
      return if @shutdown.swap(true)
      fail_pending
      @on_close.try(&.call)
    end
  end

  class InboundRequest
    getter session : Session
    getter id : RequestId
    getter method : String
    getter raw_params : JSON::Any?
    getter context : RequestContext
    @deferred = Atomic(Bool).new(false)

    def initialize(@session : Session, @id : RequestId, @method : String, @raw_params : JSON::Any?)
      @context = RequestContext.new(@session, meta)
    end

    def meta : RequestMeta?
      params = @raw_params
      return nil unless params
      hash = params.as_h?
      return nil unless hash
      meta_value = hash["_meta"]?
      return nil unless meta_value
      RequestMeta.from_json(meta_value.to_json)
    rescue JSON::ParseException | JSON::SerializableError
      nil
    end

    def params_as(type : T.class) : T forall T
      raw = @raw_params
      raise RpcError.new(ErrorCodes::INVALID_PARAMS, "missing params") if raw.nil?
      T.from_json(raw.to_json)
    rescue ex : JSON::SerializableError | JSON::ParseException
      raise RpcError.new(ErrorCodes::INVALID_PARAMS, ex.message || "invalid params")
    end

    def defer! : Nil
      @deferred.set(true)
    end

    def deferred? : Bool
      @deferred.get
    end

    def respond(result : R) : Nil forall R
      @session.send_response(@id, result)
    end

    def respond_error(error : ErrorObject) : Nil
      @session.send_error(@id, error)
    end

    def respond_error(code : Int32, message : String) : Nil
      respond_error(ErrorObject.new(code, message))
    end
  end

  class RequestContext
    getter session : Session
    getter meta : RequestMeta?
    @cancelled = Atomic(Bool).new(false)

    def initialize(@session : Session, @meta : RequestMeta?)
    end

    def cancelled? : Bool
      @cancelled.get
    end

    def cancel : Nil
      @cancelled.set(true)
    end

    def progress_token : ProgressToken?
      @meta.try(&.progress_token)
    end

    def report_progress(progress : Float64, total : Float64? = nil, message : String? = nil) : Nil
      token = progress_token
      return unless token
      @session.notify(Methods::NOTIF_PROGRESS,
        ProgressParams.new(progress_token: token, progress: progress, total: total, message: message))
    end
  end
end
