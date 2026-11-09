# frozen_string_literal: true

require "rack/session"
require "rack/mock_request"
require "busyyaks/auth"

module Busyyaks
  # A signed-in session cookie for headless browser QA: the same cookie a real sign-in sets (Hanami's
  # cookie session, SESSION_SECRET, the app's own expiry), minted by the app's own session middleware. The identity is
  # the auth provider's QA identity (Auth::Provider#qa_email, read from its settings, e.g. the first allowed email) —
  # never an argument, so no command an agent runs holds an email (Claude Code's privacy hook stops every such call
  # with a dialog, which busyyaks relays as a Human input question). Provider none needs no cookie: it refuses.
  module QaCookie
    module_function

    # → "rack.session=<value>" (name=value, ready for a Cookie header or puppeteer's page.setCookie).
    def mint(email = Auth.provider.qa_email)
      unless Auth.provider.email({ email: email.to_s.downcase })
        raise ArgumentError, "refused: the auth provider does not accept #{email.inspect}"
      end

      sign(email.downcase)
    end

    # Signs any email, accepted or not — the app's per-request provider check is what refuses it. Tests only.
    def sign(email)
      klass, opts = Hanami.app.config.actions.sessions.middleware # [Rack::Session::Cookie, {secret:, expire_after:}]
      app = klass.new(->(env) { env["rack.session"][:email] = email; [200, {}, []] }, **opts.transform_keys(&:to_sym))
      _, headers, = app.call(Rack::MockRequest.env_for("https://qa.invalid/"))
      cookie = Array(headers["set-cookie"]).join("\n").split("\n").first.to_s.split(";").first.to_s
      raise "no session cookie was set" if cookie.empty?

      cookie
    end
  end
end
