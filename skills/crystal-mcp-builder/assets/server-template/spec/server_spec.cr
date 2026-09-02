# spec/server_spec.cr
require "spec"
require "../src/app"

describe "myservice-mcp" do
  it "serves discover and tools over an in-process session" do
    srv_in, cli_out = IO.pipe
    cli_in, srv_out = IO.pipe

    server = build_server
    server.open_session(MCP::IOTransport.new(srv_in, srv_out))

    client = MCP::Client.new(MCP::IOTransport.new(cli_in, cli_out),
      MCP::Implementation.new(name: "spec-client", version: "0.0.1"))
    client.start

    discover = client.discover(5.seconds)
    discover.supported_versions.should contain MCP::PROTOCOL_VERSION

    result = client.call_tool("myservice_example", arguments: {text: "hello"}, timeout: 5.seconds)
    result.text.should eq "hello"

    client.close
  end
end
