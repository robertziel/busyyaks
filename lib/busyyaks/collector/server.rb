# frozen_string_literal: true

require "json"
require "socket"
require "io/wait"
require "time"
require_relative "../clock"
require_relative "../agent_collector"

module Busyyaks
  module Collector
    # bin/collector's read socket: one JSON line in, one JSON line out, owner-only (Busyyaks::PrivateSocket, in a 0700
    # dir). The ops bin/launcher sends:
    #   {"op":"screen","session","socket"}             → {ok, text, engine, dialog} — dialog = the parser's slice
    #                                                     {question, command, options, escape, free_text, hash} or null
    #                                                     (no `kind`: bin/launcher names it "question")
    #   {"op":"send","session","socket","text","submit"?} → {ok} — the text pasted into the agent's pane, then Enter
    #   {"op":"tasks","session","socket"}              → refused: this collector reads no subagents / tasks
    #   {"op":"ping"}                                  → {ok, collector: "busyyaks"} (`yaks doctor`: the socket answers)
    # The pane is never taken from the request: the session names it, the LAST snapshot gives its agent pane, or nothing.
    # Errors: {ok: false, error: {type, message}} (type tmux = nothing typed, worth a retry; type unconfirmed = a send
    # whose paste had started when tmux failed: the text may be on the screen, never sent again).
    class Server
      REQUEST_MAX = 64 * 1024
      READ_SECONDS = 15
      TEXT_MAX = 16_000
      SCREEN_MAX = 512 * 1024
      PASTE_SETTLE_S = 0.25
      # every C0 / C1 control character but tab and newline: a text cannot carry escape sequences, or the paste's own end
      # marker, into the terminal
      CONTROL = /[\x00-\x08\x0b-\x1f\x7f\u0080-\u009f]/
      SESSION = /\A[^\x00-\x1f]{1,200}\z/
      READ_BACK_POLLS = 8 # further reads of the input after our own paste, READ_BACK_STEP_S apart (about a second in all)
      READ_BACK_STEP_S = 0.1
      STYLE = /\e\[[0-9;:]*m/ # the colours of a `capture-pane -e`
      TASKS = "busyyaks's collector reads no subagents, workflows or background tasks"

      # dialog: the dialog parser (AgentsKanban::SessionDialog.parse — the one bin/launcher uses); typeable: engine
      # family → may a message be typed into it unconditionally (Claude Code); proven: (family, session, pid, start ticks)
      # → bin/launcher's own record says THAT process runs in queue mode (Hermes; read here, never taken from a request);
      # paste_refusal: (family, screen) → why a line may not be typed now; input_state: (family, styled screen, text) → what
      # its input holds (HermesBoard.input_state), nil = this family's input is not read
      def initialize(latest:, procfs:, tmux:, dialog:, typeable:, proven:, paste_refusal:, input_state:, reads_input:,
                     log: ->(m) { puts m }, pause: ->(s) { sleep s })
        @latest = latest
        @procfs = procfs
        @tmux = tmux
        @dialog = dialog
        @typeable = typeable
        @proven = proven
        @paste_refusal = paste_refusal
        @input_state = input_state
        @reads_input = reads_input
        @log = log
        @pause = pause
        @input = Mutex.new # one keystroke stream at a time
      end

      def handle(req)
        return err("invalid_request", "not a JSON object") unless req.is_a?(Hash)

        case req["op"]
        when "ping" then { ok: true, collector: "busyyaks" }
        when "screen" then with_target(req) { |t| screen(t) }
        when "send" then with_target(req) { |t| send_text(t, req) }
        when "tasks" then err("unsupported", TASKS)
        else err("invalid_request", "unknown op")
        end
      rescue StandardError => e
        err("internal", e.class.name)
      end

      # one connection: one line (at most REQUEST_MAX), the WHOLE line within READ_SECONDS, one answer
      def serve(conn)
        conn.write("#{JSON.generate(answer(conn))}\n")
      rescue IOError, SystemCallError
        nil
      ensure
        conn.close
      end

      private

      def answer(conn)
        line = AgentCollector.read_line(conn, READ_SECONDS, max: REQUEST_MAX)
        return err("invalid_request", "no request") if line.nil?

        handle(JSON.parse(line))
      rescue AgentCollector::Slow
        err("invalid_request", "no whole request line within #{READ_SECONDS}s")
      rescue AgentCollector::TooLarge
        err("invalid_request", "request too large")
      rescue JSON::ParserError
        err("invalid_request", "not JSON")
      end

      def err(type, message) = { ok: false, error: { type: type, message: message } }

      def with_target(req)
        name = req["session"]
        sock = req["socket"] || "default"
        return err("invalid_request", "bad session") unless name.is_a?(String) && name.match?(SESSION)
        return err("invalid_request", "bad socket") unless sock.is_a?(String) && sock.match?(Tmux::LABEL)

        t = @latest.lookup(name, sock) or return err("no_session", "not an agent session in the last snapshot")
        yield t
      end

      def capture(t)
        out, e, ok = @tmux.run(t.socket, "capture-pane", "-p", "-t", t.pane_id)
        raise TmuxFailed, e.strip[0, 200] unless ok

        out
      end

      class TmuxFailed < StandardError; end
      class Unconfirmed < StandardError; end

      def screen(t)
        text = capture(t)
        # the last SCREEN_MAX BYTES (the limit is bytes): a character cut in half at the start is dropped
        text = text.byteslice(-SCREEN_MAX, SCREEN_MAX).scrub("") if text.bytesize > SCREEN_MAX
        { ok: true, text: text, engine: t.family.name, dialog: @dialog.call(text) }
      rescue TmuxFailed => e
        err("tmux", e.message)
      end

      # The agent the snapshot named for that pane must STILL run there (its comm, the same start time): a snapshot is up
      # to one interval old, and a pane whose agent exited is a shell — a "message" typed there would be a command.
      def alive?(t)
        p = @procfs.stat(t.pid)
        !p.nil? && p.comm == t.family.comm && p.start_ticks == t.start_ticks
      end

      def clean(text)
        return nil unless text.is_a?(String) && text.valid_encoding?

        t = text.gsub("\r\n", "\n").tr("\r", "\n").gsub(CONTROL, "")
        t.strip.empty? || t.length > TEXT_MAX ? nil : t
      end

      def send_text(t, req)
        text = clean(req["text"]) or return err("invalid_request", "text must be 1..#{TEXT_MAX} characters")
        unless @typeable.call(t.family.name) || @proven.call(t.family.name, t.name, t.pid, t.start_ticks)
          return err("unsupported", "a message is not typed into #{t.family.name}")
        end

        @input.synchronize do
          return err("no_session", "the agent is no longer running in that pane") unless alive?(t)

          @reads_input.call(t.family.name) ? send_checked(t, text, req) : send_plain(t, text, req)
        end
      rescue TmuxFailed => e
        err("tmux", e.message)
      rescue Unconfirmed => e
        err("unconfirmed", "the paste failed and may have been typed in part: #{e.message}")
      end

      def send_plain(t, text, req)
        return err("dialog", "a dialog is on its screen: a paste would answer it") if @dialog.call(capture(t))

        paste(t, text)
        return sent(t, text) if req["submit"] == false

        @pause.call(PASTE_SETTLE_S) # the paste lands before the Enter
        enter_after_paste(t, text)
      end

      # No memory between sends: the input on the screen decides, every time. Empty → paste. This very ping (a dialog
      # stopped its Enter, even before a restart) → Enter only. Anything else → nothing typed: never glued to it.
      def send_checked(t, text, req)
        ansi = capture_styled(t)
        why = blocked(t, ansi.gsub(STYLE, ""))
        return err("dialog", why) if why

        now = @input_state.call(t.family.name, ansi, text)
        case now[:state]
        when :ours then enter_after_paste(t, text) # its paste is on the screen: a failed Enter is never retried
        when :empty then paste_and_enter(t, text, req)
        else refused(now)
        end
      end

      # After our own paste the input must show THIS ping before Enter. It may render late, so it is read for about a
      # second. Never seen → `paste_unconfirmed`, which is not retried: an input that still looks empty cannot be told
      # from a paste not drawn yet, and a retry would paste a second copy.
      def paste_and_enter(t, text, req)
        paste(t, text)
        return sent(t, text) if req["submit"] == false

        @pause.call(PASTE_SETTLE_S) # the paste lands before the Enter
        begin
          read_back_and_enter(t, text)
        rescue TmuxFailed => e
          # the line is in (or on its way into) the input: a retry could find it not drawn yet and paste a second copy
          err("unconfirmed", "pasted, then its input could not be read back: #{e.message}")
        end
      end

      def read_back_and_enter(t, text)
        seen = nil
        (READ_BACK_POLLS + 1).times do |i|
          @pause.call(READ_BACK_STEP_S) if i.positive?
          ansi = capture_styled(t)
          screen = ansi.gsub(STYLE, "")
          # a dialog that opened meanwhile would take the Enter as its answer (Hermes: "Allow once" is preselected)
          return err("dialog", "a dialog is on its screen (the line waits in its input)") if @dialog.call(screen)

          seen = @input_state.call(t.family.name, ansi, text)
          next if seen[:state] == :unreadable # a repaint

          why = @paste_refusal.call(t.family.name, screen)
          return err("dialog", "#{why} (the line waits in its input)") if why
          next if seen[:state] == :empty # not drawn yet

          return after_paste(t, text, seen)
        end
        shows = seen[:state] == :empty ? "nothing" : seen[:why]
        err("paste_unconfirmed", "the line was pasted but its input still shows #{shows}: Enter not pressed, not pasted again")
      end

      def after_paste(t, text, seen)
        unless seen[:state] == :ours
          return err("input_busy", "the line was pasted, but its input now holds #{seen[:why]}: Enter not pressed")
        end

        enter_after_paste(t, text)
      end

      # Enter on a line of ours in the input (pasted just now, or by an earlier send of this ping): a failed Enter may still
      # have landed, and a retry would then find an empty input and paste a second copy — so it is unconfirmed, never sent
      # again
      def enter_after_paste(t, text)
        enter(t)
        sent(t, text)
      rescue TmuxFailed => e
        err("unconfirmed", "pasted, then the Enter failed: #{e.message}")
      end

      def refused(now)
        return err("input_unreadable", "its input cannot be read: #{now[:why]}: nothing typed") if now[:state] == :unreadable

        err("input_busy", "its input holds #{now[:why]}: nothing typed until it is sent or cleared")
      end

      def capture_styled(t)
        out, e, ok = @tmux.run(t.socket, "capture-pane", "-e", "-p", "-t", t.pane_id)
        raise TmuxFailed, e.strip[0, 200] unless ok

        out
      end

      def enter(t)
        _o, e, ok = @tmux.run(t.socket, "send-keys", "-t", t.pane_id, "Enter")
        raise TmuxFailed, e.strip[0, 200] unless ok
      end

      def sent(t, text)
        @log.call("#{Clock.now.iso8601} send #{text.length} chars → #{t.name} (#{t.pane_id})") # never the text
        { ok: true }
      end

      def blocked(t, screen)
        return "a dialog is on its screen: a paste would answer it" if @dialog.call(screen)

        @paste_refusal.call(t.family.name, screen)
      end

      # one bracketed paste (a multi-line text arrives as ONE paste, never a series of Enters): the text through stdin into
      # a named buffer, pasted and deleted — never an argument tmux could read as its own
      def paste(t, text)
        buf = "busyyaks-collector-#{Process.pid}-#{Thread.current.object_id}"
        _o, e, ok = @tmux.run(t.socket, "load-buffer", "-b", buf, "-", stdin: text)
        raise TmuxFailed, e.strip[0, 200] unless ok # nothing typed yet

        _o, e, ok = @tmux.run(t.socket, "paste-buffer", "-p", "-d", "-b", buf, "-t", t.pane_id)
        raise Unconfirmed, e.strip[0, 200] unless ok # tmux may have pasted part of it before failing
      end
    end
  end
end
