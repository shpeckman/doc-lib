# src/mcp/json_rpc.cr
require "json"

module MCP
  alias RequestId = String | Int64
  alias ProgressToken = String | Int64
  alias AnyHash = Hash(String, JSON::Any)
  alias Cursor = String

  module ErrorCodes
    PARSE_ERROR                        = -32700
    INVALID_REQUEST                    = -32600
    METHOD_NOT_FOUND                   = -32601
    INVALID_PARAMS                     = -32602
    INTERNAL_ERROR                     = -32603
    HEADER_MISMATCH                    = -32020
    MISSING_REQUIRED_CLIENT_CAPABILITY = -32021
    UNSUPPORTED_PROTOCOL_VERSION       = -32022
  end

  struct ErrorObject
    include JSON::Serializable

    getter code : Int32
    getter message : String

    @[JSON::Field(emit_null: false)]
    getter data : JSON::Any?

    def initialize(@code : Int32, @message : String, @data : JSON::Any? = nil)
    end
  end

  class RpcError < Exception
    getter code : Int32
    getter data : JSON::Any?

    def initialize(@code : Int32, message : String, @data : JSON::Any? = nil)
      super(message)
    end

    def to_error_object : ErrorObject
      ErrorObject.new(@code, message || "error", @data)
    end
  end

  struct Envelope
    getter id : RequestId?
    getter method : String?
    getter params : JSON::Any?
    getter result : JSON::Any?
    getter error : ErrorObject?

    def initialize(@id : RequestId?, @method : String?, @params : JSON::Any?, @result : JSON::Any?, @error : ErrorObject?)
    end

    def self.parse(json : String) : Envelope
      parse(JSON::PullParser.new(json))
    end

    def self.parse(pull : JSON::PullParser) : Envelope
      id : RequestId? = nil
      method : String? = nil
      params : JSON::Any? = nil
      result : JSON::Any? = nil
      error : ErrorObject? = nil
      pull.read_object do |key|
        case key
        when "jsonrpc"
          pull.read_string
        when "id"
          if pull.kind.string?
            id = pull.read_string
          else
            id = pull.read_int
          end
        when "method" then method = pull.read_string
        when "params" then params = JSON::Any.new(pull)
        when "result" then result = JSON::Any.new(pull)
        when "error"  then error = ErrorObject.new(pull)
        else               pull.skip
        end
      end
      new(id, method, params, result, error)
    end

    def request? : Bool
      !@id.nil? && !@method.nil?
    end

    def notification? : Bool
      @id.nil? && !@method.nil?
    end

    def response? : Bool
      @method.nil? && (!@result.nil? || !@error.nil?)
    end
  end

  def self.request_json(id : RequestId, method : String, params : P) : String forall P
    JSON.build do |json|
      json.object do
        json.field "jsonrpc", "2.0"
        json.field "id", id
        json.field "method", method
        json.field "params", params unless params.nil?
      end
    end
  end

  def self.request_json(id : RequestId, method : String) : String
    request_json(id, method, nil)
  end

  def self.notification_json(method : String, params : P) : String forall P
    JSON.build do |json|
      json.object do
        json.field "jsonrpc", "2.0"
        json.field "method", method
        json.field "params", params unless params.nil?
      end
    end
  end

  def self.notification_json(method : String) : String
    notification_json(method, nil)
  end

  def self.result_json(id : RequestId, result : R) : String forall R
    JSON.build do |json|
      json.object do
        json.field "jsonrpc", "2.0"
        json.field "id", id
        json.field "result", result
      end
    end
  end

  def self.error_json(id : RequestId?, error : ErrorObject) : String
    JSON.build do |json|
      json.object do
        json.field "jsonrpc", "2.0"
        if id.nil?
          json.field "id", nil
        else
          json.field "id", id
        end
        json.field "error", error
      end
    end
  end

  def self.to_any(value : V) : JSON::Any forall V
    JSON.parse(value.to_json)
  end
end
