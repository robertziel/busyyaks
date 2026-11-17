# frozen_string_literal: true

require "yaml"

module Busyyaks
  # The agent harnesses (coding-agent CLIs) the hello screen looks for on the host. Which harnesses exist is
  # configuration — config/harnesses.yml (committed); whether one is installed is read on the HOST by bin/launcher's
  # `harnesses` op (`probe`): every harness command and every launch.commands command resolved in ONE `bash -ic` child
  # — the shell a launch runs in, so "found" = "a launch would find it" (the profile's PATH, shell functions, aliases);
  # the names are positional args, never part of the script — then each harness found as a FILE run with its
  # version_args (no shell, only PATH + HOME, a deadline), the version = version_pattern's first capture. Nothing is
  # guessed and nothing cached: the resolve child failing → Failed (the op answers the error, never "not found").
  # Pure Ruby, no dependencies: bin/launcher requires this file alone.
  module Harnesses
    class Invalid < StandardError; end
    class Failed < StandardError; end

    PATH = File.expand_path("../../config/harnesses.yml", __dir__)
    KEY = /\A[a-z][a-z0-9_-]{0,31}\z/
    COMMAND = /\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\z/ # a program name, looked up — never a path or a shell word
    FIELDS = %w[command install_url kind label launch_args version_args version_pattern].freeze
    KINDS = %w[claude_code hermes].freeze # the engine's Launch::KINDS a harness may name (null = none yet)
    RESOLVE_TIMEOUT_S = 8
    VERSION_TIMEOUT_S = 5
    OUTPUT_MAX = 4096 # what a runner keeps of a child's output
    MARK = "BYHARNESS"
    # one line per name: the marker, the name, `type -t` (file · function · alias · builtin · keyword · empty), and
    # `command -v` (the path for a file). The marker keeps the profile's own output out.
    SCRIPT = <<~'SH'
      for n in "$@"; do
        t=$(type -t -- "$n" 2>/dev/null | head -n 1)
        p=""; [ "$t" = file ] && p=$(command -v -- "$n" 2>/dev/null)
        printf '%s\t%s\t%s\t%s\n' BYHARNESS "$n" "$t" "$p"
      done
    SH

    # launch_args: the args a launch.commands entry for it needs (hermes: chat) — the line the hello screen offers to add
    Harness = Struct.new(:key, :label, :command, :version_args, :version_pattern, :install_url, :kind, :launch_args,
                         keyword_init: true) do
      def to_h = { key: key, label: label, command: command, install_url: install_url, kind: kind, launch_args: launch_args }
    end

    module_function

    def load(path = PATH)
      raise Invalid, "harness list not found: #{path}" unless File.file?(path)

      parse(YAML.safe_load_file(path), path)
    end

    def parse(doc, path = "harnesses")
      raise Invalid, "#{path} must be a non-empty mapping of key → {#{FIELDS.join(', ')}}" unless doc.is_a?(Hash) && doc.any?

      doc.map do |key, h|
        raise Invalid, "#{path}: key #{key.inspect} must match #{KEY.source}" unless key.is_a?(String) && key.match?(KEY)
        raise Invalid, "#{path}: #{key} must have exactly #{FIELDS.join(', ')}" unless h.is_a?(Hash) && h.keys.sort == FIELDS

        harness(key, h, path)
      end
    end

    def harness(key, h, path)
      bad = ->(why) { raise Invalid, "#{path}: #{key}.#{why}" }
      strings = ->(v) { v.is_a?(Array) && v.all?(String) }
      bad.("label must be a non-empty string") unless h["label"].is_a?(String) && !h["label"].strip.empty?
      bad.("command must match #{COMMAND.source}") unless h["command"].is_a?(String) && h["command"].match?(COMMAND)
      bad.("version_args must be a list of strings") unless strings.(h["version_args"])
      bad.("launch_args must be a list of strings") unless strings.(h["launch_args"])
      bad.("install_url must be an https URL") unless h["install_url"].is_a?(String) && h["install_url"].match?(%r{\Ahttps://\S+\z})
      bad.("kind must be one of #{KINDS.join(', ')} or null") unless h["kind"].nil? || KINDS.include?(h["kind"])
      pattern = pattern!(h["version_pattern"]) { |why| bad.("version_pattern #{why}") }

      Harness.new(key: key, label: h["label"], command: h["command"], version_args: h["version_args"],
                  version_pattern: pattern, install_url: h["install_url"], kind: h["kind"], launch_args: h["launch_args"])
    end

    def pattern!(src)
      yield "must be a string" unless src.is_a?(String)
      re = Regexp.new(src)
      yield "must have one capture group" unless re.names.empty? && Regexp.new("#{src}|").match("").captures.size == 1
      re
    rescue RegexpError => e
      yield "is not a regular expression: #{e.message}"
    end

    # → {harnesses: [{key, found, type, path, version, version_error}], commands: [{command, found, type, path}]}
    # list: the harnesses; commands: launch.commands' command names (resolved only, never run).
    # env: PATH + HOME (required: the launcher's own, a launch's), over the resolve child's environment; the version
    # runs get only these two.
    # run: how a child runs — only bin/launcher spawns (the services never do: no_git_spawn_test), so it hands its
    # runner in: run.(env, argv, timeout_s:, err: :null | :out, clean_env:) → [output, exit code (0 = success, an
    # Integer, or "signal N") or nil when it was killed at the deadline]; a spawn failure raises SystemCallError.
    def probe(list, commands, env:, run:, resolve_timeout_s: RESOLVE_TIMEOUT_S, version_timeout_s: VERSION_TIMEOUT_S)
      missing = %w[PATH HOME].reject { |k| env[k].is_a?(String) && !env[k].empty? }
      raise Failed, "harness probe: #{missing.join(' + ')} required" if missing.any?

      names = (list.map(&:command) + commands).uniq
      found = resolve(names, env: env, run: run, timeout_s: resolve_timeout_s)
      vars = { env: { "PATH" => env.fetch("PATH"), "HOME" => env.fetch("HOME") }, run: run, timeout_s: version_timeout_s }
      versions = list.map { |h| Thread.new { version_of(h, found.fetch(h.command), **vars) } }.map(&:value)
      { harnesses: list.zip(versions).map { |h, (v, why)| harness_row(h, found.fetch(h.command), v, why) },
        commands: commands.uniq.map { |c| { command: c, **found.fetch(c) } }, }
    end

    def harness_row(h, found, version, why) = { key: h.key, **found, version: version, version_error: why }

    # a program file is run; a shell function / alias / builtin is not (it exists only in the launch shell)
    def version_of(h, resolved, **)
      return [nil, nil] unless resolved[:found]
      return [nil, "not run: shell #{resolved[:type]}"] unless resolved[:type] == "file"

      version(h, resolved[:path], **)
    end

    # name → {found, type, path}, from ONE bash -ic child; a child that fails or overruns → Failed
    def resolve(names, env:, run:, timeout_s:)
      bad = names.reject { |n| n.is_a?(String) && n.match?(COMMAND) }
      raise Failed, "harness probe: refused names #{bad.inspect}" if bad.any?

      out, code = run.(env, ["bash", "-ic", SCRIPT, "_", *names], timeout_s: timeout_s, err: :null, clean_env: false)
      raise Failed, "harness probe: bash -ic timed out after #{timeout_s} s" if code.nil?
      raise Failed, "harness probe: bash -ic exit #{code}" unless code == 0

      rows(out, names)
    rescue SystemCallError => e
      raise Failed, "harness probe: bash: #{e.class}"
    end

    # the resolve child's marker lines → name → {found, type, path}; a name with no line → Failed (never "not found")
    def rows(out, names)
      rows = out.lines.filter_map { |l| l.chomp.split("\t", -1) if l.start_with?("#{MARK}\t") }
                .to_h { |_, n, t, p| [n, resolved_row(t, p)] }
      missing = names - rows.keys
      raise Failed, "harness probe: bash -ic answered no line for #{missing.join(', ')}" if missing.any?

      rows.slice(*names)
    end

    def resolved_row(type, path)
      type = nil if type.to_s.empty?
      { found: !type.nil?, type: type, path: path.to_s.empty? ? nil : path }
    end

    # [version, nil] or [nil, why]: the file run with only PATH + HOME (env), no stdin, killed at the deadline
    def version(h, exe, env:, run:, timeout_s:)
      out, code = run.(env, [exe, *h.version_args], timeout_s: timeout_s, err: :out, clean_env: true)
      first = out.lines.map(&:strip).find { |l| !l.empty? }.to_s
      return [nil, "timed out after #{timeout_s} s"] if code.nil?
      return [nil, "exit #{code}: #{first[0, 80]}".strip] unless code == 0

      v = out[h.version_pattern, 1]
      v ? [v, nil] : [nil, "no version in output: #{first[0, 80]}"]
    rescue SystemCallError => e
      [nil, "#{File.basename(exe)}: #{e.class}"]
    end
  end
end
