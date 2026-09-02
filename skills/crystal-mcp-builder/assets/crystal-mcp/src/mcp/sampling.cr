# src/mcp/sampling.cr
require "json"

module MCP
  struct ModelHint
    include JSON::Serializable

    @[JSON::Field(emit_null: false)]
    getter name : String?

    def initialize(@name : String? = nil)
    end
  end

  struct ModelPreferences
    include JSON::Serializable

    @[JSON::Field(emit_null: false)]
    getter hints : Array(ModelHint)?

    @[JSON::Field(key: "costPriority", emit_null: false)]
    getter cost_priority : Float64?

    @[JSON::Field(key: "intelligencePriority", emit_null: false)]
    getter intelligence_priority : Float64?

    @[JSON::Field(key: "speedPriority", emit_null: false)]
    getter speed_priority : Float64?

    def initialize(@hints : Array(ModelHint)? = nil, @cost_priority : Float64? = nil,
                   @intelligence_priority : Float64? = nil, @speed_priority : Float64? = nil)
    end
  end

  struct ToolChoice
    include JSON::Serializable

    @[JSON::Field(emit_null: false)]
    getter mode : String?

    def initialize(@mode : String? = nil)
    end
  end

  struct CreateMessageParams
    include JSON::Serializable

    getter messages : Array(SamplingMessage)

    @[JSON::Field(key: "maxTokens")]
    getter max_tokens : Int32

    @[JSON::Field(key: "includeContext", emit_null: false)]
    getter include_context : String?

    @[JSON::Field(key: "modelPreferences", emit_null: false)]
    getter model_preferences : ModelPreferences?

    @[JSON::Field(key: "systemPrompt", emit_null: false)]
    getter system_prompt : String?

    @[JSON::Field(key: "stopSequences", emit_null: false)]
    getter stop_sequences : Array(String)?

    @[JSON::Field(emit_null: false)]
    getter temperature : Float64?

    @[JSON::Field(emit_null: false)]
    getter metadata : Hash(String, JSON::Any)?

    @[JSON::Field(emit_null: false)]
    getter tools : Array(Tool)?

    @[JSON::Field(key: "toolChoice", emit_null: false)]
    getter tool_choice : ToolChoice?

    def initialize(@messages : Array(SamplingMessage), @max_tokens : Int32,
                   @include_context : String? = nil, @model_preferences : ModelPreferences? = nil,
                   @system_prompt : String? = nil, @stop_sequences : Array(String)? = nil,
                   @temperature : Float64? = nil, @metadata : Hash(String, JSON::Any)? = nil,
                   @tools : Array(Tool)? = nil, @tool_choice : ToolChoice? = nil)
    end
  end

  struct CreateMessageResult
    include JSON::Serializable

    getter role : Role
    getter model : String
    getter content : ContentBlock | Array(ContentBlock)

    @[JSON::Field(key: "stopReason", emit_null: false)]
    getter stop_reason : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@role : Role, @model : String, @content : ContentBlock | Array(ContentBlock),
                   @stop_reason : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
    end

    def self.text(model : String, text : String, role : Role = Role::Assistant) : self
      new(role, model, TextContent.new(text))
    end

    def text : String
      case c = @content
      in TextContent
        c.text
      in Array(ContentBlock)
        String.build do |io|
          c.each { |b| io << b.text if b.is_a?(TextContent) }
        end
      in ContentBlock
        ""
      end
    end
  end
end
