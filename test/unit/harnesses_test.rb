# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "busyyaks/harnesses"

# which harnesses exist is the committed config/harnesses.yml; whether one is installed is read in the shell
# a launch runs in (bash -ic) — a program, a shell function, an alias, or nothing — and a program's version is read
# by running it: found / not found / found but its version run failed, never guessed.
class HarnessesTest < Minitest::Test
  H = Busyyaks::Harnesses

  def entry(**over)
    { "label" => "X", "command" => "x", "version_args" => ["--version"], "version_pattern" => '(\d+\.\d+)',
      "install_url" => "https://x.example/install", "kind" => nil, "launch_args" => [], }
      .merge(over.transform_keys(&:to_s))
  end

  def test_the_committed_list_is_claude_hermes_codex
    list = H.load
    assert_equal %w[claude hermes codex], list.map(&:key)
    assert_equal ["claude_code", "hermes", nil], list.map(&:kind)
    assert_equal [[], ["chat"], []], list.map(&:launch_args)
    assert(list.all? { |h| h.install_url.start_with?("https://") })
    assert_equal "2.1.326", "2.1.326 (Claude Code)"[list[0].version_pattern, 1]
    assert_equal "0.21.5+8082.gbaef00b",
                 "Hermes Agent v0.21.5+8082.gbaef00b (2026.9.24) · upstream baef00bf"[list[1].version_pattern, 1]
    assert_equal "0.166.0", "codex-cli 0.166.0"[list[2].version_pattern, 1]
  end

  # a new engine launch kind with no harness behind it fails here, not on a host
  def test_every_engine_launch_kind_has_a_harness
    assert_equal AgentsKanban::Launch::KINDS.keys.sort, H::KINDS.sort
    assert_equal H::KINDS.sort, H.load.filter_map(&:kind).uniq.sort
  end

  def test_a_bad_entry_is_refused_naming_the_field
    assert_raises(H::Invalid) { H.load("/nope.yml") }
    assert_raises(H::Invalid) { H.parse({}) }
    {
      { command: "../x" } => /x\.command/,
      { command: "a b" } => /x\.command/,
      { install_url: "http://x" } => /install_url/,
      { kind: "codex" } => /kind must be one of claude_code, hermes or null/,
      { version_args: "--version" } => /version_args/,
      { label: " " } => /label/,
      { launch_args: [1] } => /launch_args/,
      { version_pattern: "(" } => /version_pattern is not a regular expression/,
      { version_pattern: '\d+' } => /version_pattern must have one capture group/,
      { version_pattern: '(\d)(\d)' } => /version_pattern must have one capture group/,
      { version_pattern: 1 } => /version_pattern must be a string/,
    }.each do |over, why|
      e = assert_raises(H::Invalid, over.inspect) { H.parse({ "x" => entry(**over) }) }
      assert_match why, e.message
    end
    assert_match(/exactly/, assert_raises(H::Invalid) { H.parse({ "x" => entry.merge("extra" => 1) }) }.message)
    assert_match(/key/, assert_raises(H::Invalid) { H.parse({ "X Y" => entry }) }.message)
  end

  ENV2 = { "PATH" => "/h/bin:/usr/bin", "HOME" => "/h" }.freeze

  # a runner standing in for bin/launcher's: the resolve child answers `lines`; each program answers from `programs`
  # (path → [output, code]); every call recorded
  def runner(lines, programs = {})
    calls = []
    run = lambda do |env, argv, timeout_s:, err:, clean_env:|
      calls << { env: env, argv: argv, timeout_s: timeout_s, err: err, clean_env: clean_env }
      next [lines.map { |l| "#{l}\n" }.join, 0] if argv.first == "bash"

      res = programs.fetch(argv.first)
      raise res if res.is_a?(Exception)

      res
    end
    [run, calls]
  end

  def mark(name, type = "", path = "") = ["BYHARNESS", name, type, path].join("\t")

  def test_found_not_found_a_function_an_alias_and_failed_version_runs
    list = H.parse(%w[ok bad mute plain gone myfn myal].to_h { |k| [k, entry(command: k)] })
    run, calls = runner(
      ["profile noise", mark("ok", "file", "/h/bin/ok"), mark("bad", "file", "/h/bin/bad"), mark("mute", "file", "/h/bin/mute"),
       mark("plain", "file", "/h/bin/plain"), mark("gone"), mark("myfn", "function"), mark("myal", "alias"),],
      { "/h/bin/ok" => ["\nok v1.2 (Ok)\nsecond\n", 0], "/h/bin/bad" => ["nope\n", 3],
        "/h/bin/mute" => ["no digits here\n", 0], "/h/bin/plain" => Errno::EACCES.new, }
    )
    got = H.probe(list, %w[ok myfn gone], env: ENV2, run: run)
    by = got[:harnesses].to_h { |r| [r[:key], r] }
    assert_equal [true, "file", "/h/bin/ok", "1.2", nil], by["ok"].values_at(:found, :type, :path, :version, :version_error)
    assert_equal [true, nil, "exit 3: nope"], by["bad"].values_at(:found, :version, :version_error)
    assert_equal [nil, "no version in output: no digits here"], by["mute"].values_at(:version, :version_error)
    # bash keeps a non-executable match as its last resort (a launch would fail on it): said, not hidden
    assert_equal [true, "file", "plain: Errno::EACCES"], by["plain"].values_at(:found, :type, :version_error)
    assert_equal [false, nil], by["gone"].values_at(:found, :version_error)
    assert_equal [true, "function", nil, "not run: shell function"],
                 by["myfn"].values_at(:found, :type, :path, :version_error)
    assert_equal [true, "alias", "not run: shell alias"], by["myal"].values_at(:found, :type, :version_error)
    assert_equal [{ command: "ok", found: true, type: "file", path: "/h/bin/ok" },
                  { command: "myfn", found: true, type: "function", path: nil },
                  { command: "gone", found: false, type: nil, path: nil },], got[:commands]
    # ONE resolve child: bash -ic, the names as positional args (never in the script), stderr dropped, the env over its own
    resolve = calls.first
    assert_equal ["bash", "-ic", H::SCRIPT, "_", "ok", "bad", "mute", "plain", "gone", "myfn", "myal"], resolve[:argv]
    assert_equal [ENV2, :null, false, 8], resolve.values_at(:env, :err, :clean_env, :timeout_s)
    # the version runs: the program file only, PATH + HOME alone, stderr with stdout, 5 s
    runs = calls.drop(1).sort_by { |c| c[:argv].first }
    assert_equal %w[/h/bin/bad /h/bin/mute /h/bin/ok /h/bin/plain], runs.map { |c| c[:argv].first }
    assert_equal [[["--version"], ENV2, :out, true, 5]],
                 runs.map { |c| [c[:argv].drop(1), *c.values_at(:env, :err, :clean_env, :timeout_s)] }.uniq
  end

  def test_a_name_that_is_not_a_program_name_is_refused_before_any_shell
    run, calls = runner([])
    e = assert_raises(H::Failed) { H.probe([], ["a;b"], env: ENV2, run: run) }
    assert_match(/refused names \["a;b"\]/, e.message)
    assert_empty calls
  end

  # PATH + HOME are the caller's to give (the launcher's own): none → refused, never this process's taken instead
  def test_path_and_home_are_required
    run, = runner([])
    assert_equal "harness probe: PATH + HOME required", assert_raises(H::Failed) { H.probe([], [], env: {}, run: run) }.message
    assert_equal "harness probe: HOME required",
                 assert_raises(H::Failed) { H.probe([], [], env: { "PATH" => "/bin", "HOME" => "" }, run: run) }.message
  end

  # the resolve child failing in any way fails the probe — never a partial "not found"
  def test_a_failed_resolve_fails_the_probe
    list = H.parse({ "x" => entry })
    {
      [nil] => "harness probe: bash -ic timed out after 8 s",
      [2] => "harness probe: bash -ic exit 2",
      ["signal 9"] => "harness probe: bash -ic exit signal 9",
    }.each do |(code), why|
      run = ->(*, **) { ["", code] }
      assert_equal why, assert_raises(H::Failed) { H.probe(list, [], env: ENV2, run: run) }.message
    end
    run = ->(*, **) { [mark("other", "file", "/o"), 0] }
    assert_equal "harness probe: bash -ic answered no line for x",
                 assert_raises(H::Failed) { H.probe(list, [], env: ENV2, run: run) }.message
    run = ->(*, **) { raise Errno::ENOENT }
    e = assert_raises(H::Failed) { H.probe(list, [], env: ENV2, run: run) }
    assert_equal "harness probe: bash: Errno::ENOENT", e.message
  end

  def test_a_version_run_past_its_deadline_is_said
    run, = runner([mark("x", "file", "/h/bin/x")], { "/h/bin/x" => ["", nil] })
    got = H.probe(H.parse({ "x" => entry }), [], env: ENV2, run: run).fetch(:harnesses).first
    assert_equal [true, nil, "timed out after 5 s"], got.values_at(:found, :version, :version_error)
  end
end
