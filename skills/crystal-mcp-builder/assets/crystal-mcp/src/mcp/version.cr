# src/mcp/version.cr
module MCP
  VERSION                    = "0.1.0"
  PROTOCOL_VERSION           = "2026-07-28"
  SUPPORTED_PROTOCOL_VERSIONS = [PROTOCOL_VERSION]

  RESULT_TYPE_COMPLETE       = "complete"
  RESULT_TYPE_INPUT_REQUIRED = "input_required"

  CACHE_SCOPE_PUBLIC  = "public"
  CACHE_SCOPE_PRIVATE = "private"
end
