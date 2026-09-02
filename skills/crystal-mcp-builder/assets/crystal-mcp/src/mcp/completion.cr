# src/mcp/completion.cr
require "json"

module MCP
  struct PromptReference
    include JSON::Serializable

    getter type : String = "ref/prompt"
    getter name : String

    @[JSON::Field(emit_null: false)]
    getter title : String?

    def initialize(@name : String, @title : String? = nil, @type : String = "ref/prompt")
    end
  end

  struct ResourceTemplateReference
    include JSON::Serializable

    getter type : String = "ref/resource"
    getter uri : String

    def initialize(@uri : String, @type : String = "ref/resource")
    end
  end

  alias CompletionReference = PromptReference | ResourceTemplateReference

  struct CompletionArgument
    include JSON::Serializable

    getter name : String
    getter value : String

    def initialize(@name : String, @value : String)
    end
  end

  struct CompletionContext
    include JSON::Serializable

    @[JSON::Field(emit_null: false)]
    getter arguments : Hash(String, String)?

    def initialize(@arguments : Hash(String, String)? = nil)
    end
  end

  struct CompleteParams
    include JSON::Serializable

    getter ref : CompletionReference
    getter argument : CompletionArgument

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    @[JSON::Field(emit_null: false)]
    getter context : CompletionContext?

    def initialize(@ref : CompletionReference, @argument : CompletionArgument,
                   @meta : RequestMeta? = nil, @context : CompletionContext? = nil)
    end
  end

  struct CompletionValues
    include JSON::Serializable

    getter values : Array(String)

    @[JSON::Field(emit_null: false)]
    getter total : Int32?

    @[JSON::Field(key: "hasMore", emit_null: false)]
    getter has_more : Bool?

    def initialize(@values : Array(String), @total : Int32? = nil, @has_more : Bool? = nil)
    end
  end

  struct CompleteResult
    include JSON::Serializable

    getter completion : CompletionValues

    @[JSON::Field(key: "resultType")]
    getter result_type : String = RESULT_TYPE_COMPLETE

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : ResultMeta?

    def initialize(@completion : CompletionValues, @result_type : String = RESULT_TYPE_COMPLETE,
                   @meta : ResultMeta? = nil)
    end

    def self.values(values : Array(String)) : self
      new(CompletionValues.new(values))
    end
  end
end
