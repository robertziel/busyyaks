# frozen_string_literal: true

require "test_helper"
require "busyyaks/dictation"

# Dictation (card #414): the settings' checks (card 634: Settings → Dictation, server included), the WAV the mic sends, and the
# speech server call — its request, both word-timing shapes, and every failure as Unavailable with the reason.
class DictationTest < Minitest::Test
  D = Busyyaks::Dictation
  ON = { "model" => "whisper-1", "timeout_seconds" => 5, "max_seconds" => 30 }.freeze

  def settings = D.parse!(ON)

  # a client of the server at `url` (DictationSettings.settings! sets url + token on an enabled revision's settings)
  def client_at(url, token = "")
    s = settings
    s.url = D.endpoint!(url)
    s.token = D.token!(token)
    D.client(s)
  end

  def wav(seconds = 1, rate: 16_000, channels: 1, bits: 16)
    data = "\0".b * (seconds * 16_000 * 2)
    ["RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, channels, rate, rate * 2, 2, bits, "data", data.bytesize]
      .pack("a4 V a4 a4 V v v V V v v a4 V") + data
  end

  def test_exactly_the_three_keys
    assert_equal "whisper-1", settings.model
    assert_equal 44 + (30 * 16_000 * 2), settings.max_bytes
    [nil, "none", "off", {}, ON.merge("extra" => 1), ON.except("model"), ON.merge("model" => " "),
     ON.merge("timeout_seconds" => 0), ON.merge("timeout_seconds" => "5"), ON.merge("max_seconds" => 601),
     ON.merge("max_seconds" => 29),].each do |v|
      assert_raises(D::Invalid, v.inspect) { D.parse!(v) }
    end
  end

  # off → no client; on → the settings' own server
  def test_the_client_is_the_settings_server
    assert_nil D.client(nil)
    assert_equal "http://s:8000/v1/audio/transcriptions", client_at("http://s:8000").url.to_s
  end

  # the server's model list: GET /v1/models next to the endpoint, with the bearer; every failure named
  def test_models_read_the_servers_list
    url = D.endpoint!("https://h/p/v1/audio/transcriptions")
    seen = nil
    http = lambda do |uri, token, timeout|
      seen = [uri.to_s, token, timeout]
      [200, JSON.generate(data: [{ id: "a" }, { id: "/models/b" }])]
    end
    assert_equal ["a", "/models/b"], D.models(url: url, token: "tok", timeout: 7, http: http)
    assert_equal ["https://h/p/v1/models", "tok", 7], seen
    { [401, "{}"] => /answered 401 to GET \/p\/v1\/models/, [200, "nope"] => /answered no model list/,
      [200, "{\"data\": [1]}"] => /answered no model list/, [200, "{\"data\": 1}"] => /answered no model list/,
      [200, "{"] => /answered no JSON/, }.each do |answer, msg|
      e = assert_raises(D::Unavailable) { D.models(url: url, token: nil, timeout: 1, http: ->(*) { answer }) }
      assert_match msg, e.message
    end
    assert_equal "https://h/p/v1/audio/transcriptions", url.to_s, "the settings' endpoint is not changed"
  end

  # the Test button's recording: one second of the mic's own WAV
  def test_silence_is_the_mics_wav
    assert_equal wav, D.silence
    assert_equal wav, D.wav!(D.silence, settings)
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

  # NeMo / Parakeet servers and OpenAI send words with no leading space: the space comes from the text, or the mic
  # would show "Movethecard"; a repeated word is placed after the one before it, never at its first match
  def test_words_without_their_space_take_it_from_the_text
    words = [{ word: "Move", start: 0, end: 0.3 }, { word: "the", start: 0.3, end: 0.5 },
             { word: "card,", start: 0.5, end: 0.7 }, { word: "again.", start: 0.7, end: 1.0 },]
    out = client { [200, JSON.generate(text: "Move the card, again.", segments: [{ words: words }])] }.transcribe(wav)
    assert_equal ["Move", " the", " card,", " again."], out[:words].map { |w| w[:word] }
    assert_equal "Move the card, again.", out[:words].map { |w| w[:word] }.join

    twice = %w[a a a].map { |w| { word: w, start: 0, end: 0.2 } }
    out = client { [200, JSON.generate(text: "a a a", words: twice)] }.transcribe(wav)
    assert_equal ["a", " a", " a"], out[:words].map { |w| w[:word] }
  end

  # the words spell the text in order: a word missing from it, a word found only past a skipped one ("the" inside
  # "there" once "go" is gone), or an empty word is refused, never placed by a guess
  def test_words_that_do_not_spell_the_text_are_refused
    { ["hi there", ["bye"]] => "bye", ["go there now", %w[the now]] => "the",
      ["hi", ["hi", " "]] => "", }.each do |(text, ws), bad|
      words = ws.map { |w| { word: w, start: 0, end: 0.2 } }
      e = assert_raises(Busyyaks::Dictation::Unavailable) do
        client { [200, JSON.generate(text: text, words: words)] }.transcribe(wav)
      end
      assert_equal %(speech server's word #{bad.inspect} does not follow in its text #{text.inspect}), e.message
    end
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
    assert_equal "ok", client_at(url, "s3cret").transcribe(wav)[:text]
    assert_equal "ok", client_at(url).transcribe(wav)[:text]
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
      client_at("http://127.0.0.1:#{garbage.addr[1]}").transcribe(wav)
    end
    assert_match(/speech server answered no HTTP: Net::HTTPBadResponse/, e.message)
    g.join
    garbage.close
    e = assert_raises(D::Unavailable) { client_at(url).transcribe(wav) }
    assert_match(/speech server unreachable: Errno::ECONNREFUSED/, e.message)
  end

  def test_the_real_models_call_sends_the_bearer_and_maps_network_errors
    server = TCPServer.new("127.0.0.1", 0)
    got = nil
    t = Thread.new do
      s = server.accept
      got = +""
      got << s.gets until got.end_with?("\r\n\r\n")
      s.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 22\r\n" \
              "Connection: close\r\n\r\n{\"data\":[{\"id\":\"m\"}]}")
      s.close
    end
    url = D.endpoint!("http://127.0.0.1:#{server.addr[1]}")
    assert_equal ["m"], D.models(url: url, token: "s3cret", timeout: 5)
    t.join
    assert_match(%r{\AGET /v1/models HTTP/1.1\r$}, got)
    assert_match(/^Authorization: Bearer s3cret\r$/i, got)
    server.close
    e = assert_raises(D::Unavailable) { D.models(url: url, token: "s3cret", timeout: 5) }
    assert_match(/speech server unreachable: Errno::ECONNREFUSED/, e.message)
  end
end
