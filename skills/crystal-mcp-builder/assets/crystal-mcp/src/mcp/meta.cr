# src/mcp/meta.cr
require "json"

module MCP
  struct RequestMeta
    getter protocol_version : String?
    getter client_capabilities : ClientCapabilities?
    getter client_info : Implementation?
    getter log_level : LoggingLevel?
    getter progress_token : ProgressToken?
    getter extras : Hash(String, JSON::Any)

    def initialize(*, @protocol_version : String? = nil,
                   @client_capabilities : ClientCapabilities? = nil,
                   @client_info : Implementation? = nil,
                   @log_level : LoggingLevel? = nil,
                   @progress_token : ProgressToken? = nil,
                   @extras : Hash(String, JSON::Any) = Hash(String, JSON::Any).new)
    end

    def [](key : String) : JSON::Any?
      @extras[key]?
    end

    def self.new(pull : JSON::PullParser) : self
      protocol_version : String? = nil
      client_capabilities : ClientCapabilities? = nil
      client_info : Implementation? = nil
      log_level : LoggingLevel? = nil
      progress_token : ProgressToken? = nil
      extras = Hash(String, JSON::Any).new
      pull.read_object do |key|
        case key
        when META_PROTOCOL_VERSION    then protocol_version = pull.read_string
        when META_CLIENT_CAPABILITIES then client_capabilities = ClientCapabilities.new(pull)
        when META_CLIENT_INFO         then client_info = Implementation.new(pull)
        when META_LOG_LEVEL           then log_level = LoggingLevel.new(pull)
        when META_PROGRESS_TOKEN
          progress_token = pull.kind.string? ? pull.read_string : pull.read_int
        else
          extras[key] = JSON::Any.new(pull)
        end
      end
      new(protocol_version: protocol_version, client_capabilities: client_capabilities,
        client_info: client_info, log_level: log_level,
        progress_token: progress_token, extras: extras)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field META_PROTOCOL_VERSION, @protocol_version if @protocol_version
        json.field META_CLIENT_CAPABILITIES, @client_capabilities if @client_capabilities
        json.field META_CLIENT_INFO, @client_info if @client_info
        json.field META_LOG_LEVEL, @log_level if @log_level
        json.field META_PROGRESS_TOKEN, @progress_token if @progress_token
        @extras.each do |key, value|
          json.field key, value
        end
      end
    end
  end

  struct NotificationMeta
    getter subscription_id : RequestId?
    getter extras : Hash(String, JSON::Any)

    def initialize(*, @subscription_id : RequestId? = nil,
                   @extras : Hash(String, JSON::Any) = Hash(String, JSON::Any).new)
    end

    def [](key : String) : JSON::Any?
      @extras[key]?
    end

    def self.new(pull : JSON::PullParser) : self
      subscription_id : RequestId? = nil
      extras = Hash(String, JSON::Any).new
      pull.read_object do |key|
        case key
        when META_SUBSCRIPTION_ID
          subscription_id = pull.kind.string? ? pull.read_string : pull.read_int
        else
          extras[key] = JSON::Any.new(pull)
        end
      end
      new(subscription_id: subscription_id, extras: extras)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field META_SUBSCRIPTION_ID, @subscription_id if @subscription_id
        @extras.each do |key, value|
          json.field key, value
        end
      end
    end
  end

  struct ResultMeta
    getter server_info : Implementation?
    getter subscription_id : RequestId?
    getter extras : Hash(String, JSON::Any)

    def initialize(*, @server_info : Implementation? = nil, @subscription_id : RequestId? = nil,
                   @extras : Hash(String, JSON::Any) = Hash(String, JSON::Any).new)
    end

    def [](key : String) : JSON::Any?
      @extras[key]?
    end

    def self.new(pull : JSON::PullParser) : self
      server_info : Implementation? = nil
      subscription_id : RequestId? = nil
      extras = Hash(String, JSON::Any).new
      pull.read_object do |key|
        case key
        when META_SERVER_INFO      then server_info = Implementation.new(pull)
        when META_SUBSCRIPTION_ID
          subscription_id = pull.kind.string? ? pull.read_string : pull.read_int
        else
          extras[key] = JSON::Any.new(pull)
        end
      end
      new(server_info: server_info, subscription_id: subscription_id, extras: extras)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field META_SERVER_INFO, @server_info if @server_info
        json.field META_SUBSCRIPTION_ID, @subscription_id if @subscription_id
        @extras.each do |key, value|
          json.field key, value
        end
      end
    end
  end
end
