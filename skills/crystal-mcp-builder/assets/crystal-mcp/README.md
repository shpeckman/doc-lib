# crystal-mcp

A complete [Model Context Protocol](https://modelcontextprotocol.io) implementation for
[Crystal](https://crystal-lang.org), targeting protocol version **2026-07-28**.

It provides the full typed protocol surface (tools, resources, prompts, sampling,
elicitation, roots, completion, subscriptions, logging, progress, cancellation), a
fiber-based JSON-RPC session core, stdio and Streamable HTTP transports, an ergonomic
server framework, and a full-featured client.

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Server API](#server-api)
- [Client API](#client-api)
- [Server-initiated requests](#server-initiated-requests)
- [Subscriptions](#subscriptions)
- [Transports](#transports)
- [Error handling](#error-handling)
- [Protocol notes](#protocol-notes)
- [Running the examples](#running-the-examples)
- [Running the tests](#running-the-tests)
- [Project layout](#project-layout)
- [Caveats](#caveats)
- [License](#license)

## Requirements

- Crystal >= 1.21
- No external shard dependencies; the library uses only the Crystal standard library
  (`json`, `http/server`, `http/client`, `uuid`).

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  mcp:
    git: https://github.com/your-org/crystal-mcp.git
```

(or `path: /path/to/crystal-mcp` for a local checkout), then `shards install` and:

```crystal
require "mcp"
```

## Quick start

A stdio server exposing one tool, one resource, and one prompt:

```crystal
require "mcp"

server = MCP::Server.new(
  MCP::Implementation.new(name: "my-server", version: "1.0.0"),
  instructions: "What this server does and how to use it.")

server.tool("add", description: "Add two numbers",
  input_schema: {
    type:       "object",
    properties: {a: {type: "number"}, b: {type: "number"}},
    required:   ["a", "b"],
  }) do |args, _ctx|
  (args["a"].as_f + args["b"].as_f).to_s
end

server.resource("file:///greeting.txt", name: "greeting", mime_type: "text/plain") do |_ctx|
  "Hello!"
end

server.prompt("greet", arguments: [MCP::PromptArgument.new(name: "who", required: true)]) do |args, _ctx|
  "Please greet #{args["who"]? || "world"}."
end

server.run_stdio
```

A client driving it over stdio:

```crystal
require "mcp"

client = MCP::Client.connect_stdio("crystal",
  args: ["run", "my_server.cr", "--"],
  info: MCP::Implementation.new(name: "my-client", version: "1.0.0"),
  capabilities: MCP::ClientCapabilities.create(elicitation_form: true, sampling: true))

discover = client.discover
puts discover.supported_versions        # => ["2026-07-28"]

result = client.call_tool("add", arguments: {a: 2, b: 40})
puts result.text                        # => "42.0"

client.close
```

## Server API

### Constructor

```crystal
MCP::Server.new(info : MCP::Implementation,
                instructions : String? = nil,
                protocol_version : String = MCP::PROTOCOL_VERSION,
                page_size : Int32 = 100)
```

### Tools

```crystal
server.tool(name, description: nil, input_schema: nil, output_schema: nil,
            annotations: nil, title: nil, icons: nil) do |args, ctx|
  ...
end
```

- `args` is a `Hash(String, JSON::Any)` of the call arguments.
- `input_schema` accepts a `NamedTuple`, a `Hash(String, JSON::Any)`, or anything
  serializable to a JSON object. Defaults to `{"type": "object"}`.
- The block may return a `String` (wrapped into a `TextContent`), a single
  `ContentBlock`, an `Array(ContentBlock)` (declare literals with
  `[...] of MCP::ContentBlock`), or a full `MCP::CallToolResult` for structured
  output, errors, or `_meta`.
- Tool-level failures should be reported as `MCP::CallToolResult.error("message")`
  (or a result with `is_error: true`), not raised; raising produces a protocol-level
  JSON-RPC error, which is correct for exceptional conditions only.
- Unknown tools are answered with `-32602` (invalid params) automatically.

### Request context

Every handler receives an `MCP::RequestContext`:

- `ctx.cancelled?` — cooperative cancellation flag, set when the peer sends
  `notifications/cancelled` for this request. Check it in long-running handlers.
- `ctx.report_progress(progress, total: nil, message: nil)` — emits
  `notifications/progress` when the caller supplied a progress token.
- `ctx.meta` — the parsed request `_meta` (`MCP::RequestMeta`), including the
  protocol version, client capabilities, client info, and log level.
- `ctx.session` — the `MCP::Session`, usable for server-initiated requests
  (`elicit`, `create_message`, `list_roots`) and raw notifications.

### Resources and templates

```crystal
server.resource("file:///data.json", name: "data", mime_type: "application/json") do |ctx|
  File.read("data.json")
end

server.resource_template("file:///logs/{date}.log", name: "logs", mime_type: "text/plain") do |vars, ctx|
  File.read("logs/#{vars["date"]}.log")
end
```

Template variables (`{name}`) are extracted and handed to the block as
`Hash(String, String)`. Direct resources take precedence over templates.
Handlers may return a `String` (wrapped into `TextResourceContents` with the
registered URI/MIME type), `TextResourceContents`, `BlobResourceContents`
(base64), an `Array(ResourceContents)` (`[...] of MCP::ResourceContents`), or a
full `MCP::ReadResourceResult`.

### Prompts

```crystal
server.prompt("summarize",
  description: "Summarize a file",
  arguments: [MCP::PromptArgument.new(name: "path", required: true)]) do |args, _ctx|
  [
    MCP::PromptMessage.user("Summarize #{args["path"]}."),
  ]
end
```

The block may return a `String`, one `MCP::PromptMessage`, an
`Array(PromptMessage)`, or a full `MCP::GetPromptResult`.

### Completion

```crystal
server.on_complete do |params, _ctx|
  case ref = params.ref
  in MCP::PromptReference
    ["name"].select(&.starts_with?(params.argument.value))
  in MCP::ResourceTemplateReference
    [] of String
  end
end
```

Return an `Array(String)` of completion values (wrapped into `CompleteResult`)
or a full `MCP::CompleteResult`.

### Change notifications and logging

```crystal
server.notify_tool_list_changed
server.notify_prompt_list_changed
server.notify_resource_list_changed
server.notify_resource_updated("file:///data.json")

server.log(MCP::LoggingLevel::Info, "something happened", logger: "my-server")
```

Notifications are delivered tagged with the subscription id to any client that
opened a matching `subscriptions/listen` stream; sessions without subscriptions
receive them untagged.

### Lifecycle

```crystal
server.run_stdio                        # blocking; stdin/stdout
server.run_stdio(input_io, output_io)   # any IO pair
server.run_http(port: 3000)             # blocking; Streamable HTTP at /mcp
server.serve(transport)                 # blocking; custom MCP::Transport
server.open_session(transport)          # non-blocking; spawns the read loop
server.close                            # end subscriptions, close sessions
```

## Client API

### Connecting

```crystal
MCP::Client.connect_stdio(command, args: [] of String,
                          env: Hash(String, String)? = nil, chdir : String? = nil,
                          info: MCP::Client.default_info,
                          capabilities: MCP::ClientCapabilities.new,
                          protocol_version: MCP::PROTOCOL_VERSION)

MCP::Client.connect_http("http://127.0.0.1:3000/mcp",
                         headers: {"Authorization" => "Bearer ..."},
                         info: ..., capabilities: ..., protocol_version: ...)
```

Capabilities are advertised per request in `_meta`, as the 2026-07-28 protocol
requires. Build them with:

```crystal
MCP::ClientCapabilities.create(
  roots: true, sampling: true, sampling_context: true, sampling_tools: true,
  elicitation_form: true, elicitation_url: true)
```

### Typed methods

All methods accept an optional `timeout : Time::Span`.

```crystal
client.discover                     # => DiscoverResult (versions, capabilities, instructions)
client.list_tools(cursor = nil)     # => ListToolsResult
client.list_all_tools               # => Array(Tool) (follows pagination)
client.call_tool("add", arguments: {a: 1, b: 2})  # => CallToolResult
client.list_resources / client.list_all_resources
client.list_resource_templates / client.list_all_resource_templates
client.read_resource("file:///greeting.txt")      # => ReadResourceResult
client.list_prompts / client.list_all_prompts
client.get_prompt("greet", arguments: {"name" => "Crystal"})
client.complete(MCP::PromptReference.new("greet"), "name", "C")
client.close
```

`call_tool` optionally takes a progress callback:

```crystal
result = client.call_tool("long-task") do |progress|
  STDERR.puts "#{progress.progress}/#{progress.total}"
end
```

`CallToolResult` helpers: `text` (concatenated text blocks), `error?`,
`structured_content`, `content` (typed `Array(ContentBlock)`).

### Notifications

```crystal
client.on_tools_changed    { |_method, _params| refresh_tools }
client.on_resources_changed { |_m, _p| }
client.on_prompts_changed  { |_m, _p| }
client.on_resource_updated { |_m, params| }
client.on_log { |params| puts "#{params.level}: #{params.data}" }
client.on_notification("notifications/progress") { |method, params| }
```

## Server-initiated requests

Servers can call back into the client (sampling, roots, elicitation) both as
standalone requests and inline via the `input_required` result flow. Register
handlers on the client:

```crystal
client.on_roots { MCP::ListRootsResult.new(roots: [MCP::Root.new(uri: "file:///home/me/project")]) }

client.on_elicitation do |params|
  case params
  in MCP::ElicitFormParams
    MCP::ElicitResult.accept({"name" => "Crystal"})
  in MCP::ElicitURLParams
    MCP::ElicitResult.decline
  end
end

client.on_sampling do |params|
  MCP::CreateMessageResult.text(model: "my-model", text: "sampled response")
end
```

On the server side, trigger them from any handler via the context session:

```crystal
server.tool("ask") do |_args, ctx|
  result = ctx.session.elicit(MCP::ElicitFormParams.new(
    message: "Who are you?",
    requested_schema: MCP::ElicitFormSchema.new(
      properties: {"name" => MCP::StringSchema.new.as(MCP::PrimitiveSchema)},
      required: ["name"])))
  result.action.accept? ? "hello" : "no answer"
end
```

If a server answers a client request with an `input_required` result, the client
fulfills each entry of `inputRequests` with the registered handlers and retries
the original request with `inputResponses` and `requestState` automatically
(up to 8 round trips).

## Subscriptions

```crystal
subscription = client.listen(MCP::SubscriptionFilter.new(
  tools_list_changed: true,
  resource_subscriptions: ["file:///data.json"])) do |method, params|
  puts "changed: #{method}"
end

subscription.cancel   # sends notifications/cancelled and ends the stream
```

Over stdio the stream multiplexes onto the connection; over HTTP the listen
request is answered with a `text/event-stream` response that carries the
notifications as SSE events, each tagged with `_meta["io.modelcontextprotocol/subscriptionId"]`.

## Transports

### stdio

- `MCP::StdioServerTransport` / `server.run_stdio` — newline-delimited JSON over
  stdin/stdout. Never write to stdout from a stdio server; use stderr for logging.
- `MCP::StdioClientTransport` (via `Client.connect_stdio`) — spawns the server as a
  subprocess with piped stdin/stdout; the child's stderr is inherited.
- `MCP::IOTransport` — the generic line-delimited transport over any `IO` pair
  (used by both of the above; handy for tests and embedded use).

### Streamable HTTP

Server: `server.run_http(host: "127.0.0.1", port: 3000, path: "/mcp")`.

- `POST /mcp` — requests (answered `200 application/json`, or
  `200 text/event-stream` for `subscriptions/listen`), notifications and
  responses (answered `202 Accepted`).
- `GET /mcp` — opens the SSE stream for server-initiated messages.
- `DELETE /mcp` — terminates a session.
- `MCP-Protocol-Version` is required on requests and must match
  `params._meta["io.modelcontextprotocol/protocolVersion"]`; mismatches get a
  `400` with error code `-32020`, unsupported versions get `-32022` with the
  supported list.
- Sessions: if the client sends no `MCP-Session-Id`, the server creates a session
  and returns the id in the response header; the HTTP client adopts it
  automatically.

The HTTP client (`Client.connect_http`) opens the `GET` stream in the background
and uses one connection per request, so long-lived SSE streams never block
request traffic.

### Custom transports

Implement `MCP::Transport` (`send(message : String)`, `read_message : String?`,
`close`) and pass it to `server.serve`/`server.open_session` or
`MCP::Client.new(transport, info)`.

## Error handling

Protocol errors raise `MCP::RpcError` on the client, carrying `code : Int32`,
`message`, and optional `data : JSON::Any`. Codes live in `MCP::ErrorCodes`:

| Constant | Code |
| --- | --- |
| `PARSE_ERROR` | `-32700` |
| `INVALID_REQUEST` | `-32600` |
| `METHOD_NOT_FOUND` | `-32601` |
| `INVALID_PARAMS` | `-32602` |
| `INTERNAL_ERROR` | `-32603` |
| `HEADER_MISMATCH` | `-32020` |
| `MISSING_REQUIRED_CLIENT_CAPABILITY` | `-32021` |
| `UNSUPPORTED_PROTOCOL_VERSION` | `-32022` |

On the server, raise `MCP::RpcError` from a handler to send a specific error;
any other exception becomes `-32603`.

## Protocol notes

- The negotiated protocol version string is `MCP::PROTOCOL_VERSION`
  (`"2026-07-28"`). Version negotiation is per request via `_meta`; the
  server answers unknown versions with `-32022` listing
  `SUPPORTED_PROTOCOL_VERSIONS`, and `server/discover` advertises versions and
  capabilities up front.
- Results carry `resultType` (`"complete"` or `"input_required"`); the client
  treats a missing `resultType` as `"complete"` for backward compatibility.
- JSON-RPC batching is not part of this protocol revision and is not supported.
- Request ids are `Int64` counters generated by each session; both string and
  integer ids are accepted on the wire (`MCP::RequestId = String | Int64`).

## Running the examples

From the repository root:

```bash
crystal run examples/echo_server.cr    # stdio server (waits for a host)
crystal run examples/echo_client.cr    # spawns the server, runs the full tour
crystal run examples/http_server.cr    # Streamable HTTP on 127.0.0.1:3000/mcp
```

`echo_client` accepts the server launch command as arguments, e.g.
`crystal run examples/echo_client.cr -- ./echo_server` after building the server
binary with `crystal build examples/echo_server.cr -o echo_server`.
Set `PORT` to change the HTTP port, and `MCP_DEBUG=1` for internal diagnostics
on stderr.

## Running the tests

```bash
crystal spec
```

The suite covers JSON-RPC envelope classification, content-block
serialization, `_meta` passthrough, full client/server flows over in-process
pipes (discovery, tools, resources, templates, prompts, progress,
subscriptions, server-initiated elicitation) and over real HTTP with SSE
subscription streaming.

## Project layout

```
src/mcp.cr                  entry point (requires everything)
src/mcp/version.cr          library + protocol version constants
src/mcp/methods.cr          JSON-RPC method names, reserved _meta keys
src/mcp/json_rpc.cr         ids, envelope, error objects, frame builders
src/mcp/common.cr           Role, LoggingLevel, ElicitAction, Annotations, Icon, Implementation
src/mcp/meta.cr             RequestMeta / NotificationMeta / ResultMeta
src/mcp/capabilities.cr     client & server capabilities
src/mcp/content.cr          ContentBlock hierarchy, SamplingMessage
src/mcp/tools.cr            Tool, CallToolParams/Result, ListToolsResult, pagination params
src/mcp/resources.cr        Resource, ResourceTemplate, contents, read/list results
src/mcp/prompts.cr          Prompt, PromptArgument, PromptMessage, get/list
src/mcp/completion.cr       completion/complete types
src/mcp/sampling.cr         sampling/createMessage types
src/mcp/elicitation.cr      form/url elicitation params, schema types, result
src/mcp/roots.cr            Root, ListRootsResult
src/mcp/notifications.cr    cancelled / progress / resource-updated / log params
src/mcp/subscriptions.cr    SubscriptionFilter, subscriptions/listen types
src/mcp/discover.cr         server/discover result
src/mcp/input_required.cr   input_required result handling
src/mcp/transport.cr        abstract Transport + IOTransport
src/mcp/transports/stdio.cr stdio server & subprocess client transports
src/mcp/transports/http.cr  Streamable HTTP transports + SSE codec
src/mcp/session.cr          JSON-RPC session: dispatch, pending calls, cancellation
src/mcp/server.cr           server framework and HTTP front end
src/mcp/client.cr           typed client
spec/                       test suite
examples/                   echo server/client, HTTP server
```

## Caveats

- Cancellation is cooperative: handlers should poll `ctx.cancelled?`; Crystal
  does not preempt fibers.
- Server-initiated requests over HTTP require the client's `GET` SSE stream
  (opened automatically by `Client.connect_http`); without it they raise
  `-32603`.
- A request arriving without `MCP-Session-Id` shares the server's anonymous
  session — intended for single-client development; send the returned session
  id header to isolate clients.
- `tools/list` and friends paginate in-memory with offset cursors; registration
  order determines page order.

## License

MIT
