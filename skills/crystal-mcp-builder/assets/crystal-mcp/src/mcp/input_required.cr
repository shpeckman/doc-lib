# src/mcp/input_required.cr
require "json"

module MCP
  struct InputRequiredResult
    include JSON::Serializable

    @[JSON::Field(key: "resultType")]
    getter result_type : String = RESULT_TYPE_INPUT_REQUIRED

    @[JSON::Field(key: "inputRequests", emit_null: false)]
    getter input_requests : Hash(String, JSON::Any)?

    @[JSON::Field(key: "requestState", emit_null: false)]
    getter request_state : String?

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : ResultMeta?

    def initialize(@result_type : String = RESULT_TYPE_INPUT_REQUIRED,
                   @input_requests : Hash(String, JSON::Any)? = nil,
                   @request_state : String? = nil, @meta : ResultMeta? = nil)
    end
  end

  def self.input_required?(result : JSON::Any) : Bool
    h = result.as_h?
    return false unless h
    v = h["resultType"]?
    return false unless v
    v.as_s? == RESULT_TYPE_INPUT_REQUIRED
  end
end
