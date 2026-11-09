# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "busyyaks/auth"

# the auth provider interface — none, a provider directory, and every refusal at build time.
class AuthTest < Minitest::Test
  A = Busyyaks::Auth

  def build(block, root: Hanami.app.root.to_s) = A.build(block, root: root)

  def provider_dir(body)
    dir = Dir.mktmpdir("auth-provider")
    File.write(File.join(dir, "provider.rb"), body)
    dir
  end

  def test_none_is_the_operator_with_nothing_to_sign_out
    p = build({ "provider" => "none", "allow_unauthenticated" => true })
    assert_instance_of A::None, p
    assert_match(/AUTH DISABLED .* every request to the web app is the operator/, p.banner)
    assert_equal "operator", p.email({})
    refute p.sign_out?
    assert_equal [], p.scripts(:login)
    assert_raises(A::Invalid) { p.qa_email }
  end

  # no sign-in is an explicit opt-in: `allow_unauthenticated: true` exactly, nothing else beside it
  def test_none_needs_the_explicit_opt_in_and_nothing_else
    [{}, { "allow_unauthenticated" => false }, { "allow_unauthenticated" => "true" },
     { "allow_unauthenticated" => true, "allowed_emails" => ["a@b"] }, { "allowed_emails" => ["a@b"] },].each do |s|
      e = assert_raises(A::Invalid, s.inspect) { build({ "provider" => "none" }.merge(s)) }
      assert_includes e.message, "`allow_unauthenticated: true` beside `provider: none`", s.inspect
    end
  end

  def test_a_provider_prints_no_banner_by_default
    assert_nil A::Provider.new({}, dir: nil).banner
  end

  def test_no_provider_is_refused
    [nil, {}, { "provider" => "" }, { "provider" => 1 }].each do |bad|
      assert_raises(A::Invalid, bad.inspect) { build(bad) }
    end
  end

  def test_a_directory_without_provider_rb_is_refused
    e = assert_raises(A::Invalid) { build({ "provider" => "nope/none-here" }) }
    assert_includes e.message, "provider.rb"
  end

  def test_provider_rb_must_provide_a_provider_subclass
    e = assert_raises(A::Invalid) { build({ "provider" => provider_dir("# nothing\n") }) }
    assert_includes e.message, "did not call Busyyaks::Auth.provide"
    e = assert_raises(A::Invalid) { build({ "provider" => provider_dir("Busyyaks::Auth.provide(String)\n") }) }
    assert_includes e.message, "is not a Busyyaks::Auth::Provider"
    assert_raises(A::Invalid) { A.provide(String) } # only while Auth.build loads a provider.rb
  end

  def test_a_custom_provider_gets_its_settings_and_directory
    dir = provider_dir(<<~RUBY)
      class AuthTestProvider < Busyyaks::Auth::Provider
        def email(session) = session[:email]
      end
      Busyyaks::Auth.provide(AuthTestProvider)
    RUBY
    p = build({ "provider" => File.basename(dir), "k" => "v" }, root: File.dirname(dir))
    assert_equal [{ "k" => "v" }, dir], [p.settings, p.dir]
    assert_equal "a@b", p.email({ email: "a@b" })
    assert_same p.class, build({ "provider" => dir }).class, "loaded once"
  end

  def test_the_test_suites_provider_is_the_stub
    assert_equal "AuthStub::Provider", A.provider.class.name
    assert_equal "owner@example.com", A.provider.qa_email
  end

  def test_csp_is_the_cores_plus_the_providers
    assert_equal({ connect_src: "'self'", script_src: "'self'", img_src: "'self' data: https://avatars.githubusercontent.com" },
                 A.csp_sources({}))
    got = A.csp_sources({ connect_src: ["https://id.test"], img_src: ["https://id.test"] })
    assert_equal "'self' https://id.test", got[:connect_src]
    assert_equal "'self' data: https://avatars.githubusercontent.com https://id.test", got[:img_src]
    e = assert_raises(A::Invalid) { A.csp_sources({ frame_src: ["x"] }) }
    assert_includes e.message, "frame_src"
  end

  def test_identify_writes_the_providers_answer_to_the_session
    session = { email: "stranger@example.com" }
    assert_nil A.identify(session)
    assert_nil session[:email]
    A.use(A::None.new(A::None::OPT_IN)) { assert_equal "operator", A.identify(session) }
    assert_equal "operator", session[:email]
  end

  def test_settings_helpers
    assert_raises(A::Invalid) { A.keys!({ "a" => 1 }, %w[a b], provider: "x") }
    assert_raises(A::Invalid) { A.keys!({ "a" => 1, "b" => 1, "c" => 1 }, %w[a b], provider: "x") }
    assert_nil A.keys!({ "a" => 1, "b" => 1 }, %w[a b], provider: "x")
    assert_equal ["a@b.io"], A.email_list([" A@b.io "], key: "k", provider: "x")
    [nil, [], ["nope"], "a@b"].each { |bad| assert_raises(A::Invalid) { A.email_list(bad, key: "k", provider: "x") } }
  end
end
