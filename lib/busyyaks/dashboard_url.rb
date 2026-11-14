# frozen_string_literal: true

require "erb"
require_relative "deploy_template"

module Busyyaks
  # The origin the operator's browser opens the dashboard at, read from .env exactly as docs/DEPLOY.md defines it per
  # mode: `PUBLIC_HOST` set (modes 2 and 3: nginx + TLS) → `https://<PUBLIC_HOST>`; `PUBLIC_HOST` empty (mode 1,
  # localhost only) → `http://127.0.0.1:<WEB_HOST_PORT>`. One value each, no second definition. A malformed value, or
  # a key missing from the env, raises at the first use (the MCP server's first kanban tool call, `yaks panel`).
  # Pure Ruby (erb + deploy_template only): the host's `yaks` requires this file alone.
  module DashboardUrl
    class Invalid < StandardError; end

    # where compose publishes web (docker-compose.yml: "127.0.0.1:${WEB_HOST_PORT}"), the one definition
    LOOPBACK = "127.0.0.1"

    module_function

    def origin(env = ENV)
      host = env.fetch("PUBLIC_HOST") { raise Invalid, "PUBLIC_HOST missing from the env (empty = localhost only)" }
      return "https://#{shape!('PUBLIC_HOST', host)}" unless host.empty?

      port = env.fetch("WEB_HOST_PORT") { raise Invalid, "WEB_HOST_PORT missing from the env" }
      "http://#{LOOPBACK}:#{shape!('WEB_HOST_PORT', port)}"
    end

    # The SPA path that opens a card on its project's board (API.card_path: the engine's "card #N" chips, search hits).
    def card_path(slug, id)
      "/projects/#{slug.to_s.split('/').map { |s| ERB::Util.url_encode(s) }.join('/')}?tab=board&card=#{id}"
    end

    # The SPA path of a card on a SESSION board (an agent session's own board, no project): the read-only
    # /session-boards page.
    def session_card_path(session, id) = "/session-boards?session=#{ERB::Util.url_encode(session.to_s)}&card=#{id}"

    # The absolute URL that opens card `id` on project `slug`'s board (the engine's Tools card_url port → each card's `url`).
    def card(slug, id, env = ENV) = "#{origin(env)}#{card_path(slug, id)}"

    def shape!(key, value)
      ok, what = DeployTemplate::FORMATS.fetch(key)
      raise Invalid, "#{key}=#{value.inspect} is not #{what}" unless ok.call(value)

      value
    end
  end
end
