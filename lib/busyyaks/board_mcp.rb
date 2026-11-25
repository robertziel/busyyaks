# frozen_string_literal: true

require "fileutils"
require "json"

module Busyyaks
  # The board's MCP endpoint for the sessions busyyaks starts (2026-11-24): the kanban_* tools are on MCP_BOARD_TOKEN
  # alone, and bin/launcher hands that token only to a session it starts — written into the session's own stage (0700
  # dir, 0600 file), never into an argv, the repo or a user-wide config. MCP_TOKEN has no board tool, and nothing
  # registers a busyyaks MCP user-wide: a session started from a terminal knows nothing of the board.
  module BoardMcp
    class Invalid < StandardError; end

    CLAUDE_FILE = "mcp.json"
    # the server name every board skill calls (mcp__busyyaks__kanban_*): the per-launch entry replaces the user-wide
    # one of the same name for that session (measured with Claude Code: `--mcp-config` beats the user scope)
    NAME = "busyyaks"

    module_function

    # .env → {url:, token:}; a key missing or empty → refused (the launch is refused: no board session without it)
    def endpoint!(env)
      host, port, token = %w[MCP_HOST MCP_HOST_PORT MCP_BOARD_TOKEN].map do |k|
        v = env.fetch(k) { raise Invalid, "#{k} missing in .env (a board session needs the busyyaks MCP)" }.to_s
        raise Invalid, "#{k} is empty in .env (a board session needs the busyyaks MCP)" if v.empty?

        v
      end
      { url: "http://#{host}:#{port}/mcp", token: token }
    end

    # Claude Code: <stage>/mcp.json for `--mcp-config` → its path
    def claude!(stage, mcp)
      path = File.join(stage, CLAUDE_FILE)
      doc = { "mcpServers" => { NAME => { "type" => "http", "url" => mcp[:url],
                                          "headers" => { "Authorization" => "Bearer #{mcp[:token]}" }, } } }
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(JSON.generate(doc)) }
      path
    end

    def claude_path(stage) = File.join(stage, CLAUDE_FILE)
  end
end
