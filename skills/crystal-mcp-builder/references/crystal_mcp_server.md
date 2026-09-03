# Crystal MCP Server Implementation Guide

Complete guide to building MCP servers in Crystal with the crystal-mcp shard (protocol version 2026-07-28). The shard lives at https://github.com/shpeckman/crystal-mcp — source, full API README, and runnable `examples/` are all there.

## Overview

crystal-mcp provides the entire protocol stack: typed messages for every 2026-07-28 definition, a fiber-based JSON-RPC `Session`, stdio and Streamable HTTP transports, an ergonomic `MCP::Server` DSL, and a full `MCP::Client` used for testing. Server code only touches the `MCP::Server` DSL; the shard handles discovery, capability negotiation, pagination of `list` endpoints, subscription filtering, and protocol-version validation.

## Quick Reference

### Require

```crystal
require "crystal-mcp"
```

The shard is a git dependency (see Project Structure) — fetched from GitHub by `shards install`. Its shard `name` is `crystal-mcp`, so both the `shard.yml` dependency key and the `require` use `crystal-mcp`, never `mcp`.

### Server Initialization

```crystal
server = MCP::Server.new(
  MCP::Implementation.new(name: "myservice-mcp", version: "0.1.0"),
  instructions: "What this server is for and how to use its tools."
)
```

### Tool Registration Pattern

```crystal
server.tool("myservice_get_user",
  description: "Get a user by ID. Returns profile fields; use myservice_list_users to find IDs.",
  input_schema: {
    type:       "object",
    properties: {user_id: {type: "string", description: "User ID, e.g. u_12345"}},
    required:   ["user_id"],
  },
  annotations: MCP::ToolAnnotations.new(read_only_hint: true, open_world_hint: true)) do |args, ctx|
  user_id = args["user_id"].as_s
  fetch_user(user_id).to_json
end

server.run_stdio
```

### Handler Signatures

| Registration | Handler block | Returns |
|---|---|---|
| `server.tool` | `\|args : Hash(String, JSON::Any), ctx\|` | `String \| ContentBlock \| Array(ContentBlock) \| CallToolResult` |
| `server.resource` | `\|ctx\|` | `String \| TextResourceContents \| BlobResourceContents \| Array(ResourceContents) \| ReadResourceResult` |
| `server.resource_template` | `\|vars : Hash(String, String), ctx\|` | same as resource |
| `server.prompt` | `\|args : Hash(String, String), ctx\|` | `String \| PromptMessage \| Array(PromptMessage) \| GetPromptResult` |
| `server.on_complete` | `\|params : CompleteParams, ctx\|` | `Array(String) \| CompleteResult` |

Plain `String` returns are wrapped into text content automatically; return the richer types when you need images, structured content, or error flags.

## Environment Setup

Crystal >= 1.21 is required and is NOT preinstalled in every environment.

```bash
crystal --version
```

If Crystal is missing, install the official tarball without root (if the `dev` skill is loaded in this session, run its `scripts/install_crystal.py` instead — it is idempotent and handles mirrors automatically):

```bash
cd "$HOME"
curl -fL --retry 3 -C - -o crystal.tar.gz \
  https://github.com/crystal-lang/crystal/releases/download/1.21.0/crystal-1.21.0-1-linux-x86_64-bundled.tar.gz \
  || curl -fL --retry 3 -C - -o crystal.tar.gz \
  https://gh-proxy.com/https://github.com/crystal-lang/crystal/releases/download/1.21.0/crystal-1.21.0-1-linux-x86_64-bundled.tar.gz
mkdir -p crystal && tar -xzf crystal.tar.gz -C crystal --strip-components=1
export PATH="$HOME/crystal/bin:$PATH"
```

Constraints that matter:

