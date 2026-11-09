# frozen_string_literal: true

require "minitest/autorun"
require "rack"
require "rack/session"
require "rack/mock"
require_relative "../../lib/busyyaks/session_cookie"

# SESSION_COOKIE_SECURE=true behind the TLS proxy: Rack sets a Secure cookie only on a request it sees as https. Through
# the frp tunnel the app sees X-Forwarded-Proto: http (frps rewrites it) and X-Forwarded-Ssl: on (nginx sets it, frps
# keeps it) — measured on frp 0.65.0. The cookie must be set then, and never on a request with no TLS hop at all.
class SecureCookieTest < Minitest::Test
  OPTS = Busyyaks::SessionCookie.options("SESSION_SECRET" => "s" * 64, "SESSION_COOKIE_SECURE" => "true",
                                         "SESSION_COOKIE_SAME_SITE" => "strict")

  def app = Rack::Session::Cookie.new(->(env) { env["rack.session"]["k"] = 1; [200, {}, ["ok"]] }, **OPTS)

  def cookie(headers) = Rack::MockRequest.new(app).get("/login", headers).headers["set-cookie"].to_s

  def test_set_through_the_tunnel_as_nginx_and_frps_hand_it_on
    c = cookie("HTTP_X_FORWARDED_PROTO" => "http", "HTTP_X_FORWARDED_SSL" => "on", "HTTP_X_FORWARDED_FOR" => "127.0.0.1")
    assert_match(/\Arack\.session=/, c)
    assert_match(/; secure/i, c)
    assert_match(/; httponly/i, c)
    assert_match(/; samesite=strict/i, c)
  end

  def test_never_set_on_a_plain_http_request
    assert_empty cookie({})
    assert_empty cookie("HTTP_X_FORWARDED_PROTO" => "http")
  end
end
