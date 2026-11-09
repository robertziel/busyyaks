# frozen_string_literal: true

# The MCP endpoint is its own process on its own port (127.0.0.1 only, never
# tunnelled): the web app may be public behind its auth provider, this is not.
require "hanami/boot"
require_relative "lib/busyyaks/mcp_server"
require_relative "lib/busyyaks/env_file"

# the host address compose publishes this port on (.env MCP_HOST): loopback, or the server refuses to start
Busyyaks::EnvFile.shape!("MCP_HOST", ENV.fetch("MCP_HOST"))

run Busyyaks::McpServer.new(token: ENV.fetch("MCP_TOKEN"), report_token: ENV.fetch("MCP_REPORT_TOKEN"),
                            scan_interval: Integer(ENV.fetch("SCAN_INTERVAL_SECONDS")))
