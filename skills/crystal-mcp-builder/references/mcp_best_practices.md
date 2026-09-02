# MCP Server Best Practices

Language-agnostic guidelines, adapted for Crystal servers built with the crystal-mcp shard.

## Quick Reference

### Server Naming
- **Crystal shard**: `{service}-mcp` (e.g., `slack-mcp`) — matches shard naming rules and the vendored `mcp` shard itself

### Tool Naming
- snake_case with service prefix
- Format: `{service}_{action}_{resource}`
- Example: `slack_send_message`, `github_create_issue`

### Response Formats
- Support both JSON and Markdown formats
- JSON for programmatic processing
- Markdown for human readability

### Pagination
- Always respect the `limit` parameter
- Return `has_more`, `next_offset`, `total_count`
- Default to 20-50 items

### Transport
- **Streamable HTTP** (`server.run_http`): for remote servers, multi-client scenarios
- **stdio** (`server.run_stdio`): for local integrations, command-line tools
- Avoid legacy SSE-only transports (superseded by Streamable HTTP)

---

## Server Naming Conventions

**Crystal**: shard name `{service}-mcp` (lowercase with hyphens)
- Examples: `slack-mcp`, `github-mcp`, `jira-mcp`
- Use the same string for `MCP::Implementation.new(name: ...)`

The name should be general, descriptive of the service being integrated, easy to infer from the task description, and without version numbers.

---

## Tool Naming and Design

### Tool Naming

1. **Use snake_case**: `search_users`, `create_project`, `get_channel_info`
2. **Include service prefix**: Anticipate that your MCP server may be used alongside other MCP servers
   - Use `slack_send_message` instead of just `send_message`
   - Use `github_create_issue` instead of just `create_issue`
3. **Be action-oriented**: Start with verbs (get, list, search, create, etc.)
4. **Be specific**: Avoid generic names that could conflict with other servers

### Tool Design

- Tool descriptions must narrowly and unambiguously describe functionality
- Descriptions must precisely match actual functionality
- Provide tool annotations (readOnlyHint, destructiveHint, idempotentHint, openWorldHint)
- Keep tool operations focused and atomic

---

## Response Formats

All tools that return data should support multiple formats via a `response_format` parameter:

### JSON Format (`response_format="json"`)
- Machine-readable structured data
- Include all available fields and metadata
- Consistent field names and types
- Use for programmatic processing

### Markdown Format (`response_format="markdown"`, typically default)
- Human-readable formatted text
- Use headers, lists, and formatting for clarity
- Convert timestamps to human-readable format
- Show display names with IDs in parentheses
- Omit verbose metadata

---

## Pagination

For tools that list resources:

- **Always respect the `limit` parameter**
- **Implement pagination**: Use `offset` or cursor-based pagination
- **Return pagination metadata**: Include `has_more`, `next_offset`/`next_cursor`, `total_count`
- **Never load all results into memory**: Especially important for large datasets
- **Default to reasonable limits**: 20-50 items is typical

Example pagination response:

```json
{
  "total": 150,
  "count": 20,
  "offset": 0,
  "items": [],
  "has_more": true,
  "next_offset": 20
}
```

The protocol's own `list` endpoints (`tools/list`, `resources/list`, ...) are paginated automatically by the shard (offset cursors, configurable `page_size:`).

---

## Transport Options

### Streamable HTTP

**Best for**: Remote servers, web services, multi-client scenarios

**Characteristics**:
- Bidirectional communication over HTTP (POST for requests, GET SSE stream for server-initiated traffic)
- Supports multiple simultaneous clients (per-session `MCP-Session-Id`)
- Can be deployed as a web service
- Enables server-to-client notifications

**Use when**:
- Serving multiple clients simultaneously
- Deploying as a cloud service
- Integration with web applications

In crystal-mcp: `server.run_http(host:, port:, path:)`.

### stdio

**Best for**: Local integrations, command-line tools

**Characteristics**:
- Standard input/output stream communication
- Simple setup, no network configuration needed
- Runs as a subprocess of the client

**Use when**:
- Building tools for local development environments
- Integrating with desktop applications
- Single-user, single-session scenarios

