# src/mcp/content.cr
require "json"

module MCP
  abstract class ContentBlock
    include JSON::Serializable

    use_json_discriminator "type", {
      text:          TextContent,
      image:         ImageContent,
      audio:         AudioContent,
      resource:      EmbeddedResource,
      resource_link: ResourceLink,
      tool_use:      ToolUseContent,
      tool_result:   ToolResultContent,
    }

  end

  class TextContent < ContentBlock
    include JSON::Serializable
    getter type : String = "text"
    getter text : String

    @[JSON::Field(emit_null: false)]
    getter annotations : Annotations?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@text : String, @annotations : Annotations? = nil, @meta : Hash(String, JSON::Any)? = nil)
    end

  end

  class ImageContent < ContentBlock
    include JSON::Serializable
    getter type : String = "image"
    getter data : String

    @[JSON::Field(key: "mimeType")]
    getter mime_type : String

    @[JSON::Field(emit_null: false)]
    getter annotations : Annotations?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@data : String, @mime_type : String, @annotations : Annotations? = nil, @meta : Hash(String, JSON::Any)? = nil)
    end

  end

  class AudioContent < ContentBlock
    include JSON::Serializable
    getter type : String = "audio"
    getter data : String

    @[JSON::Field(key: "mimeType")]
    getter mime_type : String

    @[JSON::Field(emit_null: false)]
    getter annotations : Annotations?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@data : String, @mime_type : String, @annotations : Annotations? = nil, @meta : Hash(String, JSON::Any)? = nil)
    end

  end

  class ResourceLink < ContentBlock
    include JSON::Serializable
    getter type : String = "resource_link"
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
    getter icons : Array(Icon)?

    @[JSON::Field(emit_null: false)]
    getter annotations : Annotations?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@uri : String, @name : String, @title : String? = nil,
                   @description : String? = nil, @mime_type : String? = nil,
                   @size : Int64? = nil, @icons : Array(Icon)? = nil,
                   @annotations : Annotations? = nil, @meta : Hash(String, JSON::Any)? = nil)
    end

  end

  class EmbeddedResource < ContentBlock
    include JSON::Serializable
    getter type : String = "resource"
    getter resource : TextResourceContents | BlobResourceContents

    @[JSON::Field(emit_null: false)]
    getter annotations : Annotations?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@resource : TextResourceContents | BlobResourceContents,
                   @annotations : Annotations? = nil, @meta : Hash(String, JSON::Any)? = nil)
    end

  end

  class ToolUseContent < ContentBlock
    include JSON::Serializable
    getter type : String = "tool_use"
    getter id : String
    getter name : String
    getter input : Hash(String, JSON::Any)

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@id : String, @name : String, @input : Hash(String, JSON::Any) = Hash(String, JSON::Any).new,
                   @meta : Hash(String, JSON::Any)? = nil)
    end

  end

  class ToolResultContent < ContentBlock
    include JSON::Serializable
    getter type : String = "tool_result"
    @[JSON::Field(key: "toolUseId")]
    getter tool_use_id : String

    getter content : Array(ContentBlock)

    @[JSON::Field(key: "isError", emit_null: false)]
    getter is_error : Bool?

    @[JSON::Field(key: "structuredContent", emit_null: false)]
    getter structured_content : JSON::Any?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@tool_use_id : String, @content : Array(ContentBlock) = [] of ContentBlock,
                   @is_error : Bool? = nil, @structured_content : JSON::Any? = nil,
                   @meta : Hash(String, JSON::Any)? = nil)
    end

  end

  struct SamplingMessage
    include JSON::Serializable

    getter role : Role
    getter content : ContentBlock | Array(ContentBlock)

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@role : Role, @content : ContentBlock | Array(ContentBlock), @meta : Hash(String, JSON::Any)? = nil)
    end

    def self.text(role : Role, text : String) : self
      new(role, TextContent.new(text))
    end
  end
end
