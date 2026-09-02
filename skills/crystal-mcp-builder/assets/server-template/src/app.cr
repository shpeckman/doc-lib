# src/app.cr
require "mcp"

def build_server : MCP::Server
  server = MCP::Server.new(
    MCP::Implementation.new(name: "myservice-mcp", version: "0.1.0"),
    instructions: "MCP server for myservice."
  )

  server.tool("myservice_example", description: "Example tool that echoes text back",
    input_schema: {
      type:       "object",
      properties: {text: {type: "string", description: "Text to echo"}},
      required:   ["text"],
    },
    annotations: MCP::ToolAnnotations.new(read_only_hint: true, idempotent_hint: true, open_world_hint: false)) do |args, _ctx|
    args["text"]?.try(&.as_s) || ""
  end

  server
end
