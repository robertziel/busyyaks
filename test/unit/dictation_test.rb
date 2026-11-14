# frozen_string_literal: true

require "test_helper"
require "busyyaks/dictation"

# Dictation: config/busyyaks.yml `dictation` + the web's DICTATION_* env, the WAV the mic sends, and the
# speech server call — its request, both word-timing shapes, and every failure as Unavailable with the reason.
class DictationTest < Minitest::Test
  D = Busyyaks::Dictation
  ON = { "model" => "whisper-1", "timeout_seconds" => 5, "max_seconds" => 30 }.freeze

  def settings = D.parse!(ON)

  def wav(seconds = 1, rate: 16_000, channels: 1, bits: 16)
    data = "\0".b * (seconds * 16_000 * 2)
    ["RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, channels, rate, rate * 2, 2, bits, "data", data.bytesize]
      .pack("a4 V a4 a4 V v v V V v v a4 V") + data
  end

  def test_none_or_exactly_the_three_keys
    assert_nil D.parse!("none")
    assert_equal "whisper-1", settings.model
    assert_equal 44 + (30 * 16_000 * 2), settings.max_bytes
    [nil, "off", {}, ON.merge("extra" => 1), ON.except("model"), ON.merge("model" => " "),
     ON.merge("timeout_seconds" => 0), ON.merge("timeout_seconds" => "5"), ON.merge("max_seconds" => 601),
     ON.merge("max_seconds" => 29),].each do |v|
      assert_raises(D::Invalid, v.inspect) { D.parse!(v) }
    end
  end

  def test_boot_needs_both_keys_and_matches_the_config
    e = assert_raises(D::Invalid) { D.boot!(nil, {}) }
    assert_match(/DICTATION_URL, DICTATION_TOKEN not in the web service's env/, e.message)
    assert_nil D.boot!(nil, "DICTATION_URL" => "", "DICTATION_TOKEN" => "")
    e = assert_raises(D::Invalid) { D.boot!(nil, "DICTATION_URL" => "http://s:8000", "DICTATION_TOKEN" => "") }
    assert_match(/DICTATION_URL set but config\/busyyaks.yml dictation is none/, e.message)
    assert_raises(D::Invalid) { D.boot!(settings, "DICTATION_URL" => "", "DICTATION_TOKEN" => "") }
    c = D.boot!(settings, "DICTATION_URL" => "http://s:8000", "DICTATION_TOKEN" => "")
    assert_equal "http://s:8000/v1/audio/transcriptions", c.url.to_s
  end

  def test_the_url_is_a_base_or_the_endpoint_never_with_credentials
    assert_equal "https://h/v1/audio/transcriptions", D.endpoint!("https://h/").to_s
    assert_equal "https://h/p/v1/audio/transcriptions", D.endpoint!("https://h/p/v1/audio/transcriptions").to_s
    ["", "h:8000", "ftp://h", "https://u:p@h", "https://h/?a=1", "https://h/#x", "http://"].each do |u|
      assert_raises(D::Invalid, u) { D.endpoint!(u) }
    end
    assert_nil D.token!("")
    assert_raises(D::Invalid) { D.token!("a b") }
  end

  def test_only_the_mics_wav_within_max_seconds
    assert_equal wav, D.wav!(wav, settings)
    { wav(1, rate: 44_100) => /16 kHz mono/, wav(1, channels: 2) => /16 kHz mono/, wav(1, bits: 8) => /16 kHz mono/,
      ("x" * 100) => /16 kHz mono/, "".b => /empty/, wav(31) => /too long: over 30 s/, }.each do |bytes, msg|
      assert_match msg, assert_raises(D::Refused) { D.wav!(bytes, settings) }.message
    end
  end

  # the http port: (uri, body, boundary) → [status, body]
  def client(token: "t0k", &http) = D::Client.new(settings, url: D.endpoint!("http://s:8000"), token: token, http: http)

  def test_sends_the_window_as_multipart_and_reads_segment_words
    seen = nil
    c = client do |uri, body, boundary|
      seen = [uri.to_s, body, boundary]
      [200, JSON.generate(text: " Fix it. ", segments: [{ words: [{ word: " Fix", start: 0, end: 0.4 },
                                                                  { word: " it.", start: 0.4, end: 0.9, probability: 1 },
                                                                  { word: 3 },] }]),]
    end
    out = c.transcribe(wav, prompt: "#{'x' * 900}tail")
    words = [{ word: " Fix", start: 0.0, end: 0.4 }, { word: " it.", start: 0.4, end: 0.9 }]
    assert_equal({ text: "Fix it.", words: words }, out)
    url, body, boundary = seen
    assert_equal "http://s:8000/v1/audio/transcriptions", url
    { "model" => "whisper-1", "response_format" => "verbose_json", "timestamp_granularities[]" => "word",
      "timestamp_granularities" => "word", }.each do |k, v|
      assert_includes body, "name=\"#{k}\"\r\n\r\n#{v}\r\n"
    end
    prompt = body[/name="prompt"\r\n\r\n(.*?)\r\n/, 1]
    assert_equal 800, prompt.size
    assert prompt.end_with?("tail")
    assert_includes body, "filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF"
    assert body.end_with?("--#{boundary}--\r\n")
  end

  def test_top_level_words_and_no_prompt_field_when_empty
    body = nil
    out = client do |_u, b, _|
      body = b
      [200, JSON.generate(text: "hi", words: [{ word: "hi", start: 0, end: 0.2 }])]
    end.transcribe(wav)
    assert_equal [{ word: "hi", start: 0.0, end: 0.2 }], out[:words]
    refute_includes body, "name=\"prompt\""
  end

  def test_silence_is_no_segments_and_an_answer_without_word_timings_is_refused
    assert_equal({ text: "", words: [] }, client { [200, '{"text":"","segments":[]}'] }.transcribe(wav))
    [{ text: "hi" }, { text: "hi", segments: [{ text: "hi" }] }].each do |answer|
      e = assert_raises(D::Unavailable) { client { [200, JSON.generate(answer)] }.transcribe(wav) }
      assert_match(/answered no word timings/, e.message)
    end
  end

  def test_every_server_failure_is_unavailable_with_its_reason
    { [500, '{"error":{"message":"model not loaded"}}'] => "speech server answered 500: model not loaded",
      [404, '{"detail":"Not Found"}'] => "speech server answered 404: Not Found",
      [502, "<html>bad gateway</html>"] => "speech server answered 502: <html>bad gateway</html>",
      [200, "nope"] => "speech server answered no JSON",
      [200, '{"segments":[]}'] => "speech server answered no text",
      [200, '{"text":"x","segments":[{"text":"x"}]}'] => /\Aspeech server answered no word timings /, }.each do |answer, msg|
      e = assert_raises(D::Unavailable) { client { answer }.transcribe(wav) }
      msg.is_a?(Regexp) ? assert_match(msg, e.message) : assert_equal(msg, e.message)
    end
  end

  def test_the_real_http_call_sends_the_bearer_only_when_set_and_maps_network_errors
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    got = []
    t = Thread.new do
      2.times do
        s = server.accept
        head = +""
        head << s.gets until head.end_with?("\r\n\r\n")
        len = head[/content-length: (\d+)/i, 1].to_i
        s.read(len)
        got << head
        s.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 24\r\n" \
                "Connection: close\r\n\r\n{\"text\":\"ok\",\"words\":[]}")
        s.close
      end
    end
    url = "http://127.0.0.1:#{port}"
    assert_equal "ok", D.client(settings, "DICTATION_URL" => url, "DICTATION_TOKEN" => "s3cret").transcribe(wav)[:text]
    assert_equal "ok", D.client(settings, "DICTATION_URL" => url, "DICTATION_TOKEN" => "").transcribe(wav)[:text]
    t.join
    assert_match(/^Authorization: Bearer s3cret\r$/i, got[0])
    refute_match(/^Authorization:/i, got[1])
    assert_match(%r{^Content-Type: multipart/form-data; boundary=busyyaks\h{24}\r$}i, got[0])
    server.close
    garbage = TCPServer.new("127.0.0.1", 0)
    g = Thread.new do
      s = garbage.accept
      s.gets
      s.write("not http at all\r\n\r\n")
      s.close
    end
    e = assert_raises(D::Unavailable) do
      D.client(settings, "DICTATION_URL" => "http://127.0.0.1:#{garbage.addr[1]}", "DICTATION_TOKEN" => "").transcribe(wav)
    end
    assert_match(/speech server answered no HTTP: Net::HTTPBadResponse/, e.message)
    g.join
    garbage.close
    e = assert_raises(D::Unavailable) { D.client(settings, "DICTATION_URL" => url, "DICTATION_TOKEN" => "").transcribe(wav) }
    assert_match(/speech server unreachable: Errno::ECONNREFUSED/, e.message)
  end
end
