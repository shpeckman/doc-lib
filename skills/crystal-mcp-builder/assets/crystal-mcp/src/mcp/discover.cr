# src/mcp/discover.cr
require "json"

module MCP
  struct DiscoverResult
    include JSON::Serializable

    @[JSON::Field(key: "supportedVersions")]
    getter supported_versions : Array(String)

    getter capabilities : ServerCapabilities

    @[JSON::Field(key: "cacheScope")]
    getter cache_scope : String = CACHE_SCOPE_PRIVATE

    @[JSON::Field(key: "ttlMs")]
    getter ttl_ms : Int64 = 0_i64

    @[JSON::Field(key: "resultType")]
    getter result_type : String = RESULT_TYPE_COMPLETE

    @[JSON::Field(emit_null: false)]
    getter instructions : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : ResultMeta?

    def initialize(@supported_versions : Array(String) = SUPPORTED_PROTOCOL_VERSIONS.dup,
                   @capabilities : ServerCapabilities = ServerCapabilities.new,
                   @cache_scope : String = CACHE_SCOPE_PRIVATE, @ttl_ms : Int64 = 0_i64,
                   @result_type : String = RESULT_TYPE_COMPLETE, @instructions : String? = nil,
                   @meta : ResultMeta? = nil)
    end
  end
end
