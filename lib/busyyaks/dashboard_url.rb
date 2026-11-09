# frozen_string_literal: true

require_relative "deploy_template"
require_relative "api"

module Busyyaks
  # The origin the operator's browser opens the dashboard at, read from .env exactly as docs/DEPLOY.md defines it per
  # mode: `PUBLIC_HOST` set (modes 2 and 3: nginx + TLS) → `https://<PUBLIC_HOST>`; `PUBLIC_HOST` empty (mode 1,
  # localhost only) → `http://127.0.0.1:<WEB_HOST_PORT>`. One value each, no second definition. A malformed value, or
  # a key missing from the env, raises at the first use (the MCP server's first kanban tool call).
  module DashboardUrl
    class Invalid < StandardError; end

    module_function

    def origin(env = ENV)
      host = env.fetch("PUBLIC_HOST") { raise Invalid, "PUBLIC_HOST missing from the env (empty = localhost only)" }
      return "https://#{shape!('PUBLIC_HOST', host)}" unless host.empty?

      port = env.fetch("WEB_HOST_PORT") { raise Invalid, "WEB_HOST_PORT missing from the env" }
      "http://127.0.0.1:#{shape!('WEB_HOST_PORT', port)}"
    end

    # The absolute URL that opens card `id` on project `slug`'s board (the engine's Tools card_url port → each card's `url`).
    def card(slug, id, env = ENV) = "#{origin(env)}#{API.card_path(slug, id)}"

    def shape!(key, value)
      ok, what = DeployTemplate::FORMATS.fetch(key)
      raise Invalid, "#{key}=#{value.inspect} is not #{what}" unless ok.call(value)

      value
    end
  end
end