In crystal-mcp: `server.run_stdio`.

**Note**: stdio servers must NOT log to stdout (use STDERR for logging)

### Transport Selection

| Criterion | stdio | Streamable HTTP |
|-----------|-------|-----------------|
| **Deployment** | Local | Remote |
| **Clients** | Single | Multiple |
| **Complexity** | Low | Medium |
| **Real-time notifications** | No | Yes |

---

## Security Best Practices

### Authentication and Authorization

**OAuth 2.1**:
- Put remote HTTP servers behind OAuth 2.1 with certificates from recognized authorities (typically via a reverse proxy — the shard does not implement auth)
- Validate access tokens before processing requests
- Only accept tokens specifically intended for your server

**API Keys**:
- Store API keys in environment variables, never in code
- Validate keys on server startup (`ENV["..."]? || raise ...`)
- Provide clear error messages when authentication fails

### Input Validation

- Sanitize file paths to prevent directory traversal
- Validate URLs and external identifiers
- Check parameter sizes and ranges
- Prevent command injection in system calls (never interpolate args into shell strings; use `Process.run` with separate arguments)
- Use JSON Schema constraints (`enum`, `minimum`, `pattern`) for all inputs, and validate business rules in the handler

### Error Handling

- Don't expose internal errors to clients — the shard forwards raw exception messages as internal errors, so rescue broadly in handlers and return sanitized `MCP::CallToolResult.error` text
- Log security-relevant errors server-side
- Provide helpful but not revealing error messages
- Clean up resources after errors

### DNS Rebinding Protection

For Streamable HTTP servers running locally:
- Bind to `127.0.0.1` rather than `0.0.0.0` (the `run_http` default)
- Validate the `Origin` header on incoming connections when binding beyond localhost

---

## Tool Annotations

Provide annotations to help clients understand tool behavior:

| Annotation | Type | Default | Description |
|-----------|------|---------|-------------|
| `readOnlyHint` | boolean | false | Tool does not modify its environment |
| `destructiveHint` | boolean | true | Tool may perform destructive updates |
| `idempotentHint` | boolean | false | Repeated calls with same args have no additional effect |
| `openWorldHint` | boolean | true | Tool interacts with external entities |

In crystal-mcp: `MCP::ToolAnnotations.new(read_only_hint: true, idempotent_hint: true, destructive_hint: false, open_world_hint: false)`.

**Important**: Annotations are hints, not security guarantees. Clients should not make security-critical decisions based solely on annotations.

---

## Error Handling

- Use standard JSON-RPC error codes for protocol failures (raise `MCP::RpcError` with `MCP::ErrorCodes::*`)
- Report tool errors within result objects (`MCP::CallToolResult.error` → `isError: true`), not as protocol-level errors
- Provide helpful, specific error messages with suggested next steps
- Don't expose internal implementation details
- Clean up resources properly on errors

Example error handling:

```crystal
server.tool("myservice_list_items", ...) do |args, _ctx|
  begin
    items = api.list_items(args["limit"]?.try(&.as_i64) || 20_i64)
    items.to_json
  rescue ex : ApiRateLimited
    MCP::CallToolResult.error("Rate limited. Retry in #{ex.retry_after}s, or use filter=\"active_only\" to reduce results.")
  rescue ex : ApiError
    MCP::CallToolResult.error("API error: #{ex.message}. Check credentials and parameters.")
  end
end
```

---

## Testing Requirements

Comprehensive testing should cover:

- **Functional testing**: in-process `IO.pipe` specs driving the real server through `MCP::Client`; verify valid/invalid inputs
- **Integration testing**: compiled binary exercised end-to-end (`MCP::Client.connect_stdio`, MCP Inspector)
- **Security testing**: validate auth failures, input sanitization, rate limiting
- **Performance testing**: check behavior under load, timeouts (always pass timeouts in client calls)
- **Error handling**: ensure proper error reporting and cleanup

---

## Documentation Requirements

- Provide clear documentation of all tools and capabilities (a README for the server project, when the user asks for documentation)
- Include working examples (at least 3 per major feature)
- Document security considerations
- Specify required permissions and access levels
- Document rate limits and performance characteristics
