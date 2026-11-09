# frozen_string_literal: true

require "test_helper"
require "busyyaks/auth"
require "busyyaks/host_guard"

# DNS rebinding: the web app answers only the hosts the deployment names (PUBLIC_HOST, 127.0.0.1 / localhost on
# WEB_HOST_PORT), and a mutation's Origin / Referer must be that host's own origin — before any handler runs.
class HostGuardTest < Minitest::Test
  G = Busyyaks::HostGuard
  NONE = Busyyaks::Auth::None.new(Busyyaks::Auth::None::OPT_IN)
  PROVIDER = Busyyaks::Auth::Provider.new({}, dir: nil)
  ENV_OK = { "WEB_HOST_PORT" => "3096", "PUBLIC_HOST" => "Busy.Example.COM" }.freeze

  # the inner app: records that it ran
  class Inner
    attr_reader :calls

    def initialize = @calls = 0

    def call(_env)
      @calls += 1
      [200, { "content-type" => "text/plain" }, ["ok"]]
    end
  end

  def guard(env = ENV_OK, provider: PROVIDER)
    @inner = Inner.new
    G.new(@inner, G.origins(env, provider: provider))
  end

  def request(app, method, host, headers = {})
    env = { "REQUEST_METHOD" => method, "PATH_INFO" => "/api/launch", "rack.input" => StringIO.new }
    env["HTTP_HOST"] = host if host
    app.call(env.merge(headers))
  end

  def test_origins_are_loopback_on_the_web_port_and_the_public_host_over_https
    assert_equal({ "127.0.0.1:3096" => "http://127.0.0.1:3096", "localhost:3096" => "http://localhost:3096",
                   "busy.example.com" => "https://busy.example.com", },
                 G.origins(ENV_OK, provider: PROVIDER))
    assert_equal({ "127.0.0.1:3096" => "http://127.0.0.1:3096", "localhost:3096" => "http://localhost:3096" },
                 G.origins(ENV_OK.merge("PUBLIC_HOST" => ""), provider: PROVIDER))
  end

  # no defaults: a missing or malformed value stops the boot, naming the key
  def test_missing_or_malformed_values_stop_the_boot
    { {} => /WEB_HOST_PORT/, { "WEB_HOST_PORT" => "3096" } => /PUBLIC_HOST/,
      ENV_OK.merge("WEB_HOST_PORT" => "0") => /WEB_HOST_PORT .*1-65535/,
      ENV_OK.merge("WEB_HOST_PORT" => "80x") => /WEB_HOST_PORT/,
      ENV_OK.merge("PUBLIC_HOST" => "evil.example:443") => /PUBLIC_HOST .*hostname/,
      ENV_OK.merge("PUBLIC_HOST" => "a b") => /PUBLIC_HOST/, }.each do |env, msg|
      err = assert_raises(G::Invalid, env.inspect) { G.origins(env, provider: PROVIDER) }
      assert_match msg, err.message
    end
  end

  # provider none = no sign-in: only loopback Hosts, so a public host with it is refused at boot
  def test_provider_none_with_a_public_host_stops_the_boot
    err = assert_raises(G::Invalid) { G.origins(ENV_OK, provider: NONE) }
    assert_match(/provider none .*PUBLIC_HOST/, err.message)
    assert_equal %w[127.0.0.1:3096 localhost:3096],
                 G.origins(ENV_OK.merge("PUBLIC_HOST" => ""), provider: NONE).keys
  end

  # the rebinding request: evil.example resolved to 127.0.0.1 — its Host is the attacker's name
  def test_a_foreign_host_is_421_and_no_handler_runs
    app = guard
    ["evil.example", "evil.example:3096", "127.0.0.1:2300", "localhost", "127.0.0.1", "0.0.0.0:3096",
     "busy.example.com.evil.example", "busy.example.com:3096", "[::1]:3096", "", nil,].each do |host|
      %w[GET POST HEAD].each do |verb|
        status, headers, body = request(app, verb, host)
        assert_equal 421, status, "#{verb} #{host.inspect}"
        assert_equal "application/json", headers["content-type"]
        assert_match(/host not allowed/, body.join) unless verb == "HEAD"
      end
    end
    assert_equal 0, @inner.calls
  end

  # X-Forwarded-Host is settable by a page's fetch: never read
  def test_forwarded_host_is_ignored
    status, = request(guard, "GET", "evil.example", "HTTP_X_FORWARDED_HOST" => "busy.example.com")
    assert_equal 421, status
    assert_equal 0, @inner.calls
  end

  def test_allowed_hosts_pass_case_insensitively
    app = guard
    %w[127.0.0.1:3096 localhost:3096 LOCALHOST:3096 busy.example.com BUSY.example.com].each do |host|
      assert_equal 200, request(app, "GET", host).first, host
    end
    assert_equal 5, @inner.calls
  end

  def test_a_mutation_needs_its_hosts_own_origin
    app = guard
    ok = { "busy.example.com" => "https://busy.example.com", "127.0.0.1:3096" => "http://127.0.0.1:3096",
           "localhost:3096" => "http://LOCALHOST:3096", }
    ok.each { |host, origin| assert_equal 200, request(app, "POST", host, "HTTP_ORIGIN" => origin).first, host }
    bad = [["busy.example.com", "http://busy.example.com"], ["busy.example.com", "https://evil.example"],
           ["busy.example.com", "https://busy.example.com:8443"], ["busy.example.com", "null"],
           ["127.0.0.1:3096", "http://localhost:3096"], ["127.0.0.1:3096", "https://busy.example.com"],
           ["127.0.0.1:3096", "http://127.0.0.1:3096.evil.example"],]
    %w[POST PUT PATCH DELETE].each do |verb|
      bad.each do |host, origin|
        status, _, body = request(app, verb, host, "HTTP_ORIGIN" => origin)
        assert_equal 403, status, "#{verb} #{host} #{origin}"
        assert_match(/origin not allowed/, body.join)
      end
    end
    assert_equal 3, @inner.calls
  end

  # no Origin: the Referer is checked the same way (its origin, then a path)
  def test_a_mutation_without_origin_checks_the_referer
    app = guard
    assert_equal 200, request(app, "POST", "busy.example.com", "HTTP_REFERER" => "https://busy.example.com/projects/x").first
    assert_equal 200, request(app, "POST", "busy.example.com", "HTTP_REFERER" => "https://busy.example.com").first
    ["https://busy.example.com.evil.example/", "https://evil.example/https://busy.example.com/",
     "http://busy.example.com/", "https://busy.example.com:444/",].each do |ref|
      assert_equal 403, request(app, "POST", "busy.example.com", "HTTP_REFERER" => ref).first, ref
    end
    assert_equal 2, @inner.calls
  end

  # neither header (curl, a non-browser client): the CSRF token behind it still decides; GET is never origin-checked
  def test_no_origin_or_referer_and_safe_methods_pass_to_the_app
    app = guard
    assert_equal 200, request(app, "POST", "busy.example.com").first
    assert_equal 200, request(app, "GET", "busy.example.com", "HTTP_ORIGIN" => "https://evil.example").first
    assert_equal 2, @inner.calls
  end
end
