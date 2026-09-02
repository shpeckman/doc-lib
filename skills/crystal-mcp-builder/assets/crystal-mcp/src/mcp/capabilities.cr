# src/mcp/capabilities.cr
require "json"

module MCP
  struct ClientCapabilities
    include JSON::Serializable

    struct Roots
      include JSON::Serializable

      def initialize
      end
    end

    struct Sampling
      include JSON::Serializable

      @[JSON::Field(emit_null: false)]
      getter context : Hash(String, JSON::Any)?

      @[JSON::Field(emit_null: false)]
      getter tools : Hash(String, JSON::Any)?

      def initialize(@context : Hash(String, JSON::Any)? = nil, @tools : Hash(String, JSON::Any)? = nil)
      end
    end

    struct Elicitation
      include JSON::Serializable

      @[JSON::Field(emit_null: false)]
      getter form : Hash(String, JSON::Any)?

      @[JSON::Field(emit_null: false)]
      getter url : Hash(String, JSON::Any)?

      def initialize(@form : Hash(String, JSON::Any)? = nil, @url : Hash(String, JSON::Any)? = nil)
      end
    end

    @[JSON::Field(emit_null: false)]
    getter roots : Roots?

    @[JSON::Field(emit_null: false)]
    getter sampling : Sampling?

    @[JSON::Field(emit_null: false)]
    getter elicitation : Elicitation?

    @[JSON::Field(emit_null: false)]
    getter experimental : Hash(String, JSON::Any)?

    @[JSON::Field(emit_null: false)]
    getter extensions : Hash(String, JSON::Any)?

    def initialize(@roots : Roots? = nil, @sampling : Sampling? = nil,
                   @elicitation : Elicitation? = nil,
                   @experimental : Hash(String, JSON::Any)? = nil,
                   @extensions : Hash(String, JSON::Any)? = nil)
    end

    def self.create(*, roots : Bool = false, sampling : Bool = false,
                    sampling_context : Bool = false, sampling_tools : Bool = false,
                    elicitation_form : Bool = false, elicitation_url : Bool = false,
                    extensions : Hash(String, JSON::Any)? = nil,
                    experimental : Hash(String, JSON::Any)? = nil) : self
      sampling_cap : Sampling? = nil
      if sampling || sampling_context || sampling_tools
        empty = Hash(String, JSON::Any).new
        sampling_cap = Sampling.new(context: sampling_context ? empty : nil,
          tools: sampling_tools ? empty : nil)
      end
      elicitation_cap : Elicitation? = nil
      if elicitation_form || elicitation_url
        empty = Hash(String, JSON::Any).new
        elicitation_cap = Elicitation.new(form: elicitation_form ? empty : nil,
          url: elicitation_url ? empty : nil)
      end
      new(roots: roots ? Roots.new : nil, sampling: sampling_cap,
        elicitation: elicitation_cap, experimental: experimental, extensions: extensions)
    end
  end

  struct ServerCapabilities
    include JSON::Serializable

    struct Prompts
      include JSON::Serializable

      @[JSON::Field(key: "listChanged", emit_null: false)]
      getter list_changed : Bool?

      def initialize(@list_changed : Bool? = nil)
      end
    end

    struct Resources
      include JSON::Serializable

      @[JSON::Field(key: "listChanged", emit_null: false)]
      getter list_changed : Bool?

      @[JSON::Field(emit_null: false)]
      getter subscribe : Bool?

      def initialize(@list_changed : Bool? = nil, @subscribe : Bool? = nil)
      end
    end

    struct Tools
      include JSON::Serializable

      @[JSON::Field(key: "listChanged", emit_null: false)]
      getter list_changed : Bool?

      def initialize(@list_changed : Bool? = nil)
      end
    end

    @[JSON::Field(emit_null: false)]
    getter completions : Hash(String, JSON::Any)?

    @[JSON::Field(emit_null: false)]
    getter logging : Hash(String, JSON::Any)?

    @[JSON::Field(emit_null: false)]
    getter prompts : Prompts?

    @[JSON::Field(emit_null: false)]
    getter resources : Resources?

    @[JSON::Field(emit_null: false)]
    getter tools : Tools?

    @[JSON::Field(emit_null: false)]
    getter experimental : Hash(String, JSON::Any)?

    @[JSON::Field(emit_null: false)]
    getter extensions : Hash(String, JSON::Any)?

    def initialize(@completions : Hash(String, JSON::Any)? = nil,
                   @logging : Hash(String, JSON::Any)? = nil,
                   @prompts : Prompts? = nil, @resources : Resources? = nil,
                   @tools : Tools? = nil,
                   @experimental : Hash(String, JSON::Any)? = nil,
                   @extensions : Hash(String, JSON::Any)? = nil)
    end

    def self.create(*, completions : Bool = false, logging : Bool = false,
                    prompts : Bool = false, prompts_list_changed : Bool = false,
                    resources : Bool = false, resources_list_changed : Bool = false,
                    resources_subscribe : Bool = false,
                    tools : Bool = false, tools_list_changed : Bool = false,
                    extensions : Hash(String, JSON::Any)? = nil,
                    experimental : Hash(String, JSON::Any)? = nil) : self
      new(completions: completions ? Hash(String, JSON::Any).new : nil,
        logging: logging ? Hash(String, JSON::Any).new : nil,
        prompts: (prompts || prompts_list_changed) ? Prompts.new(list_changed: prompts_list_changed ? true : nil) : nil,
        resources: (resources || resources_list_changed || resources_subscribe) ? Resources.new(list_changed: resources_list_changed ? true : nil, subscribe: resources_subscribe ? true : nil) : nil,
        tools: (tools || tools_list_changed) ? Tools.new(list_changed: tools_list_changed ? true : nil) : nil,
        experimental: experimental, extensions: extensions)
    end
  end
end
