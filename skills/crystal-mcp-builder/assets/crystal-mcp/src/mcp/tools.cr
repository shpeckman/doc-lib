# src/mcp/tools.cr
require "json"

module MCP
  struct ToolAnnotations
    include JSON::Serializable

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(key: "readOnlyHint", emit_null: false)]
    getter read_only_hint : Bool?

    @[JSON::Field(key: "destructiveHint", emit_null: false)]
    getter destructive_hint : Bool?

    @[JSON::Field(key: "idempotentHint", emit_null: false)]
    getter idempotent_hint : Bool?

    @[JSON::Field(key: "openWorldHint", emit_null: false)]
    getter open_world_hint : Bool?

    def initialize(@title : String? = nil, @read_only_hint : Bool? = nil,
                   @destructive_hint : Bool? = nil, @idempotent_hint : Bool? = nil,
                   @open_world_hint : Bool? = nil)
    end
  end

  struct Tool
    include JSON::Serializable

    getter name : String

    @[JSON::Field(key: "inputSchema")]
    getter input_schema : Hash(String, JSON::Any)

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(key: "outputSchema", emit_null: false)]
    getter output_schema : Hash(String, JSON::Any)?

    @[JSON::Field(emit_null: false)]
    getter annotations : ToolAnnotations?

    @[JSON::Field(emit_null: false)]
    getter icons : Array(Icon)?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@name : String, @input_schema : Hash(String, JSON::Any) = Hash(String, JSON::Any).new,
                   @title : String? = nil, @description : String? = nil,
                   @output_schema : Hash(String, JSON::Any)? = nil,
                   @annotations : ToolAnnotations? = nil, @icons : Array(Icon)? = nil,
                   @meta : Hash(String, JSON::Any)? = nil)
    end

    def display_title : String
      @annotations.try(&.title) || @title || @name
    end
  end

  struct PaginatedParams
    include JSON::Serializable

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    @[JSON::Field(emit_null: false)]
    getter cursor : String?

    def initialize(@meta : RequestMeta? = nil, @cursor : String? = nil)
    end
  end

  struct CallToolParams
    include JSON::Serializable

    getter name : String

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    @[JSON::Field(emit_null: false)]
    getter arguments : Hash(String, JSON::Any)?

    @[JSON::Field(key: "inputResponses", emit_null: false)]
    getter input_responses : Hash(String, JSON::Any)?

    @[JSON::Field(key: "requestState", emit_null: false)]
    getter request_state : String?

    def initialize(@name : String, @meta : RequestMeta? = nil,
                   @arguments : Hash(String, JSON::Any)? = nil,
                   @input_responses : Hash(String, JSON::Any)? = nil,
                   @request_state : String? = nil)
    end
  end

  struct CallToolResult
    include JSON::Serializable

    getter content : Array(ContentBlock)

    @[JSON::Field(key: "resultType")]
    getter result_type : String = RESULT_TYPE_COMPLETE

    @[JSON::Field(key: "isError", emit_null: false)]
    getter is_error : Bool?

    @[JSON::Field(key: "structuredContent", emit_null: false)]
    getter structured_content : JSON::Any?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : ResultMeta?

    def initialize(@content : Array(ContentBlock) = [] of ContentBlock,
                   @result_type : String = RESULT_TYPE_COMPLETE, @is_error : Bool? = nil,
                   @structured_content : JSON::Any? = nil, @meta : ResultMeta? = nil)
    end

    def self.error(message : String) : self
      new(content: [TextContent.new(message)] of ContentBlock, is_error: true)
    end

    def self.text(text : String) : self
      new(content: [TextContent.new(text)] of ContentBlock)
    end

    def error? : Bool
      @is_error == true
    end

    def text : String
      String.build do |io|
        @content.each do |block|
          io << block.text if block.is_a?(TextContent)
        end
      end
    end
  end

  struct ListToolsResult
    include JSON::Serializable

    getter tools : Array(Tool)

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

    def initialize(@tools : Array(Tool) = [] of Tool, @cache_scope : String = CACHE_SCOPE_PRIVATE,
                   @ttl_ms : Int64 = 0_i64, @result_type : String = RESULT_TYPE_COMPLETE,
                   @next_cursor : String? = nil, @meta : ResultMeta? = nil)
    end
  end
end
