# frozen_string_literal: true

require "json"
require "monitor"
require_relative "clock"
require_relative "dictation"

module Busyyaks
  # What the card dialog's mic runs (card 634): on or off, the speech server (its URL + bearer token), the model, the
  # timeout and the longest recording — once config/busyyaks.yml `dictation` + .env DICTATION_URL / DICTATION_TOKEN,
  # now revisions in the DATABASE (table dictation_settings: the newest row is the current one, every earlier one
  # kept), edited on Settings → Dictation or with bin/dictation-settings.
  #
  # A revision is exactly KEYS: `enabled` true/false, `url` (the server's base or full endpoint; "" only while off),
  # `token` (its bearer; "" = none sent) + the three Dictation.parse! checks (model, timeout_seconds, max_seconds),
  # kept while off so turning it back on keeps them. The token is write-only: no answer carries it (redact). A save
  # that turns or keeps it ON is checked against the server itself (`served`: the ids its GET /v1/models lists): a
  # model the server does not serve is refused, a server that cannot be read refuses the save with its reason —
  # never saved on a guess. Nothing is seeded: no revision = off (the mic is hidden, POST /api/dictation 404 saying so).
  module DictationSettings
    TABLE = :dictation_settings
    KEYS = %w[enabled url token model timeout_seconds max_seconds].freeze

    class Error < StandardError; end
    class Conflict < Error; end # base is not the newest revision: reload, then save again
    class Refused < Error; end  # the document, or the model against the server

    module_function

    # a revision's document → Dictation::Settings (url + token resolved) when enabled, nil when off; Refused naming
    # what is wrong
    def settings!(doc)
      raise Refused, "dictation settings must be an object {#{KEYS.join(', ')}}" unless doc.is_a?(Hash)

      missing = KEYS - doc.keys
      raise Refused, "missing #{missing.join(', ')}" if missing.any?

      unknown = doc.keys - KEYS
      raise Refused, "unknown #{unknown.join(', ')} (known: #{KEYS.join(', ')})" if unknown.any?
      raise Refused, "enabled must be true or false" unless [true, false].include?(doc["enabled"])

      url, token = server!(doc)
      raise Refused, "url is required while the mic is on (the speech server's base or endpoint)" if doc["enabled"] && !url

      s = Dictation.parse!(doc.slice(*Dictation::KEYS))
      return nil unless doc["enabled"]

      s.url = url
      s.token = token
      s
    rescue Dictation::Invalid => e
      raise Refused, e.message
    end

    # doc's url + token → [endpoint URI or nil (url ""), token or nil]
    def server!(doc)
      %w[url token].each { |k| raise Refused, "#{k} must be a string" unless doc[k].is_a?(String) }
      raise Refused, "token is set but url is empty" if doc["url"].strip.empty? && !doc["token"].empty?

      [doc["url"].strip.empty? ? nil : Dictation.endpoint!(doc["url"]), Dictation.token!(doc["token"])]
    rescue Dictation::Invalid => e
      raise Refused, e.message
    end

    # An editor's doc → the doc to store or try: `token` null = keep the current revision's — only while the url is
    # the current revision's (a changed url never gets the old bearer: type its token, or "" for none).
    def with_token(db, doc)
      return doc unless doc.is_a?(Hash) && doc.key?("token") && doc["token"].nil?

      cur = current(db)&.fetch(:doc)
      unless cur && cur["url"] == doc["url"]
        raise Refused, "token: the url is not the saved one (#{cur ? cur['url'].inspect : 'none saved'}): " \
                       "type its token, or leave it empty for none"
      end

      doc.merge("token" => cur["token"])
    end

    # a stored doc as an answer carries it: the token replaced by whether one is set + its last 4 characters
    def redact(doc)
      return nil unless doc

      t = doc["token"].to_s
      doc.merge("token" => nil, "token_set" => !t.empty?, "token_hint" => t.length >= 12 ? "…#{t[-4..]}" : nil)
    end

    def current(db)
      row = db[TABLE].reverse(:id).first
      row && { id: row[:id], doc: JSON.parse(row[:doc]), author: row[:author], at: row[:created_at] }
    end

    def current_id(db) = db[TABLE].max(:id)

    # What the mic runs now: Dictation::Settings, or nil (no revision, or the newest is off). One MAX(id) per call,
    # the parse kept per revision.
    MEMO = Monitor.new
    def get(db)
      id = current_id(db) or return nil
      MEMO.synchronize do
        return @memo[1] if @memo && @memo[0] == id

        @memo = [id, settings!(current(db)[:doc])]
        @memo[1]
      end
    end

    def history(db, limit: 20)
      db[TABLE].reverse(:id).limit(limit).select(:id, :author, :created_at).all
               .map { |r| { id: r[:id], author: r[:author], at: r[:created_at] } }
    end

    def revisions(db) = db[TABLE].count

    # The settings' model against what their server serves: `served`.(settings) → the model ids (it raises
    # Dictation::Unavailable / Invalid when the server cannot be asked) — both are a refusal here.
    def served!(settings, served)
      ids = served.call(settings)
      return if ids.include?(settings.model)

      raise Refused, "the speech server does not serve #{settings.model.inspect} (it serves: #{ids.join(', ')})"
    rescue Dictation::Unavailable, Dictation::Invalid => e
      raise Refused, "the model cannot be checked: #{e.message}"
    end

    # A new revision from `doc` (token null = the current one's, with_token), based on revision `base` (the one the
    # editor loaded; nil = none existed): validated,
    # an enabled one's model served, `base` still the newest → the new revision's id.
    def save!(db, doc:, base:, author:, served:, clock: -> { Busyyaks::Clock.epoch })
      doc = with_token(db, doc)
      s = settings!(doc)
      raise Refused, "author is required" if author.to_s.empty?

      served!(s, served) if s
      db.transaction do
        now = current_id(db)
        raise Conflict, "revision #{base.inspect} is not the newest (#{now.inspect} is): reload, then save again" \
          unless now == base

        db[TABLE].insert(doc: JSON.generate(doc.slice(*KEYS)), author: author.to_s, created_at: clock.call)
      end
    end

    # the old config/busyyaks.yml block (+ the server, bin/dictation-settings import) → a document: `none` = off with
    # nothing to keep is refused (nothing to import: off is no revision), a mapping = on; its `url` / `token` (once
    # .env DICTATION_URL / DICTATION_TOKEN) are required beside the block (token "" = none)
    def from_config_block(value)
      raise Refused, "the old block is `none`: nothing to import (no revision = off)" if value == "none"
      unless value.is_a?(Hash) && value.keys.sort == (Dictation::KEYS + %w[url token]).sort
        raise Refused, "the old block must be a mapping {#{Dictation::KEYS.join(', ')}} plus url and token " \
                       "(the old .env DICTATION_URL / DICTATION_TOKEN)"
      end

      { "enabled" => true }.merge(value)
    end
  end
end
