# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "rack/test"
require "stringio"
require "busyyaks/dictation"

# POST /api/dictation: signed in + CSRF, off → 404, the WAV forwarded to the speech server, its words back,
# every refusal and failure with its status and reason; the shell says whether the mic is on.
class DictationApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  D = Busyyaks::Dictation

  def app = Hanami.app

  def wav(seconds = 1)
    data = "\0".b * (seconds * 16_000 * 2)
    ["RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 1, 16_000, 32_000, 2, 16, "data", data.bytesize]
      .pack("a4 V a4 a4 V v v V V v v a4 V") + data
  end

  def setup
    super
    assert_equal 200, sign_in
    get "/"
    @csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
  end

  def post_wav(body, csrf: @csrf, prompt: nil)
    form = { audio: Rack::Test::UploadedFile.new(StringIO.new(body), "audio/wav", true, original_filename: "d.wav") }
    form[:prompt] = prompt if prompt
    post "/api/dictation", form, "HTTP_ACCEPT" => "application/json", "HTTP_X_CSRF_TOKEN" => csrf.to_s
    [last_response.status, JSON.parse(last_response.body)]
  end

  def with_client(http, &)
    s = D.parse!("model" => "whisper-1", "timeout_seconds" => 5, "max_seconds" => 30)
    c = D::Client.new(s, url: D.endpoint!("http://speech:8000"), token: nil, http: http)
    D.stub(:client, ->(_settings, _env) { c }, &)
  end

  def test_the_shell_says_the_mic_is_off_and_the_route_404s
    assert_includes last_response.body, '<meta name="dictation" content="off">'
    assert_equal [404, { "error" => "dictation is off: config/busyyaks.yml dictation is none" }], post_wav(wav)
  end

  def test_forwards_the_window_and_answers_the_words
    seen = nil
    http = lambda do |uri, body, _b|
      seen = [uri.to_s, body]
      [200, JSON.generate(text: " Ship it.", segments: [{ words: [{ word: " Ship", start: 0, end: 0.3 }] }])]
    end
    with_client(http) do
      status, body = post_wav(wav, prompt: "Fix the")
      assert_equal 200, status
      assert_equal({ "text" => "Ship it.", "words" => [{ "word" => " Ship", "start" => 0.0, "end" => 0.3 }] }, body)
    end
    assert_equal "http://speech:8000/v1/audio/transcriptions", seen[0]
    assert_includes seen[1], "name=\"prompt\"\r\n\r\nFix the\r\n"
  end

  def test_refusals_and_failures_carry_their_status_and_reason
    with_client(->(*) { [503, '{"error":"model loading"}'] }) do
      post "/api/dictation", { prompt: "x" }, "HTTP_X_CSRF_TOKEN" => @csrf
      no_part = [last_response.status, JSON.parse(last_response.body)]
      assert_equal [400, { "error" => "no audio part (multipart field `audio`)" }], no_part
      assert_equal [400, { "error" => "not a 16 kHz mono 16-bit PCM WAV" }], post_wav("RIFF#{'x' * 60}")
      assert_equal [413, { "error" => "recording too long: over 30 s" }], post_wav(wav(31))
      assert_equal [502, { "error" => "speech server answered 503: model loading" }], post_wav(wav)
    end
    Busyyaks::Config.stub(:load, -> { raise Busyyaks::Config::Invalid, "missing keys: dictation" }) do
      assert_equal [503, { "error" => "dictation is misconfigured: missing keys: dictation" }], post_wav(wav)
    end
    D.stub(:client, ->(*) { raise D::Invalid, "DICTATION_URL is not a URL" }) do
      assert_equal [503, { "error" => "dictation is misconfigured: DICTATION_URL is not a URL" }], post_wav(wav)
    end
  end

  def test_needs_the_csrf_token_and_a_sign_in
    with_client(->(*) { flunk "no call without CSRF" }) do
      assert_equal 403, post_wav(wav, csrf: "nope")[0]
    end
    clear_cookies # signed out: no session, so no CSRF token either — refused before anything is read
    with_client(->(*) { flunk "no call signed out" }) do
      assert_equal [403, { "error" => "invalid CSRF token" }], post_wav(wav)
    end
  end
end
