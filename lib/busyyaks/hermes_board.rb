# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"
require "yaml"

module Busyyaks
  # What makes a Hermes session a board agent, per launch and never in the operator's own Hermes config: an
  # overlay file in the session's stage, handed through HERMES_MANAGED_DIR — queue mode (a line typed mid-turn waits for
  # the turn), the busyyaks MCP server (its token in that 0600 file, never on argv or in a log), MCP tools listed
  # directly, the language + skin the screen rules were captured on. After the start, Hermes itself is asked (`hermes
  # config get`, the allowlisted command with this launch's environment) whether each setting holds; not proven → the
  # launch is refused.
  # Pure Ruby + stdlib: bin/launcher (host) requires this file alone.
  module HermesBoard
    class Invalid < StandardError; end

    DIR = "hermes-managed"
    # Hermes starts MCP discovery only when the USER's config.yaml has an mcp_servers entry (mcp_startup.py reads the
    # raw file): this line turns it on and connects an ordinary session to nothing.
    INERT = "mcp_servers: {busyyaks: {enabled: false}}"
    # key → the value `hermes config get` must print
    PINNED = { "display.busy_input_mode" => "queue", "display.language" => "en", "display.skin" => "default",
               "tools.tool_search.enabled" => "false", "mcp_servers.busyyaks.enabled" => "true",
               "paste_collapse_char_threshold" => "1", }.freeze
    # A modal takes the next Enter as its answer. Each draws one of these hints right above the composer (locales/en.yaml
    # cli.tui.hint_*: sudo · secret · approval · slash confirm · connection · vault · clarify) and, on an empty composer,
    # its own prompt glyph (a composer holding several lines draws no prompt, so the hint is the one that always shows).
    MODAL_HINT = Regexp.union(/Enter to (?:skip|confirm|lock|continue|open in browser)/, "Enter for next field", "press Enter",
                              "input temporarily disabled", "connection setup", "waiting for the backend")
    MODAL_PROMPT = /\A(?:⚠|\?|✎|🔐|🔑|⚙)/
    HINT_ROWS = 4 # the rows above the composer's top rule: the hint, the status bar, a queue line
    RULE = /\A─{20,}/

    module_function

    def mcp!(env)
      host, port, token = %w[MCP_HOST MCP_HOST_PORT MCP_TOKEN].map do |k|
        env.fetch(k) { raise Invalid, "#{k} missing in .env (a Hermes board session needs the busyyaks MCP)" }
      end
      raise Invalid, "MCP_TOKEN is empty in .env" if token.empty?

      { url: "http://#{host}:#{port}/mcp", token: token }
    end

    # Writes <stage>/hermes-managed/config.yaml (dir 0700, file 0600) → the dir
    def stage!(stage, mcp)
      dir = File.join(stage, DIR)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.chmod(0o700, dir)
      doc = { "display" => { "busy_input_mode" => "queue", "language" => "en", "skin" => "default" },
              "tools" => { "tool_search" => { "enabled" => false } },
              # every paste becomes one `[Pasted text #N: L lines → <file>]`, so what a ping left in the input is read
              # back byte for byte (input_state), whatever its length or line breaks
              "paste_collapse_char_threshold" => 1,
              # Hermes records these one-time tips in the USER's config.yaml once shown: marked seen here, so a board
              # session never writes that file (measured: scripts/harness-lab/board-e2e)
              "onboarding" => { "seen" => { "busy_input_prompt" => true, "tool_progress_prompt" => true } },
              "mcp_servers" => { "busyyaks" => { "enabled" => true, "url" => mcp[:url],
                                                 "headers" => { "Authorization" => "Bearer #{mcp[:token]}" }, } }, }
      File.open(File.join(dir, "config.yaml"), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(YAML.dump(doc)) }
      dir
    end

    # HERMES_LANGUAGE: Hermes reads it before display.language
    def env(dir) = { "HERMES_MANAGED_DIR" => dir, "HERMES_LANGUAGE" => "en" }

    # nil when the started session has the overlay, else why. user_config: the text of the operator's config.yaml (read
    # only), nil when unreadable. get: key → what `hermes config get` printed, nil when it failed.
    def refusal(path:, user_config:, url:, get:)
      return "cannot read #{path}: it needs the line `#{INERT}`" if user_config.nil?

      servers = begin
        doc = YAML.safe_load(user_config, aliases: true)
        doc.is_a?(Hash) ? doc["mcp_servers"] : nil
      rescue Psych::Exception => e
        return "#{path} is not valid YAML (#{e.class})"
      end
      unless servers.is_a?(Hash) && servers.any?
        return "#{path} has no mcp_servers, so Hermes skips MCP discovery: add the line `#{INERT}` " \
               "(inert: an ordinary session connects to nothing)"
      end

      PINNED.merge("mcp_servers.busyyaks.url" => url).each do |key, want|
        got = get.call(key)
        return "hermes config get #{key} failed" if got.nil?
        return "hermes runs with #{key} = #{got.inspect}, not #{want.inspect}: its overlay is not in effect" if got != want
      end
      nil
    end

    # The composer: between the screen's last two rules. nil when a line may be typed now, else why.
    def paste_refusal(screen)
      lines = screen.to_s.delete("\r").lines.map(&:rstrip)
      lines.pop while lines.last&.empty?
      low = lines.rindex { |l| l.match?(RULE) }
      high = low && (low - 1).downto(0).find { |i| lines[i].match?(RULE) }
      return "its input row is not on the screen" unless high && low - high >= 2

      hint = lines[[high - HINT_ROWS, 0].max...high].find { |l| l.match?(MODAL_HINT) }
      return "a prompt is waiting on its screen (#{hint.strip[0, 40]})" if hint
      return "its input row is asking for something" if lines[high + 1].match?(MODAL_PROMPT)

      nil
    end

    # ── what the composer holds, from the pane's styled capture (`capture-pane -e`) ──
    # Hermes draws its hint in the empty input in ITALICS ("Research this topic…", "msg=interrupt · …"); typed text is
    # never italic (test/fixtures/screens/hermes_input_*.ansi). tmux carries a style across rows, so it is tracked from
    # the top of the screen.
    SGR = /\e\[([0-9;:]*)m/
    PROMPT = /\A(?:☤\s+)?❯\s?|\A☤\s?/
    PASTE_REF = /\A\[Pasted text #\d+: \d+ lines → (?<path>.+)\]\z/
    PASTE_FILE = %r{/pastes/paste_\d+_\d+\.txt\z}
    PASTE_MAX_BYTES = 256 * 1024

    def plain(ansi) = ansi.to_s.gsub(SGR, "")

    # → {state: :empty} · {state: :text, text:} (rows joined: a wrap is no character) · {state: :unreadable, why:}
    def input(ansi)
      rows = ansi.to_s.delete("\r").lines.map(&:chomp)
      flat = rows.map { |r| plain(r).rstrip }
      flat.pop while flat.last&.empty?
      low = flat.rindex { |l| l.match?(RULE) }
      high = low && (low - 1).downto(0).find { |i| flat[i].match?(RULE) }
      return { state: :unreadable, why: "its input row is not on the screen" } unless high && low - high >= 2

      italic = false
      typed = rows[0...low].each_with_index.filter_map do |row, i|
        text, italic = upright(row, italic)
        text if i > high
      end
      # (a running turn draws its prompt in italics too, so the prompt is checked on the plain row)
      drawn = flat[high + 1]
      return { state: :unreadable, why: "its input row has no prompt" } unless drawn.match?(PROMPT) || drawn.strip.empty?

      body = [typed.first.to_s.sub(PROMPT, ""), *typed.drop(1).map(&:lstrip)].map(&:rstrip).join
      body.strip.empty? ? { state: :empty } : { state: :text, text: body }
    end

    # one row's characters drawn upright → [text, italic at its end]
    def upright(row, italic)
      out = +""
      at = 0
      loop do
        m = row.match(SGR, at) or break
        out << row[at...m.begin(0)] unless italic
        italic = italic_after(m[1], italic)
        at = m.end(0)
      end
      out << row[at..] unless italic
      [out, italic]
    end

    # an SGR's parameters, a colour's own numbers (38;5;n · 38;2;r;g;b) skipped
    def italic_after(code, italic)
      params = code.empty? ? [0] : code.split(/[;:]/).map(&:to_i)
      until params.empty?
        n = params.shift
        case n
        when 38, 48, 58 then params.shift(params.first == 5 ? 2 : 4)
        when 0, 23 then italic = false
        when 3 then italic = true
        end
      end
      italic
    end

    # What the input holds relative to this ping → {state: :empty | :ours | :other | :unreadable, why:}. Ours = the
    # placeholder of a paste whose file holds exactly this text. Never says what a person typed, only how long it is.
    def input_state(ansi, ping)
      now = input(ansi)
      return now unless now[:state] == :text

      ref = now[:text].match(PASTE_REF)
      return { state: :other, why: "typed text (#{now[:text].length} chars)" } unless ref

      held = paste_file(ref[:path])
      return { state: :unreadable, why: "the file of its pasted block cannot be read" } if held.nil?

      held.strip == ping.strip ? { state: :ours } : { state: :other, why: "a pasted block that is not this ping" }
    end

    def paste_file(path)
      return nil unless path.start_with?("/") && path.match?(PASTE_FILE) && File.file?(path) && !File.symlink?(path)
      return nil if File.size(path) > PASTE_MAX_BYTES

      File.read(path, encoding: "UTF-8").delete_prefix("\uFEFF")
    rescue SystemCallError
      nil
    end

    # Which running Hermes processes busyyaks launched with the overlay: {session, pid, start_ticks}, in the launcher's
    # own state dir. The pid + its start time prove it is still THAT process.
    class Records
      def initialize(dir)
        @file = File.join(dir, "hermes-board.json")
        @dir = dir
        @lock = Mutex.new
        @lock.synchronize { read } # a corrupt file stops the start
      end

      def record(session:, pid:, start_ticks:, alive:)
        @lock.synchronize do
          keep = read.reject { |e| e["session"] == session || !alive.call(e["session"]) }
          write(keep + [{ "session" => session, "pid" => pid, "start_ticks" => start_ticks }])
        end
      end

      # {pid, start_ticks} when `pid` with that start time is the recorded process of `session`, else nil
      def proof(session, pid, start_ticks)
        e = @lock.synchronize { read.find { |x| x["session"] == session } }
        return nil unless e && e["pid"] == pid && e["start_ticks"] == start_ticks

        { "pid" => pid, "start_ticks" => start_ticks }
      end

      private

      def read
        return [] unless File.exist?(@file)

        list = JSON.parse(File.read(@file))
        valid = list.is_a?(Array) && list.all? { |e| e.is_a?(Hash) && e.keys.sort == %w[pid session start_ticks] }
        raise Invalid, "#{@file}: not a list of Hermes board records" unless valid

        list
      rescue JSON::ParserError => e
        raise Invalid, "#{@file}: #{e.message}"
      end

      def write(list)
        f = Tempfile.create(["hermes-board", ".json.tmp"], @dir)
        begin
          f.write(JSON.generate(list))
          f.close
          File.rename(f.path, @file)
        ensure
          f.close unless f.closed?
          FileUtils.rm_f(f.path)
        end
      end
    end
  end
end
