# src/mcp/transports/http.cr
require "http/client"
require "uuid"

module MCP
  module SSE
    def self.write(io : IO, data : String) : Nil
      data.each_line do |line|
        io << "data: " << line << '\n'
      end
      io << '\n'
      io.flush
    end

    def self.each_event(io : IO, & : String -> Nil) : Nil
      data = IO::Memory.new
      has_data = false
      while line = io.gets
        line = line.chomp
        if line.empty?
          if has_data
            yield data.to_s
            data = IO::Memory.new
            has_data = false
          end
        elsif line.starts_with?(':')
        elsif line.starts_with?("data:")
          payload = line[5..]
          payload = payload[1..] if payload.starts_with?(' ')
          data << payload << '\n'
          has_data = true
        end
      end
      yield data.to_s if has_data
    end
  end

  class HttpClientTransport < Transport
    PROTOCOL_HEADER = "MCP-Protocol-Version"
    SESSION_HEADER  = "MCP-Session-Id"

    getter session_id : String?
    property protocol_version : String = PROTOCOL_VERSION

    def initialize(@url : String, @headers : Hash(String, String) = Hash(String, String).new)
      @uri = URI.parse(@url)
      @inbox = Channel(String).new(64)
      @closed = Atomic(Bool).new(false)
      @get_started = Atomic(Bool).new(false)
    end

    private def new_client : HTTP::Client
      client = HTTP::Client.new(@uri)
      client.read_timeout = nil
      client
    end

    def start : Nil
      return if @get_started.swap(true)
      spawn get_stream
    end

    def send(message : String) : Nil
      return if closed?
      envelope : Envelope? = nil
      begin
        envelope = Envelope.parse(message)
      rescue JSON::ParseException
        return
      end
      env = envelope.not_nil!
      if env.request?
        spawn post_request(message, env.id.not_nil!)
      else
        spawn post_simple(message)
      end
    end

    def read_message : String?
      @inbox.receive
    rescue Channel::ClosedError
      nil
    end

    def close : Nil
      return if @closed.swap(true)
      @inbox.close
    end

    def closed? : Bool
      @closed.get
    end

    private def base_headers : HTTP::Headers
      headers = HTTP::Headers.new
      @headers.each { |k, v| headers[k] = v }
      headers[PROTOCOL_HEADER] = @protocol_version
      if id = @session_id
        headers[SESSION_HEADER] = id
      end
      headers
    end

    private def capture_session(response : HTTP::Client::Response) : Nil
      if id = response.headers[SESSION_HEADER]?
        @session_id = id
      end
    end

    private def request_path : String
      path = @uri.path
      path.empty? ? "/" : path
    end

    private def post_request(message : String, id : RequestId) : Nil
      headers = base_headers
      headers["Content-Type"] = "application/json"
      headers["Accept"] = "application/json, text/event-stream"
      new_client.post(request_path, headers: headers, body: message) do |response|
        capture_session(response)
        content_type = response.headers["Content-Type"]? || ""
        if response.status.success?
          if content_type.includes?("text/event-stream")
            SSE.each_event(response.body_io) do |event|
              deliver(event)
            end
          else
            deliver(response.body_io.gets_to_end)
          end
        else
          body = response.body_io.gets_to_end
          handled = false
          begin
            parsed = Envelope.parse(body)
            if parsed.error
              deliver(body)
              handled = true
            end
          rescue JSON::ParseException
          end
          unless handled
            deliver(MCP.error_json(id, ErrorObject.new(ErrorCodes::INTERNAL_ERROR,
              "HTTP #{response.status_code} #{response.status_message}")))
          end
        end
      end
    rescue ex : IO::Error | Socket::Error
      deliver(MCP.error_json(id, ErrorObject.new(ErrorCodes::INTERNAL_ERROR, "HTTP transport error: #{ex.message}")))
    end

    private def post_simple(message : String) : Nil
      headers = base_headers
      headers["Content-Type"] = "application/json"
      response = new_client.post(request_path, headers: headers, body: message)
      capture_session(response)
    rescue IO::Error | Socket::Error
    end

    private def get_stream : Nil
      headers = base_headers
      headers["Accept"] = "text/event-stream"
      new_client.get(request_path, headers: headers) do |response|
        capture_session(response)
        unless response.status.success?
          break
        end
        SSE.each_event(response.body_io) do |event|
          deliver(event)
        end
      end
    rescue IO::Error | Socket::Error
    end

    private def deliver(message : String) : Nil
      return if closed?
      return if message.strip.empty?
      @inbox.send(message)
    rescue Channel::ClosedError
    end
  end

  class HttpSessionTransport < Transport
    @inbox = Channel(String).new(64)
    @response_waiters = Hash(RequestId, Channel(String)).new
    @listen_streams = Hash(RequestId, Channel(String)).new
    @get_streams = [] of Channel(String)
    @mutex = Mutex.new
    @closed = Atomic(Bool).new(false)

    def push_incoming(message : String) : Nil
      @inbox.send(message)
    rescue Channel::ClosedError
    end

    def read_message : String?
      @inbox.receive
    rescue Channel::ClosedError
      nil
    end

    def register_waiter(id : RequestId) : Channel(String)
      channel = Channel(String).new(1)
      @mutex.synchronize { @response_waiters[id] = channel }
      channel
    end

    def unregister_waiter(id : RequestId) : Nil
      @mutex.synchronize { @response_waiters.delete(id) }
    end

    def register_listen(id : RequestId) : Channel(String)
      channel = Channel(String).new(64)
      @mutex.synchronize { @listen_streams[id] = channel }
      channel
    end

    def unregister_listen(id : RequestId) : Nil
      channel = @mutex.synchronize { @listen_streams.delete(id) }
      channel.try(&.close)
    end

    def listen_stream?(id : RequestId) : Bool
      @mutex.synchronize { @listen_streams.has_key?(id) }
    end

    def add_get_stream : Channel(String)
      channel = Channel(String).new(64)
      @mutex.synchronize { @get_streams << channel }
      channel
    end

    def remove_get_stream(channel : Channel(String)) : Nil
      @mutex.synchronize { @get_streams.delete(channel) }
    end

    def send(message : String) : Nil
      envelope : Envelope? = nil
      begin
        envelope = Envelope.parse(message)
      rescue JSON::ParseException
        return
      end
      env = envelope.not_nil!
      if env.response? && (id = env.id)
        target = @mutex.synchronize do
          @listen_streams[id]? || @response_waiters[id]?
        end
        if target
          begin
            target.send(message)
          rescue Channel::ClosedError
          end
        end
        return
      end
      if env.notification?
        if sub_id = subscription_id_of(env)
          stream = @mutex.synchronize { @listen_streams[sub_id]? }
          if stream
            begin
              stream.send(message)
            rescue Channel::ClosedError
            end
            return
          end
        end
      end
      streams = @mutex.synchronize { @get_streams.dup }
      if streams.empty?
        if env.request?
          raise RpcError.new(ErrorCodes::INTERNAL_ERROR,
            "cannot send server-initiated request: client has no open SSE stream")
        end
        return
      end
      streams.each do |stream|
        begin
          stream.send(message)
        rescue Channel::ClosedError
        end
      end
    end

    def close : Nil
      return if @closed.swap(true)
      @inbox.close
      @mutex.synchronize do
        @get_streams.each(&.close)
        @get_streams.clear
        @listen_streams.each_value(&.close)
        @listen_streams.clear
        @response_waiters.each_value(&.close)
        @response_waiters.clear
      end
    end

    def closed? : Bool
      @closed.get
    end

    private def subscription_id_of(envelope : Envelope) : RequestId?
      params = envelope.params
      return nil unless params
      hash = params.as_h?
      return nil unless hash
      meta = hash["_meta"]?.try(&.as_h?)
      return nil unless meta
      value = meta[META_SUBSCRIPTION_ID]?
      return nil unless value
      if s = value.as_s?
        s
      elsif i = value.as_i64?
        i
      end
    end
  end
end
