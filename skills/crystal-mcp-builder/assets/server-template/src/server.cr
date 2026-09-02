# src/server.cr
require "./app"

server = build_server

if port = ENV["PORT"]?
  server.run_http(port: port.to_i)
else
  server.run_stdio
end
