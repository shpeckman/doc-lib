# src/mcp/common.cr
require "json"

module MCP
  enum Role
    Assistant
    User

    def self.new(pull : JSON::PullParser) : self
      case value = pull.read_string
      when "assistant" then Assistant
      when "user"      then User
      else                  raise JSON::ParseException.new("invalid Role: #{value}", pull.line_number, pull.column_number)
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s.downcase)
    end
  end

  enum LoggingLevel
    Debug
    Info
    Notice
    Warning
    Error
    Critical
    Alert
    Emergency

    def self.new(pull : JSON::PullParser) : self
      case value = pull.read_string
      when "debug"     then Debug
      when "info"      then Info
      when "notice"    then Notice
      when "warning"   then Warning
      when "error"     then Error
      when "critical"  then Critical
      when "alert"     then Alert
      when "emergency" then Emergency
      else                  raise JSON::ParseException.new("invalid LoggingLevel: #{value}", pull.line_number, pull.column_number)
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s.downcase)
    end
  end

  enum ElicitAction
    Accept
    Cancel
    Decline

    def self.new(pull : JSON::PullParser) : self
      case value = pull.read_string
      when "accept"  then Accept
      when "cancel"  then Cancel
      when "decline" then Decline
      else                raise JSON::ParseException.new("invalid ElicitAction: #{value}", pull.line_number, pull.column_number)
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s.downcase)
    end
  end

  struct Annotations
    include JSON::Serializable

    @[JSON::Field(emit_null: false)]
    getter audience : Array(Role)?

    @[JSON::Field(emit_null: false)]
    getter priority : Float64?

    @[JSON::Field(key: "lastModified", emit_null: false)]
    getter last_modified : String?

    def initialize(@audience : Array(Role)? = nil, @priority : Float64? = nil, @last_modified : String? = nil)
    end
  end

  struct Icon
    include JSON::Serializable

    getter src : String

    @[JSON::Field(key: "mimeType", emit_null: false)]
    getter mime_type : String?

    @[JSON::Field(emit_null: false)]
    getter sizes : Array(String)?

    @[JSON::Field(emit_null: false)]
    getter theme : String?

    def initialize(@src : String, @mime_type : String? = nil, @sizes : Array(String)? = nil, @theme : String? = nil)
    end
  end

  struct Implementation
    include JSON::Serializable

    getter name : String
    getter version : String

    @[JSON::Field(emit_null: false)]
    getter title : String?

    @[JSON::Field(emit_null: false)]
    getter description : String?

    @[JSON::Field(key: "websiteUrl", emit_null: false)]
    getter website_url : String?

    @[JSON::Field(emit_null: false)]
    getter icons : Array(Icon)?

    def initialize(@name : String, @version : String, @title : String? = nil,
                   @description : String? = nil, @website_url : String? = nil,
                   @icons : Array(Icon)? = nil)
    end
  end
end
