# frozen_string_literal: true

require "find"

module Busyyaks
  # Finds a repo's own icon (favicon / app icon) on disk. Walks at most DEPTH levels and MAX_ENTRIES entries,
  # skipping dependency/build trees, then ranks candidates: where it lives (public/, static/, app assets beat
  # docs/, worklog/, tests), what it is (favicon.svg > large PNG > apple-touch-icon > .ico > icon/logo), size.
  # No icon file in the repo → nil; the UI draws a visible monogram placeholder, never a borrowed icon.
  module Icons
    DEPTH = 4
    MAX_ENTRIES = 20_000
    MAX_BYTES = 512 * 1024
    PRUNE = %w[node_modules .git vendor venv .venv dist build tmp coverage site-packages __pycache__ .next .nuxt target
               bundle .bundle Pods DerivedData .gradle .cache log logs].to_set
    SIZE = '(?:[-_.]?\d+(?:x\d+)?)?' # favicon-32x32, apple-touch-icon.180, …
    NAME = /\A(favicon#{SIZE}|apple-touch-icon#{SIZE}|icon|app-icon|logo|mark)\.(svg|png|ico)\z/i
    GOOD_DIR = %r{(?:\A|/)(public|static|assets|images|img|icons|app)(?:/|\z)}i
    BAD_DIRS = 'docs?|worklog|previews?|tests?|spec|fixtures?|examples?|handoff|export|samples?|screenshots?|third[_-]?party|' \
               'node_modules'
    BAD_DIR = %r{(?:\A|/)(#{BAD_DIRS})(?:/|\z)}i
    TYPES = { "svg" => "image/svg+xml", "png" => "image/png", "ico" => "image/x-icon" }.freeze

    module_function

    # → [relative_path, mtime] or nil
    def find(repo)
      best = nil
      seen = 0
      Find.find(repo) do |path|
        seen += 1
        break if seen > MAX_ENTRIES

        rel = path.delete_prefix("#{repo}/")
        if File.directory?(path)
          next if path == repo

          Find.prune if PRUNE.include?(File.basename(path)) || rel.count("/") >= DEPTH - 1
          next
        end
        next unless File.basename(path).match?(NAME)

        st = File.stat(path)
        next if st.size.zero? || st.size > MAX_BYTES

        s = score(rel, st.size, png_width(path))
        best = [s, rel, st.mtime.to_i] if best.nil? || s > best[0]
      end
      best && best[1..]
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    # A PNG's pixel width from its IHDR chunk (bytes 16..19, big-endian); nil when it is not a PNG.
    def png_width(path)
      head = File.binread(path, 24)
      head&.start_with?("\x89PNG\r\n\x1A\n".b) ? head[16, 4].unpack1("N") : nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def score(rel, size, width = nil)
      base = File.basename(rel).downcase
      ext = File.extname(base).delete(".")
      s = 0
      s += 40 if base.start_with?("favicon")
      s += 25 if base.start_with?("apple-touch-icon")
      s += 15 if base.match?(/\A(icon|app-icon)\./)
      s += 5 if base.match?(/\A(logo|mark)\./)
      s += { "svg" => 30, "png" => 20, "ico" => 10 }.fetch(ext, 0)
      if ext == "png" && width # pixel size decides among PNGs: a 16 px favicon is mush on a 2x screen
        s += if width < 32 then -30
             elsif width < 64 then -5
             else 15
             end
      elsif ext == "png"
        s += [Math.log2([size, 1].max).floor - 8, 8].min
      end
      dir = File.dirname(rel)
      s += 20 if dir.match?(GOOD_DIR)
      s -= 60 if dir.match?(BAD_DIR)
      s - (rel.count("/") * 3) # shallower wins ties
    end

    def type(rel) = TYPES.fetch(File.extname(rel).delete(".").downcase)
  end
end
