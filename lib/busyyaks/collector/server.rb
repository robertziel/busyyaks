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
    # Errors: {ok: false, error: {type, message}} (type tmux = worth a retry).
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
      TASKS = "busyyaks's collector reads no subagents, workflows or background tasks"

      # dialog: the dialog parser (AgentsKanban::SessionDialog.parse — the one bin/launcher uses); typeable: engine
      # family → may a message be typed into it (Busyyaks::Engines's families: Claude Code yes, Hermes no)
      def initialize(latest:, procfs:, tmux:, dialog:, typeable:, log: ->(m) { puts m }, pause: ->(s) { sleep s })
        @latest = latest
        @procfs = procfs
        @tmux = tmux
        @dialog = dialog
        @typeable = typeable
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
        return err("unsupported", "a message is not typed into #{t.family.name}") unless @typeable.call(t.family.name)

        @input.synchronize do
          return err("no_session", "the agent is no longer running in that pane") unless alive?(t)
          return err("dialog", "a dialog is on its screen: a paste would answer it") if @dialog.call(capture(t))

          paste(t, text)
          unless req["submit"] == false
            @pause.call(PASTE_SETTLE_S) # the paste lands before the Enter
            _o, e, ok = @tmux.run(t.socket, "send-keys", "-t", t.pane_id, "Enter")
            raise TmuxFailed, e.strip[0, 200] unless ok
          end
          @log.call("#{Clock.now.iso8601} send #{text.length} chars → #{t.name} (#{t.pane_id})") # never the text
          { ok: true }
        end
      rescue TmuxFailed => e
        err("tmux", e.message)
      end

      # one bracketed paste (a multi-line text arrives as ONE paste, never a series of Enters): the text through stdin into
      # a named buffer, pasted and deleted — never an argument tmux could read as its own
      def paste(t, text)
        buf = "busyyaks-collector-#{Process.pid}-#{Thread.current.object_id}"
        [["load-buffer", "-b", buf, "-"], ["paste-buffer", "-p", "-d", "-b", buf, "-t", t.pane_id]].each_with_index do |args, i|
          _o, e, ok = @tmux.run(t.socket, *args, stdin: i.zero? ? text : nil)
          raise TmuxFailed, e.strip[0, 200] unless ok
        end
      end
    end
  end
end
