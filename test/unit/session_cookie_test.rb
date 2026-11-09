# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/busyyaks/session_cookie"

# The session cookie's flags are .env values checked at boot: a ≥ 64-byte secret, Secure and SameSite stated (no
# default), always HttpOnly.
class SessionCookieTest < Minitest::Test
  S = Busyyaks::SessionCookie
  OK = { "SESSION_SECRET" => "s" * 64, "SESSION_COOKIE_SECURE" => "true", "SESSION_COOKIE_SAME_SITE" => "strict" }.freeze

  def test_options_from_env
    assert_equal({ secret: "s" * 64, expire_after: 604_800, httponly: true, secure: true, same_site: :strict }, S.options(OK))
    o = S.options(OK.merge("SESSION_COOKIE_SECURE" => "false", "SESSION_COOKIE_SAME_SITE" => "lax"))
    assert_equal [false, :lax], [o[:secure], o[:same_site]]
  end

  def test_a_short_secret_stops_the_boot
    e = assert_raises(S::Invalid) { S.options(OK.merge("SESSION_SECRET" => "s" * 63)) }
    assert_equal "SESSION_SECRET is 63 bytes; at least 64 (openssl rand -hex 64)", e.message
  end

  def test_flags_are_stated_never_defaulted
    %w[SESSION_SECRET SESSION_COOKIE_SECURE SESSION_COOKIE_SAME_SITE].each do |k|
      assert_raises(KeyError, k) { S.options(OK.except(k)) }
    end
    bad = { "SESSION_COOKIE_SECURE" => ["", "1", "yes", "TRUE"], "SESSION_COOKIE_SAME_SITE" => ["", "none", "Strict"] }
    bad.each do |k, vs|
      vs.each do |v|
        e = assert_raises(S::Invalid, "#{k}=#{v}") { S.options(OK.merge(k => v)) }
        assert_match(/\A#{k} must be /, e.message)
      end
    end
  end
end
