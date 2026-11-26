# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "rack/test"
require "busyyaks/dictation_settings_api"

# GET / POST /api/settings/dictation, POST …/test and …/models over HTTP (card 634): signed in + CSRF, the API's
# statuses, the token never in an answer.
class DictationSettingsApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  def app = Hanami.app

  def setup
    super
    assert_equal 200, sign_in
    get "/"
    @csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
  end

  def post_json(path, body, csrf: @csrf)
    post path, JSON.generate(body), "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json",
                                    "HTTP_X_CSRF_TOKEN" => csrf.to_s
    [last_response.status, JSON.parse(last_response.body)]
  end

  def test_show_save_and_check_over_http
    get "/api/settings/dictation", {}, "HTTP_ACCEPT" => "application/json"
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal [nil, "no revision saved: type the server's URL"], body.values_at("revision", "models_error")

    # off, its server kept (127.0.0.1:9 = discard: nothing listens, so every server read fails fast)
    doc = { "enabled" => false, "url" => "http://127.0.0.1:9", "token" => "s3cret-token-abcd", "model" => "m",
            "timeout_seconds" => 5, "max_seconds" => 30, }
    status, saved = post_json("/api/settings/dictation", { base: nil, doc: doc })
    assert_equal 200, status
    assert_equal doc.merge("token" => nil, "token_set" => true, "token_hint" => "…abcd"), saved["doc"]
    refute_includes last_response.body, "s3cret"
    get "/api/settings/dictation", {}, "HTTP_ACCEPT" => "application/json"
    refute_includes last_response.body, "s3cret"
    assert_equal 409, post_json("/api/settings/dictation", { base: nil, doc: doc })[0]
    on = doc.merge("enabled" => true, "token" => nil)
    status, refused = post_json("/api/settings/dictation", { base: saved["revision"]["id"], doc: on })
    assert_equal 422, status
    assert_match(/the model cannot be checked: speech server unreachable/, refused["error"])
    assert_equal 422, post_json("/api/settings/dictation/test", { doc: on })[0]
    status, listed = post_json("/api/settings/dictation/models", { url: doc["url"], token: nil })
    assert_equal 200, status
    assert_match(/speech server unreachable/, listed["models_error"])
    assert_equal 422, post_json("/api/settings/dictation/models", { url: "x", token: "" })[0]
    assert_equal 403, post_json("/api/settings/dictation", { base: nil, doc: doc }, csrf: "nope")[0]
    assert_equal 403, post_json("/api/settings/dictation/models", { url: doc["url"], token: "" }, csrf: "nope")[0]
  end
end
