# src/mcp/prompts.cr
require "json"

module MCP
  struct PromptArgument
    include JSON::Serializable

    getter name : String

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter required : Bool?

    def initialize(@name : String, @title : String? = nil, @description : String? = nil, @required : Bool? = nil)
    end
  end

  struct Prompt
    include JSON::Serializable

    getter name : String

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter arguments : Array(PromptArgument)?

    @[JSON::Field(emit_null: false)]
    getter icons : Array(Icon)?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@name : String, @title : String? = nil, @description : String? = nil,
                   @arguments : Array(PromptArgument)? = nil, @icons : Array(Icon)? = nil,
                   @meta : Hash(String, JSON::Any)? = nil)
    end
  end

  struct PromptMessage
    include JSON::Serializable

    getter role : Role
    getter content : ContentBlock

    def initialize(@role : Role, @content : ContentBlock)
    end

    def self.user(text : String) : self
      new(Role::User, TextContent.new(text))
    end

    def self.assistant(text : String) : self
      new(Role::Assistant, TextContent.new(text))
    end
  end

  struct GetPromptParams
    include JSON::Serializable

    getter name : String

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    @[JSON::Field(emit_null: false)]
    getter arguments : Hash(String, String)?

    @[JSON::Field(key: "inputResponses", emit_null: false)]
    getter input_responses : Hash(String, JSON::Any)?

    @[JSON::Field(key: "requestState", emit_null: false)]
    getter request_state : String?

    def initialize(@name : String, @meta : RequestMeta? = nil,
                   @arguments : Hash(String, String)? = nil,
                   @input_responses : Hash(String, JSON::Any)? = nil,
                   @request_state : String? = nil)
    end
  end

  struct GetPromptResult
    include JSON::Serializable

    getter messages : Array(PromptMessage)

    @[JSON::Field(key: "resultType")]
    getter result_type : String = RESULT_TYPE_COMPLETE

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : ResultMeta?

    def initialize(@messages : Array(PromptMessage) = [] of PromptMessage,
                   @result_type : String = RESULT_TYPE_COMPLETE,
                   @description : String? = nil, @meta : ResultMeta? = nil)
    end
  end

  struct ListPromptsResult
    include JSON::Serializable

    getter prompts : Array(Prompt)

    @[JSON::Field(key: "cacheScope")]
    getter cache_scope : String = CACHE_SCOPE_PRIVATE

    @[JSON::Field(key: "ttlMs")]
    getter ttl_ms : Int64 = 0_i64

    @[JSON::Field(key: "resultType")]
    getter result_type : String = RESULT_TYPE_COMPLETE

    @[JSON::Field(key: "nextCursor", emit_null: false)]
    getter next_cursor : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : ResultMeta?

    def initialize(@prompts : Array(Prompt) = [] of Prompt,
                   @cache_scope : String = CACHE_SCOPE_PRIVATE, @ttl_ms : Int64 = 0_i64,
                   @result_type : String = RESULT_TYPE_COMPLETE,
                   @next_cursor : String? = nil, @meta : ResultMeta? = nil)
    end
  end
end