- `$HOME` and `/tmp` are wiped between sandbox sessions — re-run the installer at the start of each session.
- `/mnt/agents` is mounted noexec and rejects symlinks — never install Crystal there and never compile there. Build in `$HOME` or `/tmp`; copy deliverables to `/mnt/agents/output/` afterwards.
- `gcc`, `ld`, and the tarball's bundled libs (libgc, pcre2, ssl, yaml, event) work out of the box.

## Project Structure

Create the project layout yourself (the repo's `examples/` directory has working servers for reference):

```
myservice-mcp/
├── shard.yml               # declares git dependency on the crystal-mcp shard
├── src/
│   ├── app.cr              # build_server : MCP::Server — all registration lives here
│   ├── server.cr           # entrypoint: build_server + transport selection
│   └── myservice/
│       ├── client.cr       # HTTP API client wrapper
│       └── formatters.cr   # JSON/Markdown formatting helpers
├── spec/
│   └── server_spec.cr      # in-process integration specs
└── lib/
    └── crystal-mcp         # crystal-mcp shard, fetched by `shards install`
```

Setup:

```bash
shards init app myservice-mcp
cd myservice-mcp
```

Declare the dependency in `shard.yml`:

```yaml
dependencies:
  crystal-mcp:
    github: shpeckman/crystal-mcp
```

```bash
shards install        # clones the shard into lib/crystal-mcp
# GitHub unreachable from the build host? vendor a clone instead:
#   git clone https://github.com/shpeckman/crystal-mcp vendor/crystal-mcp
# and use `path: vendor/crystal-mcp` in shard.yml
# (on filesystems without symlink support, copy vendor/crystal-mcp to lib/crystal-mcp)
```

The dependency key must be `crystal-mcp` — shards rejects a dependency whose key differs from the shard's `name`. `require "crystal-mcp"` resolves through the `lib` entry on `CRYSTAL_PATH` in both cases. Keep ALL registration in `app.cr`'s `build_server` method so specs can construct the same server in-process — never register tools at the top level of the entrypoint.

## Server Naming Convention

- Shard name (`shard.yml` `name:`): `{service}-mcp` — e.g. `slack-mcp`, `weather-mcp`
- `Implementation` name: same string
- No version numbers in the name; general and descriptive of the service

## Tool Implementation

### Tool Naming

1. snake_case, action-oriented verbs: `get`, `list`, `search`, `create`, `update`, `delete`
2. Always service-prefixed — the server will be used alongside other MCP servers: `myservice_get_user`, not `get_user`
3. Format: `{service}_{action}_{resource}`

### Registration DSL

Full signature:

```crystal
server.tool(name : String, description : String? = nil, input_schema = nil,
            output_schema = nil, annotations : ToolAnnotations? = nil, title : String? = nil,
            icons : Array(Icon)? = nil) { |args, ctx| ... }
```

- `description`: narrowly and unambiguously state what the tool does, when to use it, and what it returns. Agents pick tools by description alone.
- `title`: human-friendly display name.
- `input_schema` / `output_schema`: NamedTuple or Hash literals, emitted verbatim as JSON Schema (see below).
- `annotations`: `MCP::ToolAnnotations.new(read_only_hint:, destructive_hint:, idempotent_hint:, open_world_hint:, title:)`.

### Argument Extraction

Handlers receive `args : Hash(String, JSON::Any)`. Extraction idioms:

```crystal
text    = args["text"].as_s                          # required String
count   = args["count"].as_i64                       # required Int
ratio   = args["ratio"].as_f                         # required Float
flag    = args["flag"].as_bool                       # required Bool
limit   = args["limit"]?.try(&.as_i64) || 20_i64     # optional with default
status  = args["filter"]?.try(&.as_h["status"]?.try(&.as_s))   # nested optional
tags    = args["tags"].as_a.map(&.as_s)              # Array(String)
```

`.as_*` raises `TypeCastError` on mismatch, which surfaces to the caller as a protocol error — acceptable for malformed input, but validate business rules yourself and return actionable `CallToolResult.error` messages.

### Handler Return Types

```crystal
server.tool("myservice_plain", ...) { |args, _ctx| "text becomes TextContent" }

server.tool("myservice_blocks", ...) do |args, _ctx|
  [
    MCP::TextContent.new("chart rendered"),
    MCP::ImageContent.new(data: png_base64, mime_type: "image/png"),
  ] of MCP::ContentBlock
end

server.tool("myservice_result", ...) do |args, _ctx|
  MCP::CallToolResult.error("Not found. Use myservice_search_users to locate the ID first.")
end
```

When returning mixed content blocks, the array literal needs an explicit `of MCP::ContentBlock` so the compiler unifies the element types.

## Input Schemas

`input_schema` is a NamedTuple (or Hash) literal converted verbatim to the JSON Schema object advertised in `tools/list`. Write real JSON Schema — it is the only documentation an agent sees for parameters:

```crystal
input_schema: {
  type:       "object",
  properties: {
    query:   {type: "string", description: "Full-text search query"},
    state:   {type: "string", enum: ["open", "closed"], description: "Filter by state"},
    limit:   {type: "integer", minimum: 1, maximum: 100, default: 20,
              description: "Max results to return (1-100)"},
    since:   {type: "string", format: "date-time",
              description: "Only items updated after this ISO 8601 timestamp"},
  },
  required: ["query"],
  additionalProperties: false,
}
```

Omitting `input_schema` defaults to `{"type": "object"}` (no arguments).

Rules:
- Describe every property; include examples in descriptions ("e.g. u_12345")
- Constrain with `enum`, `minimum`/`maximum`, `pattern`, `default` where applicable
- Keep required parameters minimal
- Do NOT hand-build JSON strings for schemas — NamedTuple literals are typed and checked at compile time

## Output Schemas and Structured Content

For tools returning data, declare `output_schema:` and return both human-readable text and machine-readable structured content:

```crystal
server.tool("myservice_get_weather",
  description: "Current weather for a city",
  input_schema: {
    type:       "object",
    properties: {city: {type: "string"}},
    required:   ["city"],
  },
  output_schema: {
    type:       "object",
    properties: {
      temperature: {type: "number"},
      unit:        {type: "string"},
      conditions:  {type: "string"},
    },
    required: ["temperature", "unit", "conditions"],
  }) do |args, _ctx|
  weather = fetch_weather(args["city"].as_s)
  structured = MCP.to_any({temperature: weather.temp, unit: "C", conditions: weather.conditions})
  MCP::CallToolResult.new(
    content: [MCP::TextContent.new("#{weather.temp}°C, #{weather.conditions}")] of MCP::ContentBlock,
    structured_content: structured)
end
```

`MCP.to_any` converts NamedTuples, Hashes, Arrays, and primitives to `JSON::Any` — use it for `structured_content`.

## Response Formats

Tools that return data should support JSON and Markdown via a `response_format` parameter (default `markdown`):

```crystal
server.tool("myservice_list_issues", description: "List issues",
  input_schema: {
    type:       "object",
    properties: {
      response_format: {type: "string", enum: ["json", "markdown"], default: "markdown"},
      limit:           {type: "integer", default: 20, minimum: 1, maximum: 100},
    },
  }) do |args, _ctx|
  format = args["response_format"]?.try(&.as_s) || "markdown"
  issues = api.list_issues(limit: args["limit"]?.try(&.as_i64) || 20_i64)
  format == "json" ? issues.to_json : issues_to_markdown(issues)
end
```

- JSON: machine-readable, all fields, consistent names
- Markdown: human-readable, headers/lists, human-readable timestamps, display names with IDs in parentheses, no verbose metadata

## Pagination

The shard paginates the protocol's own `list` endpoints automatically (cursor = offset, `page_size:` keyword on `MCP::Server.new`, default 100). For tool-level result sets, implement offset pagination yourself and always respect `limit`:

```crystal
limit  = args["limit"]?.try(&.as_i64) || 20_i64
offset = args["offset"]?.try(&.as_i64) || 0_i64
page, total = api.search(query, limit: limit, offset: offset)
MCP.to_any({
  items:       page,
  total_count: total,
  count:       page.size,
  offset:      offset,
  has_more:    offset + page.size < total,
  next_offset: offset + page.size < total ? offset + page.size : nil,
}).to_json
```

Default to 20–50 items; never load an unbounded result set into memory.

## Character Limits and Truncation

Tool responses compete for the agent's context window:

- Return focused fields, not raw API payloads
- Cap text responses (~25k characters is a sane ceiling)
- When truncating, say so explicitly: `"... truncated. 143 of 900 shown. Narrow with state=\"open\" or reduce limit."`
- Prefer pagination + filtering parameters over one giant response

## Error Handling

Two distinct channels — pick deliberately:

**Tool-level errors (domain failures)** — return `MCP::CallToolResult.error`, which sets `isError: true`. This is the normal path: the agent sees the message and can recover.

```crystal
server.tool("myservice_get_issue", ...) do |args, _ctx|
  begin
    issue = api.get_issue(args["id"].as_s)
    issue.to_json
  rescue ex : ApiNotFound
    MCP::CallToolResult.error("Issue '#{args["id"].as_s}' not found. Use myservice_search_issues to find valid IDs.")
  rescue ex : ApiAuthError
    MCP::CallToolResult.error("Authentication failed. Check the MYSERVICE_API_KEY environment variable.")
  end
end
```

**Protocol-level errors** — raise `MCP::RpcError.new(code, message)` only for protocol violations. The shard maps exceptions in handlers like this:

| Raised from handler | Wire result |
|---|---|
| `MCP::RpcError` | its code and message |
| `JSON::SerializableError` / `JSON::ParseException` | -32602 invalid params |
| anything else (incl. `TypeCastError` from `.as_*`) | -32603 internal error, **message included** |

Because arbitrary exception messages reach the client, rescue broadly inside handlers and return sanitized, actionable `CallToolResult.error` text — do not leak stack internals, file paths, or credentials.

Error message quality bar: state what failed, why, and the concrete next step (which other tool to call, which parameter to fix).

## Shared Utilities

Wrap the upstream API once; tools stay thin. Crystal-specific points:

- One `HTTP::Client` instance cannot multiplex a long-lived SSE stream with concurrent POSTs — create a client per request for plain REST calls.
- In block-form `HTTP::Client#post/get`, `response.body` is empty — read `response.body_io.gets_to_end`.
- Keep API keys in environment variables; fail fast at startup if missing.

```crystal
# src/myservice/client.cr
require "http/client"
require "json"

class MyserviceClient
  def initialize(@base_url : String, @api_key : String)
  end

  def get(path : String) : JSON::Any
    request("GET", path)
  end

  def post(path : String, body) : JSON::Any
    request("POST", path, body)
  end

  private def request(method : String, path : String, body = nil) : JSON::Any
    uri = URI.parse("#{@base_url}#{path}")
    client = HTTP::Client.new(uri)
    headers = HTTP::Headers{"Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json"}
    response = client.exec(method, uri.request_target, headers: headers, body: body.try(&.to_json))
    unless response.success?
      raise "API #{method} #{path} failed: HTTP #{response.status_code}"
    end
    JSON.parse(response.body)
  end
end
```

Validate configuration at startup, before `run_stdio`:

```crystal
api_key = ENV["MYSERVICE_API_KEY"]? || raise "MYSERVICE_API_KEY environment variable is required"
```

## Concurrency Notes

- Each inbound request is dispatched on its own fiber — handlers run concurrently. Protect shared mutable state with a `Mutex` or confine it to one owner fiber communicating via `Channel`s.
- Long-running tools: report progress (below) and check `ctx.cancelled?` inside loops so client cancellation actually stops work.
- Avoid unbounded `spawn` per tool call; shard internals already spawn per message.

## Resources and Resource Templates

Resources expose read-only data by URI. A handler returning a `String` is wrapped with the definition's `mime_type`:

```crystal
server.resource("config://app/settings", name: "settings", mime_type: "application/json",
  description: "Current application configuration") do |_ctx|
  load_settings.to_json
end

server.resource_template("myservice://users/{user_id}/profile", name: "user-profile",
  mime_type: "application/json", description: "Profile document for a user") do |vars, _ctx|
  fetch_user(vars["user_id"]).to_json
end
```

- Template variables are `{identifier}` segments; the shard compiles them to a regex and hands the handler `vars : Hash(String, String)`
- Return `MCP::TextResourceContents.new(uri:, text:, mime_type:)` or `MCP::BlobResourceContents.new(uri:, blob:, mime_type:)` (base64) when you need explicit control
- Register templates for every parameterized document family; agents discover them via `resources/templates/list`

## Prompts

Reusable prompt templates with typed arguments:

```crystal
server.prompt("myservice_triage", description: "Triage an issue report",
  arguments: [MCP::PromptArgument.new(name: "issue_id", description: "Issue ID", required: true)]) do |args, _ctx|
  issue = api.get_issue(args["issue_id"])
  [
    MCP::PromptMessage.user("Triage this issue and propose next steps:\n\n#{issue.to_json}"),
  ]
end
```

- `MCP::PromptMessage.new(role: MCP::Role::User, content: "text")` or the `.user` / `.assistant` helpers
- String returns become a single user message

## Completion

Argument autocompletion for prompts and resource templates:

```crystal
server.on_complete do |params, _ctx|
  case params.ref
  when MCP::PromptReference
    suggest_usernames(params.argument.value)
  when MCP::ResourceTemplateReference
    suggest_uris(params.argument.value)
  else
    [] of String
  end
end
```

Return `Array(String)` of candidates, or `MCP::CompleteResult` for full control.

## Subscriptions and Notifications

2026-07-28 replaced per-resource `subscribe` with `subscriptions/listen` streams carrying a `SubscriptionFilter` (`tools_list_changed`, `prompts_list_changed`, `resources_list_changed`, `resource_subscriptions : Array(String)`). The shard tracks listeners per session — server code just calls:

```crystal
server.notify_tool_list_changed
server.notify_prompt_list_changed
server.notify_resource_list_changed
server.notify_resource_updated("myservice://users/u_1/profile")
server.log(MCP::LoggingLevel::Info, "index rebuilt")
```

`notify_resource_updated` delivers to sessions whose filter lists that URI (or to all sessions when nobody is listening, matching the legacy behavior). Call these after any mutation so connected clients refresh.

## Server-Initiated Requests

Tools can call back into the client via `ctx.session`. These only succeed when the client advertised the matching capability — handle `MCP::RpcError` for unsupported peers.

### Sampling (ask the client's LLM)

```crystal
result = ctx.session.create_message(MCP::CreateMessageParams.new(
  messages: [MCP::SamplingMessage.text(MCP::Role::User, "Summarize: #{document}")],
  max_tokens: 1024))
case content = result.content
when MCP::TextContent then content.text
else                     ""
end
```

### Elicitation (ask the user for structured input)

```crystal
result = ctx.session.elicit(MCP::ElicitFormParams.new(
  message: "Confirm deployment target",
  requested_schema: MCP::ElicitFormSchema.new(
    properties: {
      "environment" => MCP::UntitledSingleSelectEnumSchema.new(["staging", "production"]).as(MCP::PrimitiveSchema),
      "confirm"     => MCP::BooleanSchema.new(default: false).as(MCP::PrimitiveSchema),
    },
    required: ["environment", "confirm"])))

if result.action.accept?
  content = result.content
  env = content.try(&.["environment"]?)
else
  # declined or cancelled — abort gracefully
end
```

Field schema classes: `StringSchema` (`format:`, `min_length:`, `max_length:`), `NumberSchema` (`NumberSchema.integer(...)` for integers), `BooleanSchema`, the single-select enums (`UntitledSingleSelectEnumSchema.new(values)`, `TitledSingleSelectEnumSchema.new([MCP::EnumOption.new("value", title: "...")])`, legacy `LegacyTitledEnumSchema`), and the multi-selects (`UntitledMultiSelectEnumSchema.values([...])`, `TitledMultiSelectEnumSchema.options([...])`). All must be cast `.as(MCP::PrimitiveSchema)` when mixed in one `properties` hash. See the shard README (https://github.com/shpeckman/crystal-mcp/blob/main/README.md) for the full list.

### Roots (ask where the client is working)

```crystal
roots = ctx.session.list_roots
roots.roots.each { |root| ... }
```

## Progress Reporting and Cancellation

```crystal
server.tool("myservice_reindex", ...) do |args, ctx|
  items = load_all
  items.each_with_index do |item, i|
    if ctx.cancelled?
      return MCP::CallToolResult.error("Cancelled after #{i} of #{items.size} items")
    end
    process(item)
    ctx.report_progress((i + 1).to_f64, items.size.to_f64, "processing #{item.id}")
  end
  "reindexed #{items.size} items"
end
```

`report_progress` is a no-op unless the client supplied a progress token. Cancellation is cooperative: the shard flips `ctx.cancelled?` when `notifications/cancelled` arrives; the handler must check it.

## Transports

### stdio (local servers)

```crystal
server.run_stdio   # blocking; STDIN/STDOUT is the protocol channel
```

Never write logs to STDOUT in stdio mode — use STDERR (`STDERR.puts` or `Log`).

### Streamable HTTP (remote servers)

```crystal
server.run_http(host: "127.0.0.1", port: 3000, path: "/mcp")
```

The HTTP handler validates `MCP-Protocol-Version`, issues `MCP-Session-Id` headers, routes POSTed requests, and serves GET SSE streams for `subscriptions/listen`. Bind `127.0.0.1` for local use; put TLS and authentication in front (reverse proxy / OAuth 2.1) when exposing it — the shard does not implement auth.

### Custom / in-process

```crystal
session = server.serve(MCP::IOTransport.new(input_io, output_io))   # blocking
session = server.open_session(MCP::IOTransport.new(in_io, out_io))  # spawned, non-blocking
```

`open_session` is how specs wire a client and server together over `IO.pipe` without processes.

## Building and Running

```bash
shards install                                   # fetches the crystal-mcp shard
mkdir -p bin
crystal build src/server.cr -o bin/server        # development build
crystal build src/server.cr -o bin/server --release   # production
./bin/server                                     # stdio
PORT=3000 ./bin/server                           # Streamable HTTP on :3000/mcp
```

Build in `$HOME` or `/tmp` (never `/mnt/agents` — noexec). `crystal run src/server.cr` compiles and runs in one step during development.

## Testing

### In-process integration specs (fast, no subprocess)

```crystal
# spec/server_spec.cr
require "spec"
require "../src/app"

describe "myservice-mcp" do
  it "serves tools over an in-process session" do
    srv_in, cli_out = IO.pipe
    cli_in, srv_out = IO.pipe

    server = build_server
    server.open_session(MCP::IOTransport.new(srv_in, srv_out))

    client = MCP::Client.new(MCP::IOTransport.new(cli_in, cli_out),
      MCP::Implementation.new(name: "spec-client", version: "0.0.1"))
    client.start

    discover = client.discover(5.seconds)
    discover.supported_versions.should contain MCP::PROTOCOL_VERSION

    result = client.call_tool("myservice_example", arguments: {text: "hi"}, timeout: 5.seconds)
    result.text.should eq "hi"

    client.close
  end
end
```

Run with `crystal spec`. Always pass timeouts to client calls in specs — a hang otherwise blocks the suite forever.

### Client-side surface for tests

- `MCP::Client.connect_stdio("./bin/server")` — spawn and exercise the real binary end-to-end
- `MCP::Client.connect_http("http://127.0.0.1:3000/mcp")` — HTTP transport
- `list_all_tools` / `list_all_resources` / `list_all_prompts` — paginate to exhaustion
- `call_tool(name, arguments:, timeout:) { |progress| ... }` — progress callback form
- `read_resource(uri)`, `get_prompt(name, arguments:)`, `complete(ref, argument_name, argument_value)`
- `listen(MCP::SubscriptionFilter.all) { |method, params| ... }` → `ClientSubscription`, end with `.cancel`
- `on_sampling` / `on_elicitation` / `on_roots` — stub peer handlers when testing server-initiated requests (declare matching capabilities via `MCP::ClientCapabilities.create(sampling: true, elicitation_form: true, roots: true)`)
- `result.error?` / `result.text` for assertions

### MCP Inspector

```bash
npx @modelcontextprotocol/inspector ./bin/server
```

Drives the compiled binary over stdio interactively — verify tool schemas, call tools, watch notifications.

## Crystal Pitfalls

Hit in real crystal-mcp sessions; check before debugging ghosts:

1. No trailing `while`/`until` modifiers (`i += 1 while cond` is a Ruby-ism Crystal rejects)
2. `raise` takes no keyword args — `raise MyError.new("msg", cause: ex)`
3. Union type declarations need concrete numerics: `Int32 | String`, not `Int | String`
4. `Time` (deadline) vs `Time::Span` (duration) are not interchangeable; `Time.instant + timeout` for deadlines
5. A `Hash` literal mixing schema types needs explicit casts (`.as(MCP::PrimitiveSchema)`); a heterogeneous `Array` literal needs `of MCP::ContentBlock`
6. `UInt8 == Char` compiles but is always false — compare bytes to ints
7. If the `dev` skill is present, run `python3 <dev-skill>/scripts/crystal_preflight.py FILE.cr...` on every `.cr` file before delivery; use `--fix` only on files that do not contain the word "while" inside string literals

## Quality Checklist

### Strategic Design
- [ ] Server name is `{service}-mcp`; tools use `{service}_{action}_{resource}`
- [ ] Comprehensive API coverage (or consciously chosen workflow tools)
- [ ] Tool descriptions are precise, unambiguous, and self-sufficient

### Implementation Quality
- [ ] Every tool has a complete JSON Schema `input_schema` with per-field descriptions
- [ ] Data tools declare `output_schema` and return `structured_content`
- [ ] Data tools support `response_format` (json/markdown) where useful
- [ ] List tools respect `limit` and return `has_more` / `next_offset` / `total_count`
- [ ] All tools carry correct `ToolAnnotations`
- [ ] Domain errors return `CallToolResult.error` with actionable next steps; no internal details leak
- [ ] API keys come from the environment and are validated at startup
- [ ] Long-running tools report progress and honor `ctx.cancelled?`

### Crystal Quality
- [ ] `crystal build --release` succeeds with no warnings
- [ ] No duplicated code; shared API client and formatters
- [ ] Preflight linter clean (if the `dev` skill is available)

### Testing
- [ ] `crystal spec` green, including in-process integration specs with timeouts
- [ ] Compiled binary verified end-to-end (`connect_stdio` or MCP Inspector)
- [ ] Error paths tested (bad args, missing auth, upstream failure)

### Protocol Behavior
- [ ] stdio server writes nothing but JSON-RPC to STDOUT
- [ ] Mutating tools trigger the relevant `notify_*_changed`
- [ ] Server-initiated requests (sampling/elicitation/roots) degrade gracefully when unsupported
