# frozen_string_literal: true

require "json"
require_relative "auth"
require_relative "deploy_template"

module Busyyaks
  # DNS rebinding guard, the web app's outermost own middleware (config/app.rb), in front of every route and asset.
  #
  # A page on evil.example that re-resolves its name to 127.0.0.1 is same-origin with this app in the operator's
  # browser: it could read the SPA shell's CSRF token and drive the operator API (comments typed into agent sessions,
  # launches, dialog answers). Its requests still carry `Host: evil.example[:port]`, so only the Hosts this deployment
  # names are answered:
  #
  #   127.0.0.1:<WEB_HOST_PORT>, localhost:<WEB_HOST_PORT>   origin http://…  (the published port, an ssh tunnel on it)
  #   <PUBLIC_HOST>                                          origin https://… (the TLS proxy, docs/DEPLOY.md)
  #
  # Any other Host (none at all, the container port, a forwarded one) → 421, no handler runs. A mutation (not
  # GET/HEAD) that sends an Origin — or, without one, a Referer — must come from its Host's own origin, else 403; one
  # with neither is left to the CSRF check behind. The raw Host header is read, never X-Forwarded-Host (a page's fetch
  # can set that one).
  #
  # Both values come from the env with no default: WEB_HOST_PORT required, PUBLIC_HOST present (empty = loopback only).
  # Provider none (no sign-in) answers loopback only: a PUBLIC_HOST beside it stops the boot.
  class HostGuard
    class Invalid < StandardError; end

    SAFE = %w[GET HEAD].freeze
    MISDIRECTED = 421
    FORBIDDEN = 403

    # The allowed Hosts (lowercase host[:port]) → their origin.
    def self.origins(env, provider:)
      port = fetch(env, "WEB_HOST_PORT")
      raise Invalid, "WEB_HOST_PORT must be a port number 1-65535 (got #{port.inspect})" \
        unless DeployTemplate::PORT.call(port)

      public_host = fetch(env, "PUBLIC_HOST").downcase
      unless public_host.empty? || public_host.match?(DeployTemplate::HOSTNAME)
        raise Invalid, "PUBLIC_HOST must be empty (loopback only) or a hostname, no port (got #{public_host.inspect})"
      end
      if provider.is_a?(Auth::None) && !public_host.empty?
        raise Invalid, "auth provider none has no sign-in and answers loopback Hosts only, but PUBLIC_HOST is " \
                       "#{public_host.inspect}: empty it, or configure a sign-in provider (docs/AUTH.md)"
      end

      authority = port == "80" ? "" : ":#{port}"
      loopback = %w[127.0.0.1 localhost].to_h { |h| ["#{h}#{authority}", "http://#{h}#{authority}"] }
      public_host.empty? ? loopback : loopback.merge(public_host => "https://#{public_host}")
    end

    def self.fetch(env, key)
      env.fetch(key) { raise Invalid, "#{key} is not set (.env → docker-compose.yml x-app environment)" }
    end
    private_class_method :fetch

    def initialize(app, origins)
      @app = app
      @origins = origins.freeze
    end

    def call(env)
      origin = @origins[env["HTTP_HOST"].to_s.downcase]
      return refuse(MISDIRECTED, "host not allowed: this app answers only its configured hosts") unless origin
      unless SAFE.include?(env["REQUEST_METHOD"]) || same_origin?(env, origin)
        return refuse(FORBIDDEN, "origin not allowed: a change must come from this app's own page")
      end

      @app.call(env)
    end

    private

    def same_origin?(env, origin)
      sent = env["HTTP_ORIGIN"]
      return sent.downcase == origin if sent

      ref = env["HTTP_REFERER"]&.downcase
      ref.nil? || ref == origin || ref.start_with?("#{origin}/")
    end

    def refuse(status, message)
      [status, { "content-type" => "application/json", "cache-control" => "no-store" }, [JSON.dump(error: message)]]
    end
  end
end
