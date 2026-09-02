# src/mcp/notifications.cr
require "json"

module MCP
  struct CancelledParams
    include JSON::Serializable

    @[JSON::Field(key: "requestId")]
    getter request_id : RequestId

    @[JSON::Field(emit_null: false)]
    getter reason : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : NotificationMeta?

    def initialize(@request_id : RequestId, @reason : String? = nil, @meta : NotificationMeta? = nil)
    end
  end

  struct ProgressParams
    include JSON::Serializable

    @[JSON::Field(key: "progressToken")]
    getter progress_token : ProgressToken

    getter progress : Float64

    @[JSON::Field(emit_null: false)]
    getter total : Float64?

    @[JSON::Field(emit_null: false)]
    getter message : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : NotificationMeta?

    def initialize(@progress_token : ProgressToken, @progress : Float64, @total : Float64? = nil,
                   @message : String? = nil, @meta : NotificationMeta? = nil)
    end
  end

  struct ResourceUpdatedParams
    include JSON::Serializable

    getter uri : String

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : NotificationMeta?

    def initialize(@uri : String, @meta : NotificationMeta? = nil)
    end
  end

  struct LoggingMessageParams
    include JSON::Serializable

    getter level : LoggingLevel
    getter data : JSON::Any

    @[JSON::Field(emit_null: false)]
    getter logger : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : NotificationMeta?

    def initialize(@level : LoggingLevel, @data : JSON::Any, @logger : String? = nil,
                   @meta : NotificationMeta? = nil)
    end
  end
end
