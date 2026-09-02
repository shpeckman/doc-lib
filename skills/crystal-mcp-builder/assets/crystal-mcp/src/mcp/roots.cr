# src/mcp/roots.cr
require "json"

module MCP
  struct Root
    include JSON::Serializable

    getter uri : String

    @[JSON::Field(emit_null: false)]
    getter name : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@uri : String, @name : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
    end
  end

  struct ListRootsResult
    include JSON::Serializable

    getter roots : Array(Root)

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : Hash(String, JSON::Any)?

    def initialize(@roots : Array(Root) = [] of Root, @meta : Hash(String, JSON::Any)? = nil)
    end
  end
end
