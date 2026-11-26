# frozen_string_literal: true

require_relative "dictation_settings"
require_relative "kanban"
require_relative "clock"

module Busyyaks
  # Settings → Dictation (card 634): the operator's read and write of what the mic runs, as [status, body] (the actions
  # are one line each; test/unit/dictation_settings_test.rb drives this directly). `http` = the speech server calls
  # ({models:, transcribe:}: tests stub them). The token never leaves: every doc answered is redacted (token null +
  # token_set + token_hint); a doc sent with token null keeps the saved one while its url is the saved url.
  #   show        → 200 {revision: {id, author, at} | null, doc | null, models: [ids] | null (the saved server's),
  #                      models_error, limits, history (newest 20), revisions}
  #   save(body)  → 200 the same for the new revision · 409 base is not the newest · 422 refused (verbatim)
  #   models(body) → 200 {models, models_error} of {url, token} (an unsaved server) · 422 refused
  #   check(body) → 200 {text, words, ms} from one second of silence through {doc}'s server + model (not saved) ·
  #                 422 refused · 502 the server's error
  module DictationSettingsAPI
    # how long the model list may take (the page's read; the transcription's own timeout is the revision's)
    MODELS_TIMEOUT = 10
    LIMITS = { timeout_seconds: [1, 300], max_seconds: [Dictation::MIN_WINDOW_SECONDS, 600] }.freeze

    module_function

    def show(db: Kanban.db, http: nil)
      cur = DictationSettings.current(db)
      models, error = cur ? list(cur[:doc], http) : [nil, "no revision saved: type the server's URL"]
      [200, { revision: cur&.slice(:id, :author, :at), doc: DictationSettings.redact(cur&.fetch(:doc)),
              models: models, models_error: error, limits: LIMITS,
              history: DictationSettings.history(db), revisions: DictationSettings.revisions(db), },]
    end

    def save(body, by:, db: Kanban.db, http: nil)
      return [422, { error: "body must be an object {base, doc}" }] unless body.is_a?(Hash)

      base = body["base"]
      return [422, { error: "base (the revision id the editor loaded, null for none) is required" }] \
        unless body.key?("base") && (base.nil? || base.is_a?(Integer))

      DictationSettings.save!(db, doc: body["doc"], base: base, author: by, served: served(http))
      show(db: db, http: http)
    rescue DictationSettings::Conflict => e
      [409, { error: e.message }]
    rescue DictationSettings::Refused => e
      [422, { error: e.message }]
    end

    def models(body, db: Kanban.db, http: nil)
      return [422, { error: "body must be an object {url, token}" }] unless body.is_a?(Hash) && body.key?("url")

      doc = DictationSettings.with_token(db, body.slice("url", "token"))
      return [422, { error: "url is required" }] if doc["url"].to_s.strip.empty?

      DictationSettings.server!(doc)
      models, error = list(doc, http)
      [200, { models: models, models_error: error }]
    rescue DictationSettings::Refused => e
      [422, { error: e.message }]
    end

    def check(body, db: Kanban.db, http: nil, clock: -> { Busyyaks::Clock.monotonic })
      doc = body.is_a?(Hash) ? body["doc"] : nil
      doc = DictationSettings.with_token(db, doc.merge("enabled" => true)) if doc.is_a?(Hash)
      s = DictationSettings.settings!(doc)
      DictationSettings.served!(s, served(http))
      client = Dictation.client(s, http: http && http[:transcribe])
      t0 = clock.call
      out = client.transcribe(Dictation.silence)
      [200, out.merge(ms: ((clock.call - t0) * 1000).round)]
    rescue DictationSettings::Refused, Dictation::Invalid => e
      [422, { error: e.message }]
    rescue Dictation::Unavailable => e
      [502, { error: e.message }]
    end

    # a doc's server → [ids, nil] or [nil, why]
    def list(doc, http)
      url, token = DictationSettings.server!(doc)
      return [nil, "no url saved"] unless url

      [Dictation.models(url: url, token: token, timeout: MODELS_TIMEOUT, http: http && http[:models]), nil]
    rescue DictationSettings::Refused, Dictation::Invalid, Dictation::Unavailable => e
      [nil, e.message]
    end

    def served(http)
      ->(s) { Dictation.models(url: s.url, token: s.token, timeout: MODELS_TIMEOUT, http: http && http[:models]) }
    end
  end
end
