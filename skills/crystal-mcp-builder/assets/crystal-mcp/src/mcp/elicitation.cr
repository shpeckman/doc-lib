# src/mcp/elicitation.cr
require "json"

module MCP
  alias ElicitValue = Array(String) | String | Int64 | Bool

  struct StringSchema
    include JSON::Serializable

    getter type : String = "string"

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter default : String?

    @[JSON::Field(emit_null: false)]
    getter format : String?

    @[JSON::Field(key: "minLength", emit_null: false)]
    getter min_length : Int32?

    @[JSON::Field(key: "maxLength", emit_null: false)]
    getter max_length : Int32?

    def initialize(@title : String? = nil, @description : String? = nil, @default : String? = nil,
                   @format : String? = nil, @min_length : Int32? = nil, @max_length : Int32? = nil,
                   @type : String = "string")
    end
  end

  struct NumberSchema
    include JSON::Serializable

    getter type : String

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter default : Float64?

    @[JSON::Field(emit_null: false)]
    getter minimum : Float64?

    @[JSON::Field(emit_null: false)]
    getter maximum : Float64?

    def initialize(@type : String = "number", @title : String? = nil, @description : String? = nil,
                   @default : Float64? = nil, @minimum : Float64? = nil, @maximum : Float64? = nil)
    end

    def self.integer(title : String? = nil, description : String? = nil, default : Float64? = nil,
                     minimum : Float64? = nil, maximum : Float64? = nil) : self
      new(type: "integer", title: title, description: description, default: default,
        minimum: minimum, maximum: maximum)
    end
  end

  struct BooleanSchema
    include JSON::Serializable

    getter type : String = "boolean"

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter default : Bool?

    def initialize(@title : String? = nil, @description : String? = nil, @default : Bool? = nil,
                   @type : String = "boolean")
    end
  end

  struct EnumOption
    include JSON::Serializable

    @[JSON::Field(key: "const")]
    getter value : String

    @[JSON::Field(emit_null: false)]
    getter title : String?

    def initialize(@value : String, @title : String? = nil)
    end
  end

  struct UntitledSingleSelectEnumSchema
    include JSON::Serializable

    getter type : String = "string"

    @[JSON::Field(key: "enum")]
    getter values : Array(String)

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter default : String?

    def initialize(@values : Array(String), @title : String? = nil, @description : String? = nil,
                   @default : String? = nil, @type : String = "string")
    end
  end

  struct TitledSingleSelectEnumSchema
    include JSON::Serializable

    getter type : String = "string"

    @[JSON::Field(key: "oneOf")]
    getter options : Array(EnumOption)

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter default : String?

    def initialize(@options : Array(EnumOption), @title : String? = nil,
                   @description : String? = nil, @default : String? = nil, @type : String = "string")
    end
  end

  struct LegacyTitledEnumSchema
    include JSON::Serializable

    getter type : String = "string"

    @[JSON::Field(key: "enum")]
    getter values : Array(String)

    @[JSON::Field(key: "enumNames")]
    getter enum_names : Array(String)

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter default : String?

    def initialize(@values : Array(String), @enum_names : Array(String), @title : String? = nil,
                   @description : String? = nil, @default : String? = nil, @type : String = "string")
    end
  end

  struct MultiSelectItemsUntitled
    include JSON::Serializable

    @[JSON::Field(key: "enum")]
    getter values : Array(String)

    def initialize(@values : Array(String))
    end
  end

  struct MultiSelectItemsTitled
    include JSON::Serializable

    @[JSON::Field(key: "oneOf")]
    getter options : Array(EnumOption)

    def initialize(@options : Array(EnumOption))
    end
  end

  struct UntitledMultiSelectEnumSchema
    include JSON::Serializable

    getter type : String = "array"
    getter items : MultiSelectItemsUntitled

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter default : Array(String)?

    @[JSON::Field(key: "minItems", emit_null: false)]
    getter min_items : Int32?

    @[JSON::Field(key: "maxItems", emit_null: false)]
    getter max_items : Int32?

    def initialize(@items : MultiSelectItemsUntitled, @title : String? = nil,
                   @description : String? = nil, @default : Array(String)? = nil,
                   @min_items : Int32? = nil, @max_items : Int32? = nil, @type : String = "array")
    end

    def self.values(values : Array(String), title : String? = nil, description : String? = nil,
                    default : Array(String)? = nil, min_items : Int32? = nil, max_items : Int32? = nil) : self
      new(MultiSelectItemsUntitled.new(values), title: title, description: description,
        default: default, min_items: min_items, max_items: max_items)
    end
  end

  struct TitledMultiSelectEnumSchema
    include JSON::Serializable

    getter type : String = "array"
    getter items : MultiSelectItemsTitled

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(emit_null: false)]
    getter default : Array(String)?

    @[JSON::Field(key: "minItems", emit_null: false)]
    getter min_items : Int32?

    @[JSON::Field(key: "maxItems", emit_null: false)]
    getter max_items : Int32?

    def initialize(@items : MultiSelectItemsTitled, @title : String? = nil,
                   @description : String? = nil, @default : Array(String)? = nil,
                   @min_items : Int32? = nil, @max_items : Int32? = nil, @type : String = "array")
    end

    def self.options(options : Array(EnumOption), title : String? = nil, description : String? = nil,
                     default : Array(String)? = nil, min_items : Int32? = nil, max_items : Int32? = nil) : self
      new(MultiSelectItemsTitled.new(options), title: title, description: description,
        default: default, min_items: min_items, max_items: max_items)
    end
  end

  alias PrimitiveSchema = TitledSingleSelectEnumSchema | LegacyTitledEnumSchema |
                          UntitledSingleSelectEnumSchema | TitledMultiSelectEnumSchema |
                          UntitledMultiSelectEnumSchema | NumberSchema | BooleanSchema | StringSchema

  struct ElicitFormSchema
    include JSON::Serializable

    getter type : String = "object"
    getter properties : Hash(String, PrimitiveSchema)

    @[JSON::Field(emit_null: false)]
    getter required : Array(String)?

    @[JSON::Field(key: "$schema", emit_null: false)]
    getter schema : String?

    def initialize(@properties : Hash(String, PrimitiveSchema), @required : Array(String)? = nil,
                   @schema : String? = nil, @type : String = "object")
    end
  end

  struct ElicitFormParams
    include JSON::Serializable

    getter message : String

    @[JSON::Field(key: "requestedSchema")]
    getter requested_schema : ElicitFormSchema

    getter mode : String = "form"

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    def initialize(@message : String, @requested_schema : ElicitFormSchema,
                   @mode : String = "form", @meta : RequestMeta? = nil)
    end
  end

  struct ElicitURLParams
    include JSON::Serializable

    getter message : String
    getter mode : String = "url"

    @[JSON::Field(key: "url")]
    getter url : String

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    def initialize(@message : String, @url : String, @mode : String = "url", @meta : RequestMeta? = nil)
    end
  end

  alias ElicitParams = ElicitURLParams | ElicitFormParams

  struct ElicitResult
    include JSON::Serializable

    getter action : ElicitAction

    @[JSON::Field(emit_null: false)]
    getter content : Hash(String, ElicitValue)?

    def initialize(@action : ElicitAction, @content : Hash(String, ElicitValue)? = nil)
    end

    def self.accept(content : Hash(String, V)) : self forall V
      converted = content.transform_values { |v| v.as(ElicitValue) }
      new(ElicitAction::Accept, converted)
    end

    def self.accept : self
      new(ElicitAction::Accept)
    end

    def self.cancel : self
      new(ElicitAction::Cancel)
    end

    def self.decline : self
      new(ElicitAction::Decline)
    end
  end
end
