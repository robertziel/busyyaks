# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "socket"
require "json"
require "etc"
require "yaml"

# bin/launcher itself, run as a process in a sandbox checkout (its own .env and config, a stub tmux that only records
# its calls, a git wrapper that fakes `clone`): the folder-trust wiring of create and launch.
#   - `git init` (create, no URL) is recorded and trusted;
#   - a clone is never trusted, of an owner_remotes URL included, and runs with nothing inherited;
#   - a corrupt created.json refuses a launch before `tmux new-session` runs.
class LauncherTrustTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60 # the launcher's start, until its socket exists
  # launch.start_seconds of the sandbox: far above the 13 s a slow wrapper below takes, so a refusal "at
  # once" is told from one on the clock by its reason and its distance from this, never by the machine's speed
  START_SECONDS = 120
  COPY = %w[bin/launcher lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml].freeze

  def setup
    # under the user's home: the run dir's parents must not be writable by another user (LauncherRules.run_dir!)
    @base = File.realpath(Dir.mktmpdir("launcher-trust", Etc.getpwuid(Process.uid).dir))
    @co = File.join(@base, "checkout")
    @projects = File.join(@base, "projects")
    @bin = File.join(@base, "bin")
    @tmux_log = File.join(@base, "tmux.log")
    @clone_env = File.join(@base, "clone.env")
    FileUtils.mkdir_p([@projects, @bin, File.join(@co, "config"), File.join(@base, "sessions")])
    COPY.each do |f|
      FileUtils.mkdir_p(File.dirname(File.join(@co, f)))
      FileUtils.cp_r(File.join(ROOT, f), File.join(@co, f))
    end
    FileUtils.cp(File.join(ROOT, "test/fixtures/kanban.yml"), File.join(@co, "config/kanban.yml"))
    write_config(START_SECONDS)
    File.write(File.join(@co, ".env"), <<~ENV)
      PROJECTS_ROOT=#{@projects}
      PROJECTS_MOUNT=/projects
      LAUNCHER_RUN_DIR=#{File.join(@base, 'run')}
      LAUNCHER_STATE_DIR=#{File.join(@base, 'state')}
      CLAUDE_SESSIONS_DIR=#{File.join(@base, 'sessions')}
      CLAUDE_SESSION_URL=https://claude.example/{id}
    ENV
    # tmux: records every call; the pane shows Claude Code's trust prompt until Enter is pressed on it. new-session
    # starts the pane's process: a `claude --remote-control <session>` (a copy of bash named claude, so /proc shows
    # that argv), or — with the `refuse` file present — a bare shell, as when claude refused to start
    entered = File.join(@base, "entered")
    @refuse = File.join(@base, "refuse")
    @pids = File.join(@base, "pids")
    @pane = File.join(@base, "pane.sh") # a pane command of a test's own: `sh pane.sh <session>`
    @dialog = File.join(@base, "dialog") # the pane shows a permission dialog
    FileUtils.cp(Open3.capture2("sh", "-c", "command -v bash").first.strip, File.join(@bin, "claude"))
    stub("tmux", <<~SH)
      echo "$*" >> #{@tmux_log}
      case "$1" in
        new-session)
          while [ "$1" != -s ]; do shift; done
          if [ -e #{@pane} ]; then sh #{@pane} "$2" >/dev/null 2>&1 &
          elif [ -e #{@refuse} ]; then sleep 300 >/dev/null 2>&1 &
          else #{@bin}/claude -c 'sleep 300; :' --remote-control "$2" >/dev/null 2>&1 & fi
          echo $! >> #{@pids}; echo $! > #{@base}/pane.pid; date +%s.%N > #{@base}/started_at; exit 0 ;;
        list-panes) [ -e #{@base}/pane.pid ] && cat #{@base}/pane.pid && exit 0; exit 1 ;;
        kill-session) [ -e #{@base}/nokill ] && echo "server busy" >&2 && exit 1; exit 0 ;;
        has-session) [ -e #{@base}/nokill ] && [ -e #{@base}/pane.pid ] && exit 0; exit 1 ;;
        ls|display-message) exit 1 ;;
        capture-pane)
          if [ -e #{@dialog} ]; then printf '%s\\n' "Do you want to proceed?" "❯ 1. Yes" "Enter to confirm · Esc to cancel"
          elif [ -e #{@refuse} ]; then echo "Temp directory /tmp/claude-1000 is owned by uid 0, expected 1000."; echo '$ '
          elif [ -e #{entered} ]; then echo "> "; else
            printf '%s\\n' "Do you trust the files in this folder?" "❯ 1. Yes, I trust this folder" "  2. No, exit"
          fi
          exit 0 ;;
        send-keys) case " $* " in *" Enter "*) touch #{entered} ;; esac; exit 0 ;;
      esac
      exit 0
    SH
    real_git = Open3.capture2("sh", "-c", "command -v git").first.strip
    stub("git", <<~SH)
      case " $* " in
        *" clone "*)
          env > #{@clone_env}; for a; do d=$a; done
          mkdir -p "$d/.git/objects/ab" "$d/.git/refs/heads"
          echo blob > "$d/.git/objects/ab/cdef"; echo 0123 > "$d/.git/refs/heads/main"; echo clone > "$d/CLONED"
          exit 0 ;;
      esac
      exec #{real_git} "$@"
    SH
    start
  end

  def teardown
    File.readlines(@pids).each { |p| Process.kill("TERM", p.to_i) rescue nil } if File.exist?(@pids)
    Process.kill("TERM", @pid) if @pid
    Process.wait(@pid) if @pid
    FileUtils.rm_rf(@base)
  end

  def write_config(start_seconds)
    launch = { "trusted_paths" => [], "start_seconds" => start_seconds }.compact
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(
      "roots" => [{ "path" => "/projects", "prefix" => "" }], "search_depth" => 2,
      "owner_remotes" => ["github.com/you/"], "author_emails" => ["you@example.com"], "window_days" => 7,
      "reap_protect" => [], "auth" => { "provider" => "none" }, "agents" => { "collector" => "none" },
      "launch" => launch
    ))
  end

  def restart(start_seconds)
    Process.kill("TERM", @pid)
    Process.wait(@pid)
    @pid = nil
    write_config(start_seconds)
    start
  end

  def stub(name, body)
    File.write(File.join(@bin, name), "#!/bin/sh\n#{body}")
    File.chmod(0o755, File.join(@bin, name))
  end

  def start
    @log = File.join(@base, "launcher.log")
    env = { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "GIT_SSH_COMMAND" => "false", "GIT_TEMPLATE_DIR" => "/nowhere",
            "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "protocol.file.allow", "GIT_CONFIG_VALUE_0" => "always", }
    @pid = Process.spawn(env, RbConfig.ruby, File.join(@co, "bin/launcher"), %i[out err] => [@log, "w"])
    sock = File.join(@base, "run/launcher.sock")
    # its boot (ruby + the engine) took > 10 s on the CI host under load (66 test workers, load 60 on 20 CPUs): wait
    # for the socket to accept a connection, or the process's exit, up to BOOT_SECONDS. The file alone is not enough:
    # UNIXServer.new binds (the file appears) before it listens, and a connect in between is refused
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_SECONDS
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      return if accepting?(sock)
      flunk "the launcher exited: #{File.read(@log)}" if Process.waitpid(@pid, Process::WNOHANG)

      sleep 0.1
    end
    flunk "no socket after #{BOOT_SECONDS}s: #{File.read(@log)}"
  end

  def accepting?(sock)
    File.socket?(sock) && UNIXSocket.open(sock) { true }
  rescue Errno::ECONNREFUSED
    false
  end

  def ask(req)
    UNIXSocket.open(File.join(@base, "run/launcher.sock")) do |s|
      s.puts(JSON.generate(req))
      JSON.parse(s.gets)
    end
  end

  def created
    f = File.join(@base, "state/created.json")
    File.exist?(f) ? JSON.parse(File.read(f)) : []
  end

  def launch(name)
    ask("op" => "launch", "path" => "/projects/#{name}", "session" => "#{name}_s", "type" => "lead",
        "launcher" => "fullclaude",
        "vars" => { "slug" => name, "session" => "#{name}_s", "agent" => "a", "type" => "lead", "cards" => "-" })
  end

  def tmux_calls = File.exist?(@tmux_log) ? File.read(@tmux_log) : ""

  # the trust prompt on the pane: pressed for a repo the launcher made, left for any other
  def test_the_trust_prompt_is_pressed_only_for_a_trusted_repo
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    r = launch("fresh")
    assert_equal "accepted", r["trust"], r.inspect
    assert_match(/send-keys -t =fresh_s: Enter/, tmux_calls)
    FileUtils.rm_f(File.join(@base, "entered"))
    File.write(@tmux_log, "")
    Open3.capture3("git", "init", "-q", File.join(@projects, "planted"))
    r = launch("planted")
    assert_equal "left", r["trust"], r.inspect
    assert_includes tmux_calls, "new-session"
    refute_includes tmux_calls, "Enter", "nothing pressed for a repo the launcher did not make"
  end

  # a clone and a git init of one name at the same moment: at most one create succeeds, and nothing cloned is ever
  # trusted (the dir is reserved by an exclusive mkdir; record takes only a fresh init)
  def test_a_clone_racing_an_init_is_never_trusted
    50.times do |i|
      name = "race#{i}"
      clone = { "op" => "create", "root" => "/projects", "name" => name, "url" => "https://github.com/you/#{name}" }
      init = { "op" => "create", "root" => "/projects", "name" => name, "url" => "" }
      threads = [Thread.new { ask(clone) }, Thread.new { sleep 0.001; ask(init) }]
      results = threads.map(&:value)
      assert_operator results.count { |x| x["ok"] }, :<=, 1, "#{name}: #{results.inspect}"
    end
    100.times { break if ask("op" => "jobs")["jobs"].all? { |j| j["status"] != "running" }; sleep 0.1 }
    trusted = created.map { |e| e["path"] }
    cloned = trusted.select { |p| File.exist?(File.join(p, "CLONED")) || Dir.exist?(File.join(p, ".git/objects/ab")) }
    assert_empty cloned, "a cloned repo was trusted"
  end

  def test_git_init_is_recorded_and_trusted
    r = ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    assert_equal [true, true], r.values_at("ok", "trusted"), r.inspect
    repo = File.join(@projects, "fresh")
    assert_equal [repo], created.map { |e| e["path"] }
    assert_equal created.first["nonce"], File.read(File.join(repo, ".git/busyyaks-created"))
  end

  def test_a_clone_is_never_trusted_and_inherits_nothing
    r = ask("op" => "create", "root" => "/projects", "name" => "", "url" => "https://github.com/you/app")
    assert_equal [true, false], r.values_at("ok", "trusted"), r.inspect
    50.times { break if ask("op" => "jobs")["jobs"].all? { |j| j["status"] != "running" }; sleep 0.1 }
    assert File.directory?(File.join(@projects, "app/.git")), "the (stub) clone ran"
    assert_empty created, "a clone of an owner_remotes URL is not recorded"
    env = File.read(@clone_env).lines.to_h { |l| l.chomp.split("=", 2) }
    keys = env.keys - %w[PWD SHLVL _ OLDPWD] # set by the stub's own shell
    assert_equal %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_LFS_SKIP_SMUDGE GIT_TEMPLATE_DIR GIT_TERMINAL_PROMPT HOME
                    PATH].sort,
                 (keys - %w[LANG SSH_AUTH_SOCK]).sort
    refute env.key?("GIT_SSH_COMMAND")
    refute env.key?("GIT_CONFIG_COUNT")
  end

  # claude never came up (it refused to start; the pane is a bare shell): the launch is refused with the pane's last
  # lines and the session killed — never an ok the engine would register an owner on
  def test_a_launch_without_claude_remote_control_is_refused_and_killed
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    File.write(@refuse, "")
    r = launch("fresh")
    refute r["ok"], r.inspect
    assert_equal 422, r["status"]
    assert_match(/\Afresh_s did not start: the command exited after \d+s, no claude --remote-control fresh_s: /, r["error"])
    assert_match(/: Temp directory .* owned by uid 0/, r["error"])
    assert_match(/kill-session -t =fresh_s/, tmux_calls)
  end

  def test_a_refused_launch_whose_kill_failed_says_the_session_still_runs
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    File.write(@refuse, "")
    File.write(File.join(@base, "nokill"), "")
    r = launch("fresh")
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    assert_match(/kill-session failed \(server busy\): the tmux session fresh_s is still running\z/, r["error"])
  end

  def test_a_launch_with_claude_remote_control_up_is_ok_and_kept
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    r = launch("fresh")
    assert_equal [true, "on", "fresh_s"], r.values_at("ok", "remote_control", "remote_control_name"), r.inspect
    refute_includes tmux_calls, "kill-session"
  end

  # a record the launcher cannot read refuses a launch before any session starts
  def test_a_corrupt_record_refuses_the_launch_before_tmux_new_session
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    File.write(File.join(@base, "state/created.json"), "{not json")
    r = launch("fresh")
    refute r["ok"], r.inspect
    assert_match(/folder trust: .*created\.json is not valid JSON/, r["error"])
    calls = File.exist?(@tmux_log) ? File.read(@tmux_log) : ""
    assert_includes calls, "has-session"
    refute_includes calls, "new-session", "nothing was started"
  end

  # the start check waits on the REAL signal, not a fixed window — a planted repo (trust left: no trust wait)
  def planted(name)
    Open3.capture3("git", "init", "-q", File.join(@projects, name))
  end

  def timed
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = yield
    [r, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t]
  end

  # seconds since the stub's `tmux new-session` started the pane (where the launcher's start clock starts)
  def since_new_session = Time.now.to_f - File.read(File.join(@base, "started_at")).to_f

  # a refusal "at once": the command-exited reason, its seconds = the launch's own clock (within the rounding, the
  # kill and the answer's trip), and far below launch.start_seconds — whatever the machine's speed
  def assert_refused_at_once(r, session)
    since = since_new_session
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    m = r["error"].match(/\A#{session} did not start: the command exited after (\d+)s, no claude --remote-control #{session}: /)
    assert m, r["error"]
    assert_in_delta since, m[1].to_i, 3, "the error's clock is the launch's: #{r['error']}"
    assert_operator m[1].to_i, :<, START_SECONDS / 2
    m[1].to_i
  end

  # a wrapper (a shell function starting a gateway, an ssh forward) that works longer than the old fixed 12 s, then
  # execs claude --remote-control: up, kept
  def test_a_slow_wrapper_that_then_starts_claude_is_ok
    planted("slow")
    File.write(@pane, "sleep 13; exec #{@bin}/claude -c 'sleep 300; :' --remote-control \"$1\"\n")
    r, took = timed { launch("slow") }
    assert_equal [true, "on", "slow_s"], r.values_at("ok", "remote_control", "remote_control_name"), r.inspect
    assert_operator took, :>, 12
    refute_includes tmux_calls, "kill-session"
  end

  # the command exited into the pane's bare shell: refused at once (3 checks), well before launch.start_seconds
  def test_a_command_that_exits_at_once_is_refused_fast_with_the_pane_tail
    planted("gone")
    File.write(@refuse, "")
    r = launch("gone")
    assert_refused_at_once(r, "gone_s")
    assert_match(/: Temp directory/, r["error"])
    assert_match(/kill-session -t =gone_s/, tmux_calls)
  end

  # a command that keeps working and never starts claude: refused once launch.start_seconds passed
  def test_a_command_that_never_starts_claude_is_refused_after_start_seconds
    restart(4)
    planted("stuck")
    File.write(@pane, "sleep 30; :\n")
    r, took = timed { launch("stuck") }
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    m = r["error"].match(/\Astuck_s did not start: no claude --remote-control stuck_s after (\d+)s \(launch.start_seconds 4\)/)
    assert m, r["error"]
    assert_operator m[1].to_i, :>=, 4
    assert_operator took, :>=, 4
    assert_match(/kill-session -t =stuck_s/, tmux_calls)
  end

  # a pane that merely looks like a dialog, with no claude process: a failed start, never a kept session
  def test_a_dialog_looking_pane_without_claude_is_refused
    planted("dlg")
    File.write(@refuse, "")
    File.write(@dialog, "")
    r = launch("dlg")
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    assert_match(/\Adlg_s did not start: the command exited after \d+s, no claude --remote-control dlg_s: /, r["error"])
    assert_match(/: Do you want to proceed/, r["error"])
    assert_match(/kill-session -t =dlg_s/, tmux_calls)
  end

  # launch.start_seconds is required: the launcher refuses to start without it, or with one out of 1..600
  def test_the_launcher_refuses_to_start_without_a_valid_start_seconds
    Process.kill("TERM", @pid)
    Process.wait(@pid)
    @pid = nil
    [nil, 0, 601, "30"].each do |v|
      write_config(v)
      pid = Process.spawn(RbConfig.ruby, File.join(@co, "bin/launcher"), %i[out err] => [@log, "w"])
      _p, st = Process.wait2(pid)
      refute st.success?, v.inspect
      assert_match(/launch.start_seconds must be an integer 1..600/, File.read(@log), v.inspect)
    end
  end

  # a TRUSTED repo (the launcher's git init): the trust wait shares the start clock — an instant exit is refused as
  # fast as for any repo, never after the trust wait's 15 s, and the error names the true elapsed seconds
  def test_a_trusted_repo_whose_command_exits_at_once_is_refused_fast_with_the_true_elapsed
    ask("op" => "create", "root" => "/projects", "name" => "tgone", "url" => "")
    File.write(@refuse, "")
    # the trust wait (15 s) ended on the bare shell: refused before it would have run out
    assert_operator assert_refused_at_once(launch("tgone"), "tgone_s"), :<, 15
    refute_includes tmux_calls, "Enter", "nothing answered on a pane that is a bare shell"
  end

  # a TRUSTED repo whose wrapper works longer than the trust wait, then starts claude: its prompt answered, up, kept
  def test_a_trusted_repo_with_a_slow_wrapper_is_ok
    ask("op" => "create", "root" => "/projects", "name" => "tslow", "url" => "")
    File.write(@pane, "sleep 13; exec #{@bin}/claude -c 'sleep 300; :' --remote-control \"$1\"\n")
    r, took = timed { launch("tslow") }
    assert_equal [true, "accepted", "on", "tslow_s"], r.values_at("ok", "trust", "remote_control", "remote_control_name"),
                 r.inspect
    assert_operator took, :>, 12
    refute_includes tmux_calls, "kill-session"
  end
end
