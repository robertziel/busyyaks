# frozen_string_literal: true


# The test suite's auth provider (test/fixtures/busyyaks.yml: provider test/fixtures/auth_stub): a gate with an
# allowlist and a sign-in endpoint that trusts the posted email — so the core's gate, CSRF, sign-out and QA cookie
# are tested against the provider interface alone. Also the smallest example of a custom provider.
#
#   auth: { provider: test/fixtures/auth_stub, allowed_emails: [owner@example.com] }
#
#   POST /auth/sign-in {"email": …}   → 200 + session (allowed) · 403 (not allowed)
module AuthStub
  class Provider < Busyyaks::Auth::Provider
    attr_reader :allowed_emails

    def initialize(settings, dir:)
      super
      Busyyaks::Auth.keys!(settings, %w[allowed_emails], provider: "stub")
      @allowed_emails = Busyyaks::Auth.email_list(settings["allowed_emails"], key: "allowed_emails", provider: "stub")
    end

    def email(session)
      e = session[:email]
      e if e && allowed_emails.include?(e.downcase)
    end

    def login_html(_helpers) = %(<p id="stub-login">stub sign-in</p>)
    def scripts(page) = ["/auth/stub-#{page}.js"]
    def qa_email = allowed_emails.first

    def endpoint(verb, path, req, res)
      return false unless verb == "POST" && path == "sign-in"

      email = req.params[:email].to_s.downcase
      return json(res, 403, error: "not_allowed") unless allowed_emails.include?(email)

      Busyyaks::Auth.sign_in(res.session, email)
      json(res, 200, ok: true)
    end
  end
end

Busyyaks::Auth.provide(AuthStub::Provider)
