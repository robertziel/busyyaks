# frozen_string_literal: true

module Busyyaks
  module Collector
    # The tmux servers bin/collector reads: only THIS uid's, the sockets in tmux's own socket dir
    # ($TMUX_TMPDIR or /tmp, then tmux-<uid>) that are sockets owned by this uid (never a symlink). Every call is an argv
    # array (no shell) through `runner` — bin/collector's (Open3, TMUX / TMUX_PANE cleared: a collector started from
    # inside a pane must not act relative to it); this file spawns nothing (test/unit/no_git_spawn_test.rb). Every call
    # has a deadline (config/busyyaks.yml agents.collector.tmux_timeout_seconds, no default): the runner kills a tmux
    # still running at it and answers timed_out(seconds) — that request's error, never a hang.
    class Tmux
      # session_name LAST: the one free-text field (spaces allowed); a line splits on the first N-1 spaces
      FIELDS = %w[pane_pid pane_id window_index pane_index session_attached session_created session_activity
                  window_activity session_windows session_name].freeze
      INTS = FIELDS - %w[pane_id session_name]
      FORMAT = FIELDS.map { |f| "\#{#{f}}" }.join(" ")
      # what tmux says when a socket has no server behind it: zero sessions, not an error
      DEAD = ["no server running", "error connecting", "No such file or directory", "Connection refused"].freeze
      NOT_RUNNABLE = "tmux is not installed (or not on PATH)"
      def self.timed_out(seconds) = "tmux did not answer within #{seconds}s (agents.collector.tmux_timeout_seconds): killed"
      LABEL = /\A[\w.-]{1,64}\z/
      PANE = /\A%\d{1,9}\z/

      attr_reader :dir, :timeout

      # runner: (argv, stdin, seconds) → [out, err, ok]; a tmux that cannot be run → err starting with NOT_RUNNABLE; one
      # still running after `seconds` → killed, err = timed_out(seconds)
      def initialize(dir:, uid:, runner:, timeout:)
        raise ArgumentError, "tmux timeout must be a positive Integer" unless timeout.is_a?(Integer) && timeout.positive?

        @dir = dir
        @uid = uid
        @runner = runner
        @timeout = timeout
      end

      def self.dir_for(env, uid) = File.join(env["TMUX_TMPDIR"].to_s.empty? ? "/tmp" : env["TMUX_TMPDIR"], "tmux-#{uid}")

      # the socket labels (basenames) of this uid's servers; none = no tmux server ever ran here
      def labels
        Dir.children(@dir).sort.select do |n|
          st = File.lstat(File.join(@dir, n))
          st.socket? && st.uid == @uid && n.match?(LABEL)
        rescue SystemCallError
          false
        end
      rescue Errno::ENOENT
        []
      end

      # → [[[label, rows], …], error or nil]. tmux not installed is THE error; one server failing costs its sessions only
      def rows
        errors = []
        got = labels.filter_map do |label|
          out, err, ok = run(label, "list-panes", "-a", "-F", FORMAT)
          next [label, parse(out)] if ok
          return [[], err] if err.start_with?(NOT_RUNNABLE)
          next nil if DEAD.any? { |m| err.include?(m) }

          errors << "tmux #{label}: #{err.strip[0, 200]}"
          nil
        end
        [got, errors.empty? ? nil : errors.join("; ")]
      end

      def parse(text)
        text.lines.filter_map do |line|
          parts = line.chomp.split(" ", FIELDS.size)
          next if parts.size != FIELDS.size || parts.last.empty?

          row = FIELDS.zip(parts).to_h
          next unless row["pane_id"].match?(PANE) && INTS.all? { |k| row[k].match?(/\A\d+\z/) }

          INTS.each { |k| row[k] = row[k].to_i }
          row
        end
      end

      # one tmux command on server `label`, by its socket path (-S): never a socket outside this uid's dir
      def run(label, *args, stdin: nil)
        raise ArgumentError, "bad tmux socket #{label.inspect}" unless label.to_s.match?(LABEL)

        @runner.call(["tmux", "-S", File.join(@dir, label), *args], stdin, @timeout)
      end
    end
  end
end
