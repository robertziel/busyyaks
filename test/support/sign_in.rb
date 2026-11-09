# frozen_string_literal: true

# Signing in through the test auth provider (test/fixtures/auth_stub): GET /login for the CSRF token, then its
# POST /auth/sign-in. For rack-test classes (`app`, `get`, `post`, `last_response`).
module SignIn
  CSRF = /name="csrf-token" content="([^"]*)"/

  def sign_in(email = "owner@example.com")
    get "/login"
    csrf = last_response.body[CSRF, 1].to_s
    post "/auth/sign-in", JSON.generate(email: email), "CONTENT_TYPE" => "application/json", "HTTP_X_CSRF_TOKEN" => csrf
    last_response.status
  end

  # the SPA shell's CSRF token, which every mutation sends back as X-CSRF-Token
  def shell_csrf_token
    get "/"
    last_response.body[CSRF, 1]
  end
end
