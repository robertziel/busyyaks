# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/wait"
require "tmpdir"
require "fileutils"
require "socket"
require "json"
require "etc"
require "yaml"

# bin/launcher's `harnesses` op, the launcher itself run as a process in a sandbox checkout: the probe's
# children are ITS children (the services never spawn). A real `bash -ic` reads the sandbox HOME's .bashrc, so what it
# answers is what a launch would find: a program on PATH (its version run, only PATH + HOME), a shell function, nothing,
# and a program that never answers (killed at the 5 s deadline). The allowlisted commands are resolved, never run.
class LauncherHarnessesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60
  COPY = %w[bin/launcher lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml config/harnesses.yml].freeze
  INVOCATIONS = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands")

  def setup
    @base = File.realpath(Dir.mktmpdir("launcher-harness", Etc.getpwuid(Process.uid).dir))
    @co = File.join(@base, "checkout")
    @bin = File.join(@base, "bin")
    @home = File.join(@base, "home")
    FileUtils.mkdir_p([File.join(@base, "projects"), @bin, @home, File.join(@co, "config"), File.join(@base, "sessions")])
    COPY.each do |f|
      FileUtils.mkdir_p(File.dirname(File.join(@co, f)))
      FileUtils.cp_r(File.join(ROOT, f), File.join(@co, f))
    end
    FileUtils.cp(File.join(ROOT, "test/fixtures/kanban.yml"), File.join(@co, "config/kanban.yml"))
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(
      "roots" => [{ "path" => "/projects", "prefix" => "" }], "search_depth" => 2,
      "owner_remotes" => ["github.com/you/"], "author_emails" => ["you@example.com"], "window_days" => 7,
      "reap_protect" => [], "auth" => { "provider" => "none" }, "agents" => { "collector" => "none" },
      "terminal" => { "public_host" => "deny", "max_open" => 4 }, "github_hook" => "none",
      "ci" => { "max_pending_minutes" => 60, "required" => { "o/r" => ["jenkins/ci"] } },
      "skills" => { "max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil },
      "updates" => { "remote" => "origin", "branch" => "main", "tags" => "v*", "channel" => "tags", "check_minutes" => 60 },
      "launch" => { "trusted_paths" => [], "commands" => INVOCATIONS, "start_seconds" => 30, "scopes" => nil }
    ))
    File.write(File.join(@co, ".env"), <<~ENV)
      PROJECTS_ROOT=#{File.join(@base, 'projects')}
      PROJECTS_MOUNT=/projects
      LAUNCHER_RUN_DIR=#{File.join(@base, 'run')}
      LAUNCHER_STATE_DIR=#{File.join(@base, 'state')}
      CLAUDE_SESSIONS_DIR=#{File.join(@base, 'sessions')}
      CLAUDE_SESSION_URL=https://claude.example/{id}
    ENV
    # the launch shell's profile: a function (hermes) and one allowlisted wrapper (localclaude)
    File.write(File.join(@home, ".bashrc"), "echo profile noise\nhermes() { :; }\nlocalclaude() { claude \"$@\"; }\n")
    stub("tmux", "exit 1")
    # the version run sees only PATH + HOME: SECRET (the launcher's env) must not reach it
    stub("claude", 'echo "2.1.9 (Claude Code) ${SECRET:-clean} $HOME"')
    stub("codex", "exec sleep 600")
    start
  end

  def teardown
    Process.kill("TERM", @pid) if @pid
    Process.wait(@pid) if @pid
    FileUtils.rm_rf(@base)
  end

  def stub(name, body)
    File.write(File.join(@bin, name), "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, File.join(@bin, name))
  end

  def start
    @log = File.join(@base, "launcher.log")
    env = { "PATH" => "#{@bin}:/usr/local/bin:/usr/bin:/bin", "HOME" => @home, "SECRET" => "leak" }
    @pid = Process.spawn(env, RbConfig.ruby, File.join(@co, "bin/launcher"), %i[out err] => [@log, "w"])
    sock = File.join(@base, "run/launcher.sock")
    Wait.for(-> { "the launcher's socket: #{File.read(@log)}" }, seconds: BOOT_SECONDS, every: 0.1) do
      flunk "the launcher exited: #{File.read(@log)}" if Process.waitpid(@pid, Process::WNOHANG)
      File.socket?(sock) && (UNIXSocket.open(sock) { true } rescue false)
    end
  end

  def ask(req)
    UNIXSocket.open(File.join(@base, "run/launcher.sock")) do |s|
      s.puts(JSON.generate(req))
      Wait.readable(s, -> { "the launcher's answer: #{File.read(@log)}" }, seconds: 60)
      JSON.parse(s.gets)
    end
  end

  def test_the_launch_shell_finds_programs_functions_and_nothing
    res = ask(op: "harnesses", command: "rm") # a field the web might send is ignored: the op takes no parameter
    assert res["ok"], res.inspect
    assert_equal "bash -ic", res["shell"]
    by = res["harnesses"].to_h { |h| [h["key"], h] }
    assert_equal %w[claude hermes codex], by.keys
    claude = by["claude"]
    assert_equal [true, "file", File.join(@bin, "claude"), "2.1.9", nil],
                 claude.values_at("found", "type", "path", "version", "version_error")
    assert_equal ["Claude Code", "claude_code", "https://code.claude.com/docs/en/setup", []],
                 claude.values_at("label", "kind", "install_url", "launch_args")
    assert_equal [true, "function", nil, nil, "not run: shell function"],
                 by["hermes"].values_at("found", "type", "path", "version", "version_error")
    assert_equal [true, "file", nil, "timed out after 5 s"], by["codex"].values_at("found", "type", "version", "version_error")
    assert_equal INVOCATIONS, res["allowlist"]
    assert_equal [{ "command" => "claude", "found" => true, "type" => "file", "path" => File.join(@bin, "claude") },
                  { "command" => "localclaude", "found" => true, "type" => "function", "path" => nil },],
                 res["commands"]
  end

  # the version run gets only PATH + HOME: the launcher's SECRET never reaches it
  def test_the_version_run_gets_only_path_and_home
    seen = File.join(@base, "seen")
    stub("claude", "echo \"${SECRET:-none} $HOME\" > #{seen}; echo 2.1.0")
    stub("codex", 'echo "codex-cli 0.1.0"')
    res = ask(op: "harnesses")
    assert_equal %w[2.1.0 0.1.0], [res["harnesses"].first["version"], res["harnesses"].last["version"]]
    assert_equal "none #{@home}", File.read(seen).strip
  end
end
