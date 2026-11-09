# frozen_string_literal: true

module Busyyaks
  # The session cookie's options (config/app.rb), from .env — every value required, checked at boot, no default:
  #   SESSION_SECRET            ≥ 64 bytes (openssl rand -hex 64): the cookie's HMAC key
  #   SESSION_COOKIE_SECURE     true (the browser reaches the app over https, the TLS proxy) | false (plain http, localhost)
  #   SESSION_COOKIE_SAME_SITE  strict (never sent on a request another site starts — a link from elsewhere arrives
  #                             signed out) | lax (sent on a top-level GET from another site; never on its POSTs)
  # The cookie is always HttpOnly. A bad value stops the boot naming the key.
  module SessionCookie
    class Invalid < StandardError; end

    MIN_SECRET_BYTES = 64
    EXPIRE_AFTER = 60 * 60 * 24 * 7
    BOOLS = { "true" => true, "false" => false }.freeze
    SAME_SITE = { "strict" => :strict, "lax" => :lax }.freeze

    module_function

    def options(env)
      secret = env.fetch("SESSION_SECRET")
      if secret.bytesize < MIN_SECRET_BYTES
        raise Invalid, "SESSION_SECRET is #{secret.bytesize} bytes; at least #{MIN_SECRET_BYTES} (openssl rand -hex 64)"
      end

      { secret: secret, expire_after: EXPIRE_AFTER, httponly: true,
        secure: one_of(env, "SESSION_COOKIE_SECURE", BOOLS),
        same_site: one_of(env, "SESSION_COOKIE_SAME_SITE", SAME_SITE), }
    end

    def one_of(env, key, values)
      raw = env.fetch(key)
      values.fetch(raw) { raise Invalid, "#{key} must be #{values.keys.join(' or ')} (got #{raw.inspect})" }
    end
  end
end
