# frozen_string_literal: true

require "erb"
require "json"
require "monitor"

module Busyyaks
  # Sign-in is a PROVIDER, chosen by config/busyyaks.yml `auth`; the core knows only this interface.
  #
  #   auth: { provider: none, allow_unauthenticated: true }
  #                                                  no sign-in: every request is the operator (localhost only). The
  #                                                  opt-in key is required, and the boot prints Auth::None::BANNER
  #   auth: { provider: <dir>, <its own keys…> }      a custom provider: <dir> (relative to the app root) holds
  #                                                  provider.rb, which defines a subclass of Auth::Provider and
  #                                                  calls Busyyaks::Auth.provide(<class>) (Busyyaks::Auth is loaded
  #                                                  before it); the other keys of the
  #                                                  block are its settings, validated by its constructor
  #
  # There is no default provider: a missing `auth` key, a missing or unknown provider, or settings the provider
  # refuses stop the boot (Auth::Invalid). The request's identity is `session[:email]`, written by Auth.identify on
  # every request from the provider's answer — so a provider that stops vouching for someone ends their access at once.
  module Auth
    class Invalid < StandardError; end

    NONE = "none"
    # provider none's identity: the author of everything done in the web UI
    OPERATOR = "operator"
    # CSP directives a provider may extend (each starts at the core's own sources)
    CSP_BASE = { connect_src: %w['self'], script_src: %w['self'],
                 # + GitHub's avatar CDN (the /github feed, tl:github); report/card markdown never loads a remote image
                 img_src: %w['self' data: https://avatars.githubusercontent.com], }.freeze

    # What the core asks of a provider. Override what differs; the defaults are a provider with no page assets.
    class Provider
      attr_reader :settings, :dir

      def initialize(settings, dir:)
        @settings = settings
        @dir = dir
      end

      # The signed-in identity (an email, or any stable name) of the session, or nil = not signed in. Called on every
      # request: re-check the allowlist here.
      def email(_session) = raise(NotImplementedError, "#{self.class}#email")

      # The sign-in page's body (HTML, inside the core's card + logo), for a signed-out request to GET /login.
      def login_html(_helpers) = raise(NotImplementedError, "#{self.class}#login_html")

      # Script URLs the page loads (defer): page = :login (the sign-in page) or :app (the SPA shell).
      def scripts(_page) = []

      # Extra CSP sources: { connect_src: [...], script_src: [...], img_src: [...] } (only those keys).
      def csp = {}

      # GET|POST /auth/<path>: the provider's own endpoints (a token exchange, its script). Handle it on `res`
      # (Auth.sign_in(res.session, email) to sign in) and return true; false → 404.
      def endpoint(_verb, _path, _req, _res) = false

      # Whether there is a session to end: the SPA shows "Sign out" and POST /logout clears it.
      def sign_out? = true

      # A line the boot prints to stderr (config/app.rb), or nil: what an operator must not miss in the logs.
      def banner = nil

      # bin/qa-cookie's identity (headless browser QA): an identity this provider accepts, read from its settings.
      def qa_email = raise(Invalid, "auth provider #{self.class}: no QA identity")

      private

      def json(res, status, body)
        res.status = status
        res.headers["Content-Type"] = "application/json"
        res.body = JSON.dump(body)
        true
      end

      def render(file, **locals) = ERB.new(File.read(File.join(dir, file)), trim_mode: "-").result_with_hash(locals)
    end

    # No sign-in: every request is the operator. Nothing to sign out of; no cookie needed for QA.
    #
    # Guarded by an explicit opt-in, not by a loopback check: inside Docker a request from the host's own browser
    # arrives from the bridge gateway (never 127.0.0.1), and a reverse proxy on the same host makes a request from the
    # internet arrive from loopback — a source-address check would refuse the safe setup and admit the unsafe one. So the
    # config has to say it (`allow_unauthenticated: true`), and every boot prints BANNER where the logs show it.
    class None < Provider
      OPT_IN = { "allow_unauthenticated" => true }.freeze
      BANNER = "*** AUTH DISABLED — config/busyyaks.yml auth.provider: none (allow_unauthenticated: true): every request " \
               "to the web app is the operator, with no sign-in. Keep it on localhost or an ssh tunnel, never behind a " \
               "public proxy (docs/DEPLOY.md). ***"

      def initialize(settings, dir: nil)
        unless settings == OPT_IN
          raise Invalid, "auth provider none lets every request in as the operator: say so with exactly " \
                         "`allow_unauthenticated: true` beside `provider: none` (got #{settings.inspect}), or name a provider"
        end

        super
      end

      def banner = BANNER

      def email(_session) = OPERATOR
      def sign_out? = false
      def qa_email = raise(Invalid, "auth provider none: every request is the operator, no cookie is needed")
    end

    # The provider (set at boot, read by every Puma thread) and the provider.rb registry. A Monitor, not a Mutex: a
    # provider.rb calls Auth.provide while Auth.provider_class holds the lock for its `require`.
    LOCK = Monitor.new

    module_function

    # config/busyyaks.yml `auth` (Config#auth: a Hash with "provider") → a provider instance.
    def build(block, root:)
      unless block.is_a?(Hash) && block["provider"].is_a?(String) && !block["provider"].empty?
        raise Invalid, "auth must be a mapping with a provider key (none, or a provider directory)"
      end

      name = block["provider"]
      settings = block.reject { |k, _| k == "provider" }
      return None.new(settings) if name == NONE

      dir = File.expand_path(name, root)
      file = File.join(dir, "provider.rb")
      unless File.file?(file)
        raise Invalid, "auth provider #{name.inspect}: #{file} not found (provider is none or a directory holding provider.rb)"
      end

      klass = provider_class(file)
      raise Invalid, "#{file}: #{klass} is not a Busyyaks::Auth::Provider" unless klass.is_a?(Class) && klass < Provider

      klass.new(settings, dir: dir)
    end

    def provider_class(file)
      LOCK.synchronize do
        @registry ||= {}
        unless @registry.key?(file)
          @loading = file
          begin
            require file
          ensure
            @loading = nil
          end
        end
        @registry.fetch(file) { raise Invalid, "#{file} did not call Busyyaks::Auth.provide(<class>)" }
      end
    end

    # Called by a provider.rb while it loads.
    def provide(klass)
      LOCK.synchronize do
        raise Invalid, "Busyyaks::Auth.provide is called only from a provider.rb that Auth.build loads" unless @loading

        @registry[@loading] = klass
      end
    end

    def setup!(provider) = swap_provider(provider).then { provider }
    def provider = LOCK.synchronize { @provider } || raise(Invalid, "auth provider not set up (config/app.rb)")

    # Tests: run the block with another provider (the lock is not held while the block runs).
    def use(other)
      prev = swap_provider(other)
      yield
    ensure
      swap_provider(prev)
    end

    # Sets the provider; returns the one it replaces.
    def swap_provider(other) = LOCK.synchronize { @provider.tap { @provider = other } }

    # The request's identity, written to the session (nil when signed out).
    def identify(session)
      email = provider.email(session)
      session[:email] = email unless session[:email] == email
      email
    end

    # Where sign-in returns to: GET /login?next=<this app's path>, carried by a page request that found nobody signed in
    # (a card link opened from another site arrives without the session cookie under SameSite=strict). Only a path
    # of this app — "/" then no second "/" or "\\", no scheme, no control characters or spaces — else Invalid: an
    # unsafe `next` is refused, never swapped for "/".
    NEXT_PATH = %r{\A/(?![/\\])[^\s\\]*\z}
    NEXT_MAX = 2048

    def next_path!(raw)
      unless raw.is_a?(String) && raw.length <= NEXT_MAX && raw.match?(NEXT_PATH) && !raw.match?(/[[:cntrl:]]/)
        raise Invalid, "next must be a path of this app (/…), at most #{NEXT_MAX} characters"
      end

      raw
    end

    def sign_in(session, email) = (session[:email] = email)
    def sign_out(session) = (session[:email] = nil)

    # → { connect_src: "'self' …", script_src: …, img_src: … } for Hanami's content_security_policy.
    def csp_sources(extra = provider.csp)
      raise Invalid, "provider csp must be a Hash" unless extra.is_a?(Hash)

      unknown = extra.keys - CSP_BASE.keys
      if unknown.any?
        raise Invalid, "provider csp: unknown directives #{unknown.join(', ')} (allowed: #{CSP_BASE.keys.join(', ')})"
      end

      CSP_BASE.to_h { |k, base| [k, (base + Array(extra[k])).uniq.join(" ")] }
    end

    # Settings helpers for providers: exactly these keys, and a non-empty email list (lowercased).
    def keys!(settings, required, provider:)
      unknown = settings.keys - required
      missing = required - settings.keys
      raise Invalid, "auth provider #{provider}: unknown keys #{unknown.join(', ')}" if unknown.any?
      raise Invalid, "auth provider #{provider}: missing keys #{missing.join(', ')}" if missing.any?
    end

    def email_list(value, key:, provider:)
      unless value.is_a?(Array) && value.any? && value.all? { |v| v.is_a?(String) && v.include?("@") }
        raise Invalid, "auth provider #{provider}: #{key} must be a non-empty list of emails"
      end

      value.map { |v| v.strip.downcase }
    end
  end
end
