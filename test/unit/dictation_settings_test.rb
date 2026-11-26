# frozen_string_literal: true

require "test_helper"
require "busyyaks/dictation_settings_api"

# Settings → Dictation (card 634): what the mic runs as revisions — the document's checks (the server's url + token
# included), the served-model check against that server, the write-only token, base / conflict, the model list of an
# unsaved server, the Test button's call, and the API's statuses.
class DictationSettingsTest < Minitest::Test
  include DBReset

  S = Busyyaks::DictationSettings
  API = Busyyaks::DictationSettingsAPI
  TOKEN = "s3cret-token-abcd"
  ON = { "enabled" => true, "url" => "http://speech:8000", "token" => TOKEN, "model" => "/models/parakeet",
         "timeout_seconds" => 30, "max_seconds" => 120, }.freeze
  SHOWN = ON.merge("token" => nil, "token_set" => true, "token_hint" => "…abcd").freeze

  def db = Busyyaks::Kanban.db

  # a server listing `ids`; every call's [url, token] kept in @asked
  def serves(*ids)
    @asked = []
    list = lambda do |uri, token, _t|
      @asked << [uri.to_s, token]
      [200, JSON.generate(data: ids.map { { id: _1 } })]
    end
    { models: list }
  end

  def save_on(doc = ON) = API.save({ "base" => S.current_id(db), "doc" => doc }, by: "op", http: serves(doc["model"]))

  def test_a_document_is_exactly_the_six_keys
    s = S.settings!(ON)
    assert_equal ["/models/parakeet", "http://speech:8000/v1/audio/transcriptions", TOKEN],
                 [s.model, s.url.to_s, s.token]
    assert_nil S.settings!(ON.merge("token" => "")).token, "empty token = none sent"
    assert_nil S.settings!(ON.merge("enabled" => false))
    assert_nil S.settings!(ON.merge("enabled" => false, "url" => "", "token" => "")), "off needs no server"
    { nil => /must be an object/, ON.except("model") => /missing model/, ON.except("url") => /missing url/,
      ON.merge("x" => 1) => /unknown x/, ON.merge("enabled" => "yes") => /enabled must be true or false/,
      ON.merge("max_seconds" => 29) => /max_seconds must be an integer in 30..600/,
      ON.merge("model" => "") => /model must be a non-empty string/,
      ON.merge("url" => "", "token" => "") => /url is required while the mic is on/,
      ON.merge("url" => "") => /token is set but url is empty/,
      ON.merge("url" => "speech:8000") => /url must be an http\(s\) URL/,
      ON.merge("url" => 1) => /url must be a string/, ON.merge("token" => nil) => /token must be a string/,
      ON.merge("token" => "a b") => /token has whitespace/, }.each do |doc, msg|
      assert_match msg, assert_raises(S::Refused, doc.inspect) { S.settings!(doc) }.message
    end
  end

  def test_no_revision_is_off_and_the_newest_decides
    assert_nil S.get(db)
    status, body = save_on
    assert_equal 200, status
    assert_equal [120, TOKEN], [S.get(db).max_seconds, S.get(db).token]
    assert_equal SHOWN, body[:doc]
    assert_equal [{ id: body[:revision][:id], author: "op" }], body[:history].map { _1.slice(:id, :author) }
    assert_equal [["http://speech:8000/v1/models", TOKEN]] * 2, @asked, "the save checks its own server, the answer lists it"
    off = ON.merge("enabled" => false, "url" => "", "token" => "")
    assert_equal 200, API.save({ "base" => body[:revision][:id], "doc" => off }, by: "op")[0]
    assert_nil S.get(db)
    assert_equal 2, S.revisions(db)
  end

  # the token never leaves: no answer carries it; null keeps the saved one only while the url is the saved url
  def test_the_token_is_write_only_and_never_follows_a_new_url
    _, body = save_on
    refute_includes JSON.generate(API.show(http: serves("/models/parakeet"))), TOKEN
    assert_equal [["http://speech:8000/v1/models", TOKEN]], @asked, "show lists the saved server's models"
    assert_equal SHOWN, body[:doc]

    keep = ON.merge("token" => nil, "timeout_seconds" => 60)
    assert_equal 200, save_on(keep)[0]
    assert_equal [60, TOKEN], [S.get(db).timeout_seconds, S.get(db).token]

    moved = ON.merge("url" => "http://elsewhere:9000", "token" => nil)
    status, body = save_on(moved)
    assert_equal 422, status
    assert_equal %(token: the url is not the saved one ("http://speech:8000"): type its token, or leave it empty for none),
                 body[:error]
    assert_empty @asked, "the old bearer is never sent to the new url"
    assert_equal 200, save_on(moved.merge("token" => ""))[0]
    assert_nil S.get(db).token
    assert_equal [false, nil], API.show(http: serves("/models/parakeet"))[1][:doc].values_at("token_set", "token_hint")
    assert_nil S.redact(nil)
    assert_nil S.redact(ON.merge("token" => "short"))["token_hint"], "a short token shows no characters"
  end

  def test_an_enabled_model_must_be_one_the_server_serves
    status, body = API.save({ "base" => nil, "doc" => ON }, by: "op", http: serves("whisper", "llm"))
    assert_equal [422, { error: %(the speech server does not serve "/models/parakeet" (it serves: whisper, llm)) }],
                 [status, body]
    down = { models: ->(*) { raise Busyyaks::Dictation::Unavailable, "speech server timed out after 10 s" } }
    assert_match(/cannot be checked: speech server timed out/,
                 API.save({ "base" => nil, "doc" => ON }, by: "op", http: down)[1][:error])
    assert_equal 0, S.revisions(db)
  end

  def test_base_must_be_the_newest_and_given
    ok = serves("/models/parakeet")
    assert_equal 200, API.save({ "base" => nil, "doc" => ON }, by: "op", http: ok)[0]
    status, body = API.save({ "base" => nil, "doc" => ON }, by: "op", http: ok)
    assert_equal 409, status
    assert_match(/revision nil is not the newest/, body[:error])
    assert_equal 422, API.save({ "doc" => ON }, by: "op", http: ok)[0]
    assert_equal 422, API.save({ "base" => "1", "doc" => ON }, by: "op", http: ok)[0]
    assert_equal 422, API.save([], by: "op", http: ok)[0]
    assert_equal [422, { error: "author is required" }],
                 API.save({ "base" => S.current_id(db), "doc" => ON }, by: "", http: ok)
  end

  def test_show_lists_the_saved_servers_models_or_says_why_not
    _, body = API.show
    assert_equal({ revision: nil, doc: nil, models: nil, models_error: "no revision saved: type the server's URL" },
                 body.slice(:revision, :doc, :models, :models_error))
    assert_equal [30, 600], body[:limits][:max_seconds]
    save_on
    _, body = API.show(http: serves("a", "/models/parakeet"))
    assert_equal [["a", "/models/parakeet"], nil], body.values_at(:models, :models_error)
    down = { models: ->(*) { raise Busyyaks::Dictation::Unavailable, "speech server unreachable: x" } }
    assert_equal [nil, "speech server unreachable: x"], API.show(http: down)[1].values_at(:models, :models_error)
    API.save({ "base" => S.current_id(db), "doc" => ON.merge("enabled" => false, "url" => "", "token" => "") }, by: "op")
    assert_equal [nil, "no url saved"], API.show[1].values_at(:models, :models_error)
  end

  # the page's Connect: the models of a server typed in the form, nothing saved
  def test_models_of_an_unsaved_server
    status, body = API.models({ "url" => "http://other:1", "token" => "t0k" }, http: serves("x"))
    assert_equal [200, { models: ["x"], models_error: nil }], [status, body]
    assert_equal [["http://other:1/v1/models", "t0k"]], @asked
    assert_equal [422, { error: "url is required" }], API.models({ "url" => " ", "token" => "" })
    assert_match(/url must be an http/, API.models({ "url" => "nope", "token" => "" })[1][:error])
    assert_match(/token: the url is not the saved one/, API.models({ "url" => "http://other:1", "token" => nil })[1][:error])
    assert_equal 422, API.models([])[0]
    save_on
    assert_equal 200, API.models({ "url" => ON["url"], "token" => nil }, http: serves("y"))[0]
    assert_equal [["http://speech:8000/v1/models", TOKEN]], @asked, "null = the saved token, for the saved url"
    assert_equal 1, S.revisions(db), "a model list saves nothing"
  end

  # Test: one second of silence through the form's server + model (on or off, not saved), the time it took
  def test_check_sends_silence_through_the_chosen_model
    sent = nil
    http = serves("/models/parakeet").merge(transcribe: lambda do |uri, body, _b|
      sent = [uri.to_s, body]
      [200, JSON.generate(text: "", words: [])]
    end)
    ticks = [10.0, 10.25]
    status, body = API.check({ "doc" => ON.merge("enabled" => false) }, http: http, clock: -> { ticks.shift })
    assert_equal [200, { text: "", words: [], ms: 250 }], [status, body]
    assert_equal "http://speech:8000/v1/audio/transcriptions", sent[0]
    assert_includes sent[1], "name=\"model\"\r\n\r\n/models/parakeet\r\n"
    assert_equal 0, S.revisions(db)

    assert_equal 422, API.check({ "doc" => ON }, http: serves("other"))[0]
    assert_equal 422, API.check({ "doc" => ON.except("model") }, http: http)[0]
    assert_equal 422, API.check({ "doc" => ON.merge("url" => "", "token" => "") }, http: http)[0]
    assert_equal 422, API.check({ "doc" => ON.merge("token" => nil) }, http: http)[0], "no saved token to keep"
    assert_equal 422, API.check(nil, http: http)[0]
    bad = http.merge(transcribe: ->(*) { [500, '{"error":"boom"}'] })
    assert_equal [502, { error: "speech server answered 500: boom" }], API.check({ "doc" => ON }, http: bad)
  end

  def test_the_old_config_block_imports_as_on_with_its_server
    assert_equal ON, S.from_config_block(ON.except("enabled"))
    assert_match(/plus url and token/, assert_raises(S::Refused) { S.from_config_block(ON.except("enabled", "url")) }.message)
    assert_match(/nothing to import/, assert_raises(S::Refused) { S.from_config_block("none") }.message)
    assert_raises(S::Refused) { S.from_config_block([1]) }
  end
end
