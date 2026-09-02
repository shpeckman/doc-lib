# src/mcp/methods.cr
module MCP
  module Methods
    DISCOVER                 = "server/discover"
    LIST_TOOLS               = "tools/list"
    CALL_TOOL                = "tools/call"
    LIST_RESOURCES           = "resources/list"
    LIST_RESOURCE_TEMPLATES  = "resources/templates/list"
    READ_RESOURCE            = "resources/read"
    LIST_PROMPTS             = "prompts/list"
    GET_PROMPT               = "prompts/get"
    COMPLETE                 = "completion/complete"
    LISTEN                   = "subscriptions/listen"
    CREATE_MESSAGE           = "sampling/createMessage"
    LIST_ROOTS               = "roots/list"
    ELICIT                   = "elicitation/create"
    NOTIF_CANCELLED          = "notifications/cancelled"
    NOTIF_PROGRESS           = "notifications/progress"
    NOTIF_MESSAGE            = "notifications/message"
    NOTIF_TOOLS_CHANGED      = "notifications/tools/list_changed"
    NOTIF_RESOURCES_CHANGED  = "notifications/resources/list_changed"
    NOTIF_RESOURCE_UPDATED   = "notifications/resources/updated"
    NOTIF_PROMPTS_CHANGED    = "notifications/prompts/list_changed"
    NOTIF_SUBS_ACKNOWLEDGED  = "notifications/subscriptions/acknowledged"
  end

  META_PROTOCOL_VERSION     = "io.modelcontextprotocol/protocolVersion"
  META_CLIENT_CAPABILITIES  = "io.modelcontextprotocol/clientCapabilities"
  META_CLIENT_INFO          = "io.modelcontextprotocol/clientInfo"
  META_LOG_LEVEL            = "io.modelcontextprotocol/logLevel"
  META_PROGRESS_TOKEN       = "progressToken"
  META_SERVER_INFO          = "io.modelcontextprotocol/serverInfo"
  META_SUBSCRIPTION_ID      = "io.modelcontextprotocol/subscriptionId"
end
