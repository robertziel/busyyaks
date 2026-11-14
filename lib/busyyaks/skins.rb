# frozen_string_literal: true

require "yaml"
require "json"

module Busyyaks
  # Skins (card #361): every skin is a FILE in this repo — `skins/<key>.yml` — the two built in (light.yml, the default,
  # and dark.yml) and any added next to them like any other code (by hand or by an agent), never at runtime. Chosen per
  # browser in the settings cog's Skin switch (public/static/skin.js; the choice stays this browser's localStorage).
  #
  # A skin file = {label, base, tokens}, its key the file name. `base` is light or dark: skin.js puts it on
  # <html data-skin>, so every rule written for that base (app.css's shadows and logos, the page stylesheets'
  # `[data-skin="dark"]` rules) applies, and data-skin-key=<key> beside it. light.yml / dark.yml are the bases: each
  # sets EVERY token of TOKENS (app.css's colour tokens). Any other skin sets some of them over its base's. Values are
  # only hex (#rgb, #rrggbb, #rrggbbaa) or rgb()/rgba() of plain numbers: the CSS is written into a <style> in every
  # page's <head> (css), so a value is never free text. The `--<name>-rgb` triple of a token in RGB_PAIRS (used for
  # tints) is derived from its colour (hex only), never set by hand. Read once per process and checked at boot
  # (config/app.rb): a bad file stops the boot with its reason.
  module Skins
    DIR = File.expand_path("../../skins", __dir__)
    # app.css's colour tokens, in its order: the ones a skin may set (test/unit/skins_test.rb: each is in both built-in
    # blocks of app.css, and app.css has no colour token missing here)
    TOKENS = %w[
      --bg --panel --panel-2 --surface-3 --line --line-strong --ink --ink-dim --ink-faint --track --row-rule --row-hover
      --mat-bar --mat-card --mat-fill --mat-fill-2 --mat-thumb
      --vivid-blue --vivid-green --vivid-orange --vivid-red --vivid-yellow --vivid-purple --vivid-teal --vivid-pink
      --button-fill --ok --warn --bad --accent
    ].freeze
    # a token whose "r, g, b" triple app.css also keeps (rgba() tints): written from the colour
    RGB_PAIRS = %w[--ok --warn --bad --accent].freeze
    BASES = %w[light dark].freeze
    # the choice skin.js has of its own (the system's light or dark): no skin's key
    RESERVED = %w[auto].freeze
    KEY = /\A[a-z][a-z0-9-]{0,31}\z/
    HEX = /\A#(?:\h{3}|\h{6}|\h{8})\z/
    RGBA = /\Argba?\(\d{1,3}, \d{1,3}, \d{1,3}(?:, (?:0|1|0?\.\d{1,3}))?\)\z/
    LABEL_MAX = 40
    LOCK = Mutex.new

    class Invalid < StandardError; end

    module_function

    # every skin file of DIR, validated: light, dark, then the others by key — read once per process (a new file needs
    # a restart, like code)
    def all
      LOCK.synchronize { @all ||= load(DIR) }
    end

    # the skins of `dir`: each `<key>.yml`; a file that is not a skin raises naming the file and the key. Anything in
    # the dir but *.yml and README.md is refused (a skins/<key>.yaml typo would otherwise never show).
    def load(dir)
      raise Invalid, "#{dir}: the skins directory is missing" unless File.directory?(dir)

      stray = Dir.children(dir).reject { _1.end_with?(".yml") || _1 == "README.md" }
      raise Invalid, "#{dir}: #{stray.sort.join(', ')} not a skin file (<key>.yml)" if stray.any?

      skins = Dir.glob(File.join(dir, "*.yml")).map do |path|
        where = "skins/#{File.basename(path)}"
        begin
          doc = YAML.safe_load_file(path)
        rescue Psych::Exception => e
          raise Invalid, "#{where}: not YAML (#{e.message})"
        end
        skin!(File.basename(path, ".yml"), doc, where)
      end
      bases!(skins)
      skins.sort_by { [BASES.index(_1["key"]) || BASES.size, _1["key"]] }.freeze
    end

    # light.yml and dark.yml: there, on their own base, every token set
    def bases!(skins)
      BASES.each do |b|
        s = skins.find { _1["key"] == b } or raise Invalid, "skins/#{b}.yml is missing: the #{b} base skin"
        raise Invalid, "skins/#{b}.yml: base must be #{b}" unless s["base"] == b

        missing = TOKENS - s["tokens"].keys
        raise Invalid, "skins/#{b}.yml: a base skin sets every token (missing: #{missing.join(' ')})" if missing.any?
      end
    end

    def skin!(key, s, where)
      raise Invalid, "#{where}: the file name must match #{KEY.source} (a-z, 0-9, -)" unless key.match?(KEY)
      raise Invalid, "#{where}: #{key} is reserved (#{RESERVED.join(', ')}: the system's skin)" if RESERVED.include?(key)
      raise Invalid, "#{where} must be a mapping {label, base, tokens}" unless s.is_a?(Hash)

      keys = %w[label base tokens]
      raise Invalid, "#{where} must have exactly #{keys.join(', ')} (has #{s.keys.join(', ')})" unless s.keys.sort == keys.sort

      label = s["label"]
      unless label.is_a?(String) && !label.strip.empty? && label.length <= LABEL_MAX && !label.match?(/[[:cntrl:]]/)
        raise Invalid, "#{where}: label must be 1-#{LABEL_MAX} characters, no control characters"
      end

      raise Invalid, "#{where}: base #{s['base'].inspect} is not one of #{BASES.join(', ')}" unless BASES.include?(s["base"])

      { "key" => key, "label" => label.strip, "base" => s["base"], "tokens" => tokens!(s["tokens"], where) }.freeze
    end

    def tokens!(t, where)
      raise Invalid, "#{where}: tokens must be a mapping {\"--token\": \"#hex\"}" unless t.is_a?(Hash)

      unknown = t.keys - TOKENS
      raise Invalid, "#{where}: #{unknown.join(', ')} not a skin token (known: #{TOKENS.join(' ')})" if unknown.any?

      bad = t.find { |_, v| !(v.is_a?(String) && (v.match?(HEX) || v.match?(RGBA))) }
      raise Invalid, "#{where}: #{bad[0]}: #{bad[1].inspect} is not a colour (#rgb, #rrggbb, #rrggbbaa, rgb(r, g, b), " \
                     "rgba(r, g, b, a))" if bad
      pair = RGB_PAIRS.find { t.key?(_1) && !t[_1].match?(HEX) }
      raise Invalid, "#{where}: #{pair} must be a hex colour (its #{pair}-rgb triple is derived from it)" if pair

      TOKENS.select { t.key?(_1) }.to_h { [_1, t[_1].downcase] }.freeze
    end

    # "#a8380a" / "#a83" / "#a8380aff" → "168, 56, 10"
    def rgb(hex)
      h = hex.delete_prefix("#")
      h = h.chars.map { _1 * 2 }.join if h.size == 3
      h[0, 6].scan(/../).map { _1.to_i(16) }.join(", ")
    end

    # The <style> for the skins, after app.css: a base skin's rule on :root[data-skin="<base>"] (on for every skin of
    # that base), then each other skin's on :root[data-skin-key="<key>"] — same specificity, later wins, so a skin's
    # tokens go over its base's. Every name and value passed KEY / TOKENS / HEX / RGBA: nothing here can close the rule
    # or the <style>.
    def css(skins)
      skins.map do |s|
        decls = s["tokens"].flat_map do |name, v|
          [*"#{name}: #{v};", *("#{name}-rgb: #{rgb(v)};" if RGB_PAIRS.include?(name))]
        end
        attr = BASES.include?(s["key"]) ? "data-skin" : "data-skin-key"
        ":root[#{attr}=\"#{s['key']}\"] { #{decls.join(' ')} }"
      end.join("\n")
    end

    # what skin.js reads from <meta name="skins">: [{key, label, base}] (the page escapes it into the attribute)
    def meta(skins) = JSON.generate(skins.map { _1.slice("key", "label", "base") })
  end
end
