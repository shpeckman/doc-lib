# src/mcp/resources.cr
require "json"

module MCP
  struct Resource
    include JSON::Serializable

    getter uri : String
    getter name : String

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(key: "mimeType", emit_null: false)]
    getter mime_type : String?

    @[JSON::Field(emit_null: false)]
    getter size : Int64?

    @[JSON::Field(emit_null: false)]
    getter annotations : Annotations?

    @[JSON::Field(emit_null: false)]
    getter icons : Array(Icon)?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@uri : String, @name : String, @title : String? = nil,
                   @description : String? = nil, @mime_type : String? = nil,
                   @size : Int64? = nil, @annotations : Annotations? = nil,
                   @icons : Array(Icon)? = nil, @meta : Hash(String, JSON::Any)? = nil)
    end
  end

  struct ResourceTemplate
    include JSON::Serializable

    @[JSON::Field(key: "uriTemplate")]
    getter uri_template : String

    getter name : String

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(key: "mimeType", emit_null: false)]
    getter mime_type : String?

    @[JSON::Field(emit_null: false)]
    getter annotations : Annotations?

    @[JSON::Field(emit_null: false)]
    getter icons : Array(Icon)?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@uri_template : String, @name : String, @title : String? = nil,
                   @description : String? = nil, @mime_type : String? = nil,
                   @annotations : Annotations? = nil, @icons : Array(Icon)? = nil,
                   @meta : Hash(String, JSON::Any)? = nil)
    end
  end

  struct TextResourceContents
    include JSON::Serializable

    getter uri : String
    getter text : String

    @[JSON::Field(key: "mimeType", emit_null: false)]
    getter mime_type : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@uri : String, @text : String, @mime_type : String? = nil,
                   @meta : Hash(String, JSON::Any)? = nil)
    end
  end

  struct BlobResourceContents
    include JSON::Serializable

    getter uri : String
    getter blob : String

    @[JSON::Field(key: "mimeType", emit_null: false)]
    getter mime_type : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@uri : String, @blob : String, @mime_type : String? = nil,
                   @meta : Hash(String, JSON::Any)? = nil)
    end
  end

  alias ResourceContents = TextResourceContents | BlobResourceContents

  struct ReadResourceParams
    include JSON::Serializable

    getter uri : String

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    @[JSON::Field(key: "inputResponses", emit_null: false)]
    getter input_responses : Hash(String, JSON::Any)?

    @[JSON::Field(key: "requestState", emit_null: false)]
    getter request_state : String?

    def initialize(@uri : String, @meta : RequestMeta? = nil,
                   @input_responses : Hash(String, JSON::Any)? = nil,
                   @request_state : String? = nil)
    end
  end

  struct ReadResourceResult
    include JSON::Serializable

    getter contents : Array(ResourceContents)

    @[JSON::Field(key: "cacheScope")]
    getter cache_scope : String = CACHE_SCOPE_PRIVATE

    @[JSON::Field(key: "ttlMs")]
    getter ttl_ms : Int64 = 0_i64

    @[JSON::Field(key: "resultType")]
    getter result_type : String = RESULT_TYPE_COMPLETE

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : ResultMeta?

    def initialize(@contents : Array(ResourceContents) = [] of ResourceContents,
                   @cache_scope : String = CACHE_SCOPE_PRIVATE, @ttl_ms : Int64 = 0_i64,
                   @result_type : String = RESULT_TYPE_COMPLETE, @meta : ResultMeta? = nil)
    end
  end

  struct ListResourcesResult
    include JSON::Serializable

    getter resources : Array(Resource)

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

    def initialize(@resources : Array(Resource) = [] of Resource,
                   @cache_scope : String = CACHE_SCOPE_PRIVATE, @ttl_ms : Int64 = 0_i64,
                   @result_type : String = RESULT_TYPE_COMPLETE,
                   @next_cursor : String? = nil, @meta : ResultMeta? = nil)
    end
  end

  struct ListResourceTemplatesResult
    include JSON::Serializable

    @[JSON::Field(key: "resourceTemplates")]
    getter resource_templates : Array(ResourceTemplate)

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

    def initialize(@resource_templates : Array(ResourceTemplate) = [] of ResourceTemplate,
                   @cache_scope : String = CACHE_SCOPE_PRIVATE, @ttl_ms : Int64 = 0_i64,
                   @result_type : String = RESULT_TYPE_COMPLETE,
                   @next_cursor : String? = nil, @meta : ResultMeta? = nil)
    end
  end
end
