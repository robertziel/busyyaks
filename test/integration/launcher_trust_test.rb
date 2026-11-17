# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/wait"
require_relative "../../lib/busyyaks/clock"
require "tmpdir"
require "fileutils"
require "open3"
require "socket"
require "json"
require "etc"
require "yaml"
require "shellwords"

# bin/launcher itself, run as a process in a sandbox checkout (its own .env and config, a stub tmux that only records
# its calls, a git wrapper that fakes `clone`): the folder-trust wiring of create and launch.
#   - `git init` (create, no URL) is recorded and trusted;
#   - a clone is never trusted, of an owner_remotes URL included, and runs with nothing inherited;
#   - a corrupt created.json refuses a launch before `tmux new-session` runs.
class LauncherTrustTest < Minitest::Test
  # the agent settings revision a launch carries: the suite's, test/fixtures/agents.yml
  AGENTS = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))
  # a lead's start carries its key: bin/launcher keeps it in its state dir, never in the session
  LEAD_KEY = "ab" * 32
  # the host allowlist (launch.commands): the fixture's two launchers + a hermes one
  INVOCATIONS = [*YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands"),
                 { "kind" => "hermes", "command" => "hermes", "args" => ["chat"], "via_shell" => false },].freeze
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60 # the launcher's start, until its socket exists
  # launch.start_seconds of the sandbox: far above the 13 s a slow wrapper below takes, so a refusal "at
  # once" is told from one on the clock by its reason and its distance from this, never by the machine's speed
  START_SECONDS = 120
  COPY = %w[bin/launcher lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml config/harnesses.yml skills].freeze

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
    # a hermes launch: its pane runs `hermes`. Like hermes v0.21.5: `skills list` shows the
    # skills of skills.external_dirs, `${BUSYYAKS_SKILLS_DIR}/busyyaks-skills` resolved from ITS environment
    File.write(File.join(@bin, "hermes"), <<~SH)
      #!/bin/sh
      if [ "$1" = skills ]; then
        grep -qF '${BUSYYAKS_SKILLS_DIR}/busyyaks-skills' "$HERMES_HOME/config.yaml" && [ -n "$BUSYYAKS_SKILLS_DIR" ] &&
          for d in "$BUSYYAKS_SKILLS_DIR"/busyyaks-skills/*; do echo "│ $(basename "$d") │ external │ local │ enabled │"; done
        exit 0
      fi
      sleep 300
    SH
    File.chmod(0o755, File.join(@bin, "hermes"))
    @hermes = File.join(@base, "hermes_mode")
    @noplugin = File.join(@base, "noplugin") # a launcher command that drops the extra flags
    # hermes reads its skills from config.yaml skills.external_dirs: the inert line busyyaks's launch env fills
    @home = File.join(@base, "home") # the launcher's HOME: a launch writes nothing user-wide into it
    FileUtils.mkdir_p(@home)
    @hermes_home = File.join(@base, "hermes-home")
    FileUtils.mkdir_p(@hermes_home)
    File.write(File.join(@hermes_home, "config.yaml"),
               YAML.dump("skills" => { "external_dirs" => ["${BUSYYAKS_SKILLS_DIR}/busyyaks-skills"] }))
    stub("tmux", <<~SH)
      echo "$*" >> #{@tmux_log}
      case "$1" in
        new-session)
          # the command the launcher typed (the last word) and its per-session env (-e K=V): the stub agent gets the
          # same --plugin-dir / BUSYYAKS_SKILLS_DIR the real one would (the launcher reads them off /proc)
          for a; do cmd=$a; done
          pd=$(printf '%s' "$cmd" | sed -nE 's/.*--plugin-dir ([^ ]+).*/\\1/p')
          printf '%s\n' "$cmd" > #{@base}/command
          for a; do case "$a" in BUSYYAKS_SKILLS_DIR=*) export "$a" ;; esac; done
          while [ "$1" != -s ]; do shift; done
          # each pane its own process group (setsid): teardown ends the whole group, its `sleep`s too — a TERM to the
          # pane's shell alone left them running 300 s (the flake gate's repeats ran out of tasks)
          if [ -e #{@pane} ]; then setsid sh #{@pane} "$2" "$pd" >/dev/null 2>&1 &
          elif [ -e #{@refuse} ]; then setsid sleep 300 >/dev/null 2>&1 &
          elif [ -e #{@hermes} ]; then setsid #{@bin}/hermes chat >/dev/null 2>&1 &
          elif [ -e #{@noplugin} ]; then setsid #{@bin}/claude -c 'sleep 300; :' --remote-control "$2" >/dev/null 2>&1 &
          else setsid #{@bin}/claude -c 'sleep 300; :' --plugin-dir "$pd" --remote-control "$2" >/dev/null 2>&1 & fi
          echo $! >> #{@pids}; echo $! > #{@base}/pane.pid; date +%s.%N > #{@base}/started_at; exit 0 ;;
        list-panes) [ -e #{@base}/pane.pid ] && cat #{@base}/pane.pid && exit 0; exit 1 ;;
        kill-session) [ -e #{@base}/nokill ] && echo "server busy" >&2 && exit 1; exit 0 ;;
        has-session) grep -qx -- "$3" #{@base}/alive 2>/dev/null && exit 0
          [ -e #{@base}/nokill ] && [ -e #{@base}/pane.pid ] && exit 0; exit 1 ;;
        ls) [ -e #{@base}/ls ] && cat #{@base}/ls && exit 0; [ -e #{@base}/ls_err ] && cat #{@base}/ls_err >&2; exit 1 ;;
        display-message) exit 1 ;;
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
    File.readlines(@pids).each { |p| Process.kill("TERM", -p.to_i) rescue nil } if File.exist?(@pids) # each pane's group
    Process.kill("TERM", @pid) if @pid
    Process.wait(@pid) if @pid
    FileUtils.rm_rf(@base)
  end

  def write_config(start_seconds)
    launch = { "trusted_paths" => [], "commands" => INVOCATIONS, "start_seconds" => start_seconds }.compact
    launch["scopes"] = nil # no systemd user manager in the sandbox
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(
      "roots" => [{ "path" => "/projects", "prefix" => "" }], "search_depth" => 2,
      "owner_remotes" => ["github.com/you/"], "author_emails" => ["you@example.com"], "window_days" => 7,
      "reap_protect" => [], "auth" => { "provider" => "none" }, "agents" => { "collector" => "none" }, "dictation" => "none",
      "terminal" => { "public_host" => "deny", "max_open" => 4 },
      "ci" => { "max_pending_minutes" => 60, "required" => { "o/r" => ["jenkins/ci"] } },
      "skills" => { "max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil },
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
    env = { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "HERMES_HOME" => @hermes_home, "HOME" => @home,
            "GIT_SSH_COMMAND" => "false", "GIT_TEMPLATE_DIR" => "/nowhere",
            "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "protocol.file.allow", "GIT_CONFIG_VALUE_0" => "always", }
    @pid = Process.spawn(env, RbConfig.ruby, File.join(@co, "bin/launcher"), %i[out err] => [@log, "w"])
    sock = File.join(@base, "run/launcher.sock")
    # its boot (ruby + the engine) took > 10 s on the CI host under load (66 test workers, load 60 on 20 CPUs): wait
    # for the socket to accept a connection, or the process's exit, up to BOOT_SECONDS. The file alone is not enough:
    # UNIXServer.new binds (the file appears) before it listens, and a connect in between is refused
    Wait.for(-> { "the launcher's socket: #{File.read(@log)}" }, seconds: BOOT_SECONDS, every: 0.1) do
      flunk "the launcher exited: #{File.read(@log)}" if Process.waitpid(@pid, Process::WNOHANG)
      accepting?(sock)
    end
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
        "launcher" => "fullclaude", "lead_key" => LEAD_KEY, "settings" => { "id" => 1, "doc" => AGENTS },
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
      threads = [Thread.new { ask(clone) }, Thread.new { Thread.pass; ask(init) }]
      results = threads.map(&:value)
      assert_operator results.count { |x| x["ok"] }, :<=, 1, "#{name}: #{results.inspect}"
    end
    Wait.for("the clone jobs to end", seconds: 10, every: 0.1) { ask("op" => "jobs")["jobs"].all? { |j|
 j["status"] != "running" } }
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
    Wait.for("the clone job to end", seconds: 5, every: 0.1) { ask("op" => "jobs")["jobs"].all? { |j|
 j["status"] != "running" } }
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

  # A claude_code launch hands its session busyyaks's skills for its type through --plugin-dir <stage> (a
  # copy under LAUNCHER_STATE_DIR, 0700) and a prompt opening with /busyyaks:session; --remote-control stays last
  def test_a_claude_launch_carries_its_staged_skills
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    r = launch("fresh")
    assert r["ok"], r.inspect
    stage = File.join(@base, "state/skills/fresh_s")
    argv = Shellwords.split(File.read(File.join(@base, "command")).chomp.delete_suffix("; exec bash"))
    i = argv.index("--plugin-dir")
    assert_equal stage, argv[i + 1]
    assert argv[i + 2].start_with?("/busyyaks:session Test lead session for fresh"), argv.inspect
    assert_equal ["--remote-control", "fresh_s"], argv.last(2)
    assert_equal %w[workflow lead reviewer session], r["skills"].map { |k| k["name"] }
    assert_equal "none", r["project_skills"]
    assert_equal 0o700, File.stat(stage).mode & 0o777
    assert_equal({ "name" => "busyyaks" }, JSON.parse(File.read(File.join(stage, ".claude-plugin/plugin.json"))))
    entry = File.read(File.join(stage, "skills/session/SKILL.md"))
    assert_includes entry, "## workflow (busyyaks)"
    assert_includes entry, "## lead (busyyaks)"
    assert_includes entry, "`busyyaks:reviewer`", "an on-demand skill is listed by its plugin name"
    refute_includes entry, "## reviewer"
    refute File.exist?(File.join(stage, "skills/author")), "a worker's skill is not a lead's"
    assert_match(/skills workflow\(busyyaks,start,\h{12}\)/, File.read(@log))
    assert_empty Dir.children(@home), "nothing installed user-wide (no ~/.claude/skills, no plugin install)"
  end

  # a skill dir the manifest names is missing: refused before tmux starts anything, no stage left
  def test_a_launch_with_a_broken_skill_set_is_refused_before_it_starts
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    FileUtils.rm_rf(File.join(@co, "skills/lead"))
    File.write(@tmux_log, "")
    r = launch("fresh")
    refute r["ok"], r.inspect
    assert_match(%r{\Askills: .*/skills: lead named in .*manifest.yml but missing}, r["error"])
    refute_includes tmux_calls, "new-session", "nothing started"
    refute File.exist?(File.join(@base, "state/skills/fresh_s"))
  end

  # an agent that comes up WITHOUT the stage (a launcher function dropping the extra flags): refused, killed, stage gone
  def test_an_agent_up_without_its_skills_is_refused
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    FileUtils.touch(@noplugin)
    r = launch("fresh")
    refute r["ok"], r.inspect
    assert_match(/\Afresh_s did not start: the agent runs without its skills: no --plugin-dir /, r["error"])
    assert_match(/kill-session -t =fresh_s/, tmux_calls)
    refute File.exist?(File.join(@base, "state/skills/fresh_s"))
  end

  # a stage lives while its session does: the next launch removes the stage of a session tmux no longer lists
  def test_the_stage_of_an_ended_session_is_removed
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    ask("op" => "create", "root" => "/projects", "name" => "two", "url" => "")
    assert launch("fresh")["ok"]
    assert File.directory?(File.join(@base, "state/skills/fresh_s"))
    File.write(File.join(@base, "ls"), "") # tmux ls: fresh_s is gone
    FileUtils.rm_f(File.join(@base, "pane.pid"))
    assert launch("two")["ok"]
    refute File.exist?(File.join(@base, "state/skills/fresh_s"))
    assert File.directory?(File.join(@base, "state/skills/two_s"))
  end

  # the notifier's watch pass asks `sessions`: a stage goes within a pass of its session's end
  def test_the_sessions_op_removes_the_stage_of_an_ended_session
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    assert launch("fresh")["ok"]
    File.write(File.join(@base, "ls"), "") # tmux ls: fresh_s is gone
    assert ask("op" => "sessions")["ok"]
    refute File.exist?(File.join(@base, "state/skills/fresh_s"))
    assert_match(/skills sweep \(sessions\): removed fresh_s/, File.read(@log))
  end

  # tmux unreadable (ls fails, not "no server"): nothing removed, and the log says the sweep was skipped and why
  def test_a_failed_tmux_ls_never_removes_a_stage
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    assert launch("fresh")["ok"]
    FileUtils.rm_f(File.join(@base, "ls")) # the stub's ls exits 1, no output
    ask("op" => "sessions")
    assert File.directory?(File.join(@base, "state/skills/fresh_s"))
    assert_match(/skills sweep skipped \(sessions\): tmux ls failed: no output/, File.read(@log))
  end

  # tmux's real "no server" answers (no server running / the socket missing) = no sessions: the stage goes; any other
  # error (a socket it may not open: Permission denied) = tmux unreadable: kept, the skip logged
  def test_only_a_real_no_server_answer_counts_as_no_sessions
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    assert launch("fresh")["ok"]
    stage = File.join(@base, "state/skills/fresh_s")
    FileUtils.rm_f(File.join(@base, "ls"))
    File.write(File.join(@base, "ls_err"), "error connecting to /tmp/tmux-1000/default (Permission denied)\n")
    ask("op" => "sessions")
    assert File.directory?(stage)
    assert_match(/skills sweep skipped \(sessions\): tmux ls failed: error connecting to .*\(Permission denied\)/,
File.read(@log))
    ["no server running on /tmp/tmux-1000/default", "error connecting to /tmp/tmux-1000/default (No such file or directory)"]
      .each do |msg|
        FileUtils.mkdir_p(stage)
        File.write(File.join(@base, "ls_err"), "#{msg}\n")
        ask("op" => "sessions")
        refute File.exist?(stage), msg
      end
  end

  def project_skill(repo, types:)
    base = File.join(@projects, repo, ".busyyaks")
    FileUtils.mkdir_p(File.join(base, "skills/deploy"))
    File.write(File.join(base, "skills.yml"),
YAML.dump("version" => 1, "skills" => { "deploy" => { "types" => types, "load" => "start" } }))
    File.write(File.join(base, "skills/deploy/SKILL.md"),
"---\nname: deploy\ndescription: how this repo deploys\n---\nRun make deploy.\n")
  end

  # a TRUSTED repo's own .busyyaks skills load for the type they name, after busyyaks's
  def test_a_trusted_repos_own_skills_load
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    project_skill("fresh", types: ["lead"])
    r = launch("fresh")
    assert r["ok"], r.inspect
    assert_equal "loaded", r["project_skills"]
    assert_equal [%w[deploy project]], r["skills"].select { |k|
 k["source"] == "project" }.map { |k| k.values_at("name", "source") }
    entry = File.read(File.join(@base, "state/skills/fresh_s/skills/session/SKILL.md"))
    assert_operator entry.index("## lead (busyyaks)"), :<, entry.index("## deploy (project)")
  end

  # an UNTRUSTED repo's .busyyaks skills are left (never read); the launch runs on busyyaks's and says why
  def test_an_untrusted_repos_skills_are_left
    planted("planted")
    project_skill("planted", types: ["lead"])
    r = launch("planted")
    assert r["ok"], r.inspect
    assert_match(/\Aleft: .* is not in config\/busyyaks.yml launch.trusted_paths/, r["project_skills"])
    refute(r["skills"].any? { |k| k["source"] == "project" })
  end

  # hermes: a config without the external_dirs line → hermes (asked in the session's env) lists no busyyaks-session:
  # refused with the file and the line to add, the session killed
  def test_a_hermes_launch_without_the_external_dirs_line_is_refused
    File.write(File.join(@hermes_home, "config.yaml"), YAML.dump("skills" => { "external_dirs" => [] }))
    FileUtils.touch(@hermes)
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    hermes = { "key" => "hermes", "label" => "hermes", "kind" => "hermes", "command" => "hermes", "args" => ["chat"],
               "via_shell" => false, }
    types = AGENTS["agent_types"].map do |t|
      next t unless t["key"] == "plain"

      t.merge("launchers" => t["launchers"] + ["hermes"],
              "model" => t["model"].is_a?(Hash) ? t["model"].merge("hermes" => nil) : t["model"])
    end
    doc = AGENTS.merge("launchers" => AGENTS["launchers"] + [hermes], "agent_types" => types)
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "fresh_s", "type" => "plain", "launcher" => "hermes",
            "settings" => { "id" => 3, "doc" => doc },
            "vars" => { "slug" => "fresh", "session" => "fresh_s", "agent" => "a", "type" => "plain", "cards" => "-" })
    refute r["ok"], r.inspect
    assert_match(/the agent runs without its skills: hermes does not list busyyaks-session-\h{12}: /, r["error"])
    assert_includes r["error"], "#{@hermes_home}/config.yaml needs `- ${BUSYYAKS_SKILLS_DIR}/busyyaks-skills`"
    assert_match(/kill-session -t =fresh_s/, tmux_calls)
    refute File.exist?(File.join(@base, "state/skills/fresh_s"))
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

  # a launch runs the agent settings revision it carries, and only commands on launch.commands — a revision
  # naming any other command (written from the dashboard) is refused before tmux starts anything; none carried → refused
  def test_a_revision_with_a_command_off_the_host_allowlist_is_refused_before_tmux
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    launchers = AGENTS["launchers"].map { |l| l["key"] == "fullclaude" ? l.merge("command" => "bash") : l }
    doc = AGENTS.merge("launchers" => launchers)
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "fresh_s", "type" => "lead", "launcher" => "fullclaude",
            "lead_key" => LEAD_KEY,
            "settings" => { "id" => 7, "doc" => doc },
            "vars" => { "slug" => "fresh", "session" => "fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
    refute r["ok"], r.inspect
    assert r["error"].start_with?("agent settings revision 7: launcher fullclaude " \
                                  "(claude_code: bash --permission-mode bypassPermissions): not an invocation on this " \
                                  "host's allowlist config/busyyaks.yml launch.commands"), r["error"]
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "fresh_s", "type" => "lead", "launcher" => "fullclaude",
            "lead_key" => LEAD_KEY,
            "vars" => { "slug" => "fresh", "session" => "fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
    assert_match(/settings \{id, doc\} are required/, r["error"])
    # a prompt starting with "-" (an option of the allowlisted command) is refused before tmux too
    types = AGENTS["agent_types"].map { |t| t["key"] == "lead" ? t.merge("prompt" => "--mcp-config=/tmp/x {slug}") : t }
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "fresh_s", "type" => "lead", "launcher" => "fullclaude",
            "lead_key" => LEAD_KEY,
            "settings" => { "id" => 8, "doc" => AGENTS.merge("agent_types" => types) },
            "vars" => { "slug" => "fresh", "session" => "fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
    assert_match(/agent settings revision 8: agent_types\[lead\].prompt must not start with "-"/, r["error"])
    refute_includes tmux_calls, "new-session", "nothing was started"
  end

  # a hermes launcher (kind hermes): the prompt goes as -q, no trust prompt is answered (it is Claude Code's), and the
  # start counts as up when the pane runs hermes — there is no remote control to wait for
  def test_a_hermes_launch_is_up_when_its_pane_runs_hermes
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    FileUtils.touch(@hermes)
    hermes = { "key" => "hermes", "label" => "hermes", "kind" => "hermes", "command" => "hermes", "args" => ["chat"],
               "via_shell" => false, }
    # the lead on hermes (a prompted type; a standalone one has no prompt): every type under it runs hermes too
    types = AGENTS["agent_types"].map do |t|
      n = t.merge("launchers" => t["launchers"] + ["hermes"],
                  "model" => t["model"].is_a?(Hash) ? t["model"].merge("hermes" => nil) : t["model"])
      t["key"] == "lead" ? n.merge("prompt" => "work on {slug}") : n
    end
    doc = AGENTS.merge("launchers" => AGENTS["launchers"] + [hermes], "agent_types" => types)
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "fresh_s", "type" => "lead", "launcher" => "hermes",
            "lead_key" => LEAD_KEY, "settings" => { "id" => 3, "doc" => doc },
            "vars" => { "slug" => "fresh", "session" => "fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
    assert_equal [true, "hermes", "on", "hermes"], r.values_at("ok", "kind", "process", "process_name"), r.inspect
    refute r.key?("remote_control"), r.inspect
    started = tmux_calls.lines.find { |l| l.start_with?("new-session") }
    token = started[/-s busyyaks-session-(\h{12}) /, 1]
    refute_nil token, started
    assert_match(/hermes chat -s busyyaks-session-#{token} -q work\\ on\\ fresh/, started)
    stage = File.join(@base, "state/skills/fresh_s")
    assert_includes started, "-e BUSYYAKS_SKILLS_DIR=#{stage} ", "the stage reaches hermes through this session's env only"
    entry = File.join(stage, "busyyaks-skills/busyyaks-session-#{token}/SKILL.md")
    assert_match(/\A---\nname: busyyaks-session-#{token}\n/, File.read(entry))
    assert File.file?(File.join(stage, "busyyaks-skills/busyyaks-workflow-#{token}/SKILL.md"))
    assert_equal %w[workflow lead reviewer session], r["skills"].map { |k| k["name"] }, "lead: its skills + the entry skill"
    refute_match(/--remote-control/, started)
    refute_match(/send-keys/, tmux_calls, "no trust prompt answered for hermes")
  end

  # the start check waits on the REAL signal, not a fixed window — a planted repo (trust left: no trust wait)
  def planted(name)
    Open3.capture3("git", "init", "-q", File.join(@projects, name))
  end

  # bin/launcher refuses a bare pane after BARE_CHECKS looks 1 s apart: the seconds it reports are at least that many
  # sleeps (its start clock floors)
  BARE_SLEEPS = File.read(File.expand_path("../../bin/launcher", __dir__))[/^BARE_CHECKS = (\d+)$/, 1].to_i - 1

  # a refusal "at once": the command-exited reason (never the start_seconds one), and the seconds it names are the
  # launch's own clock, bounded from below on both sides — at least the launcher's own sleeps, and the call took at
  # least that long (no upper bound on real time, which a loaded runner breaks: 3.02 s against a 3 s bound
  # in one run)
  def assert_refused_at_once(session, &launch)
    reported = ->(r) { r["error"][/the command exited after (\d+)s/, 1].to_i }
    r = Elapsed.at_least(reported, "the error's seconds are the launch's clock", &launch)
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    m = r["error"].match(/\A#{session} did not start: the command exited after (\d+)s, no claude --remote-control #{session}: /)
    assert m, r["error"]
    assert_operator m[1].to_i, :>=, BARE_SLEEPS, "the reported seconds are the launch's clock, not a constant: #{r['error']}"
    refute_match(/launch\.start_seconds/, r["error"], "refused on the exit, not after the start wait")
    r
  end

  # a wrapper (a shell function starting a gateway, an ssh forward) that works longer than the old fixed 12 s, then
  # execs claude --remote-control: up, kept
  def test_a_slow_wrapper_that_then_starts_claude_is_ok
    planted("slow")
    File.write(@pane, "sleep 13; exec #{@bin}/claude -c 'sleep 300; :' --plugin-dir \"$2\" --remote-control \"$1\"\n")
    r = Elapsed.at_least(12, "the wrapper's 13 s were waited out") { launch("slow") }
    assert_equal [true, "on", "slow_s"], r.values_at("ok", "remote_control", "remote_control_name"), r.inspect
    refute_includes tmux_calls, "kill-session"
  end

  # the command exited into the pane's bare shell: refused at once (3 checks), well before launch.start_seconds
  def test_a_command_that_exits_at_once_is_refused_fast_with_the_pane_tail
    planted("gone")
    File.write(@refuse, "")
    r = assert_refused_at_once("gone_s") { launch("gone") }
    assert_match(/: Temp directory/, r["error"])
    assert_match(/kill-session -t =gone_s/, tmux_calls)
  end

  # a command that keeps working and never starts claude: refused once launch.start_seconds passed
  def test_a_command_that_never_starts_claude_is_refused_after_start_seconds
    restart(4)
    planted("stuck")
    File.write(@pane, "sleep 30; :\n")
    r = Elapsed.at_least(4, "launch.start_seconds 4 waited out") { launch("stuck") }
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    m = r["error"].match(/\Astuck_s did not start: no claude --remote-control stuck_s after (\d+)s \(launch.start_seconds 4\)/)
    assert m, r["error"]
    assert_operator m[1].to_i, :>=, 4
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

  # lead-first boards, checked by the launcher itself: a lead's key is kept in the launcher's state
  # (leads.json, with its session, type and repo dir) — never in the tmux session, the log or an answer but the
  # lead_key op's; a worker starts only under a lead THIS launcher started for the same repo dir, while it runs
  def test_the_launcher_keeps_the_lead_key_and_a_worker_needs_its_own_boards_running_lead
    %w[fresh other].each { |n| ask("op" => "create", "root" => "/projects", "name" => n, "url" => "") }
    r = launch("fresh")
    assert r["ok"], r.inspect
    refute_includes tmux_calls, LEAD_KEY, "never in the tmux session (no -e, no env)"
    refute_includes File.read(@log), LEAD_KEY, "never logged"
    refute_includes JSON.generate(r), LEAD_KEY, "never answered"
    leads = JSON.parse(File.read(File.join(@base, "state/leads.json")))
    assert_equal [["fresh_s", "lead", File.realpath(File.join(@projects, "fresh")), LEAD_KEY]],
                 leads.map { |e| e.values_at("session", "type", "dir", "key") }
    assert_equal "600", format("%o", File.stat(File.join(@base, "state/leads.json")).mode & 0o777)
    assert_match(/fresh_s: its tmux session is not running/, ask("op" => "lead_key", "session" => "fresh_s")["error"])
    File.write(File.join(@base, "alive"), "=fresh_s\n")
    assert_equal [true, LEAD_KEY], ask("op" => "lead_key", "session" => "fresh_s").values_at("ok", "key")
    assert_match(/nobody: no lead this launcher started/, ask("op" => "lead_key", "session" => "nobody")["error"])
    File.write(@tmux_log, "")
    vars = ->(dir, s, t) { { "slug" => dir, "session" => s, "agent" => "a", "type" => t, "cards" => "-" } }
    req = lambda do |dir, s, t, over = {}|
      ask({ "op" => "launch", "path" => "/projects/#{dir}", "launcher" => "fullclaude", "session" => s, "type" => t,
            "settings" => { "id" => 1, "doc" => AGENTS }, "vars" => vars.(dir, s, t), }.merge(over))
    end
    assert_match(/needs its lead key/, req.("fresh", "l2", "lead")["error"])
    assert_match(/needs its lead key/, req.("fresh", "l2", "lead", "lead_key" => "x")["error"])
    assert_match(/runs under no lead/, req.("fresh", "l2", "lead", "lead_key" => LEAD_KEY, "lead" => "fresh_s")["error"])
    assert_match(/runs under the board's lead: no lead session given/, req.("fresh", "w1", "worker")["error"])
    assert_match(/gone_s is no lead this launcher started/, req.("fresh", "w1", "worker", "lead" => "gone_s")["error"])
    assert_match(%r{fresh_s leads .*/fresh, not .*/other: a session runs under its own board's lead},
                 req.("other", "w1", "worker", "lead" => "fresh_s")["error"])
    assert_match(/a plain session gets no lead key/, req.("fresh", "p1", "plain", "lead_key" => LEAD_KEY)["error"])
    # a revision with a worker under no lead does not even load (review round 1, blocker)
    leaderless = AGENTS.merge("agent_types" => AGENTS["agent_types"].map { |t| t["key"] == "worker" ? t.except("under") : t })
    r = req.("fresh", "w1", "worker", "lead" => "fresh_s", "settings" => { "id" => 9, "doc" => leaderless })
    assert_match(/agent settings revision 9: .*agent_types\[worker\] runs without a lead/, r["error"])
    refute_includes tmux_calls, "new-session", "nothing was started"
    r = req.("fresh", "w1", "worker", "lead" => "fresh_s")
    assert r["ok"], r.inspect
    refute_includes tmux_calls, LEAD_KEY
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
    # the trust wait (15 s) ended on the bare shell: refused on the exit, never on the trust wait's end
    r = assert_refused_at_once("tgone_s") { launch("tgone") }
    refute_match(/trust/i, r["error"])
    refute_includes tmux_calls, "Enter", "nothing answered on a pane that is a bare shell"
  end

  # a TRUSTED repo whose wrapper works longer than the trust wait, then starts claude: its prompt answered, up, kept
  def test_a_trusted_repo_with_a_slow_wrapper_is_ok
    ask("op" => "create", "root" => "/projects", "name" => "tslow", "url" => "")
    File.write(@pane, "sleep 13; exec #{@bin}/claude -c 'sleep 300; :' --plugin-dir \"$2\" --remote-control \"$1\"\n")
    r = Elapsed.at_least(12, "the wrapper's 13 s were waited out") { launch("tslow") }
    assert_equal [true, "accepted", "on", "tslow_s"], r.values_at("ok", "trust", "remote_control", "remote_control_name"),
                 r.inspect
    refute_includes tmux_calls, "kill-session"
  end
end
