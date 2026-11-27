# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/wait"
require_relative "../support/auto_loaded"
require_relative "../../lib/busyyaks/clock"
require_relative "../../lib/busyyaks/hermes_board"
require_relative "../../lib/busyyaks/agent_presets"
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
  MCP_TOKEN = "cd" * 32
  BOARD_TOKEN = "ef" * 32
  # the host allowlist (launch.commands): the fixture's by_two launchers + a hermes one
  INVOCATIONS = [*YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands"),
                 { "kind" => "hermes", "command" => "hermes", "args" => ["chat"], "via_shell" => false },].freeze
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60 # the launcher's start, until its socket exists
  # launch.start_seconds of the sandbox: far above the 13 s a slow wrapper below takes, so a refusal "at
  # once" is told from one on the clock by its reason and its distance from this, never by the machine's speed
  START_SECONDS = 120
  COPY = %w[bin/launcher lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml config/harnesses.yml skills
            config/agent_presets.yml].freeze

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
      MCP_HOST=127.0.0.1
      MCP_HOST_PORT=8081
      MCP_TOKEN=#{MCP_TOKEN}
      MCP_BOARD_TOKEN=#{BOARD_TOKEN}
    ENV
    # tmux: records every call; the pane shows Claude Code's trust prompt until Enter is pressed on it. new-session
    # starts the pane's process: a `claude --remote-control <session>` (a copy of bash named claude, so /proc shows
    # that argv), or — with the `refuse` file present — a bare shell, as when claude refused to start
    entered = File.join(@base, "entered")
    @refuse = File.join(@base, "refuse")
    @pids = File.join(@base, "pids")
    @pane = File.join(@base, "pane.sh") # a pane command of a test's own: `sh pane.sh <session>`
    @dialog = File.join(@base, "dialog") # the pane shows a permission dialog
    # the pane draws Claude Code's trust prompt as it does today: unnumbered, the cursor on the choice the
    # trust_cursor file names (no = "No, exit", the default; yes), moved by send-keys Up / Down
    @trust_ui = File.join(@base, "trust_ui")
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
      # `hermes config`: what its overlay (HERMES_MANAGED_DIR) sets, read as the real one resolves it
      if [ "$1" = config ]; then
        [ "$2" = path ] && { echo "$HERMES_HOME/config.yaml"; exit 0; }
        [ -n "$HERMES_MANAGED_DIR" ] || { echo unset; exit 0; }
        case "$3" in
          display.busy_input_mode) echo queue ;; display.language) echo en ;; display.skin) echo default ;;
          tools.tool_search.enabled) echo false ;; mcp_servers.busyyaks.enabled) echo true ;;
          paste_collapse_char_threshold) echo 1 ;;
          mcp_servers.busyyaks.url) sed -n 's/^ *url: *//p' "$HERMES_MANAGED_DIR/config.yaml" ;;
        esac
        exit 0
      fi
      sleep 300
    SH
    File.chmod(0o755, File.join(@bin, "hermes"))
    @hermes = File.join(@base, "hermes_mode")
    # a process named hermes that is NOT the allowlisted program: it records any run other than the pane's own
    @pane_hermes = File.join(@base, "pane-bin/hermes")
    @pane_hermes_ran = File.join(@base, "pane-hermes-ran")
    @noplugin = File.join(@base, "noplugin") # a launcher command that drops the extra flags
    @nomcp = File.join(@base, "nomcp") # a launcher command that drops --mcp-config: no board MCP
    # hermes reads its skills from config.yaml skills.external_dirs: the inert line busyyaks's launch env fills
    @home = File.join(@base, "home") # the launcher's HOME: a launch writes nothing user-wide into it
    FileUtils.mkdir_p(@home)
    @hermes_home = File.join(@base, "hermes-home")
    FileUtils.mkdir_p(@hermes_home)
    File.write(File.join(@hermes_home, "config.yaml"),
               YAML.dump("skills" => { "external_dirs" => ["${BUSYYAKS_SKILLS_DIR}/busyyaks-skills"] },
                         "mcp_servers" => { "busyyaks" => { "enabled" => false } }))
    stub("tmux", <<~SH)
      echo "$*" >> #{@tmux_log}
      case "$1" in
        new-session)
          # the command the launcher typed (the last word) and its per-session env (-e K=V): the stub agent gets the
          # same --plugin-dir / BUSYYAKS_SKILLS_DIR the real one would (the launcher reads them off /proc)
          for a; do cmd=$a; done
          pd=$(printf '%s' "$cmd" | sed -nE 's/.*--plugin-dir ([^ ]+).*/\\1/p')
          mc=$(printf '%s' "$cmd" | sed -nE 's/.*--mcp-config ([^ ]+).*/\\1/p')
          printf '%s\n' "$cmd" > #{@base}/command
          for a; do case "$a" in BUSYYAKS_SKILLS_DIR=*|HERMES_MANAGED_DIR=*|HERMES_LANGUAGE=*) export "$a" ;; esac; done
          while [ "$1" != -s ]; do shift; done
          # each pane its own process group (setsid): teardown ends the whole group, its `sleep`s too — a TERM to the
          # pane's shell alone left them running 300 s (the flake gate's repeats ran out of tasks)
          if [ -e #{@pane} ]; then setsid sh #{@pane} "$2" "$pd" "$mc" >/dev/null 2>&1 &
          elif [ -e #{@refuse} ]; then setsid sleep 300 >/dev/null 2>&1 &
          elif [ -e #{@pane_hermes} ]; then setsid #{@pane_hermes} chat >/dev/null 2>&1 &
          elif [ -e #{@hermes} ]; then setsid #{@bin}/hermes chat >/dev/null 2>&1 &
          elif [ -e #{@noplugin} ]; then setsid #{@bin}/claude -c 'sleep 300; :' --mcp-config "$mc" --remote-control "$2" >/dev/null 2>&1 &
          elif [ -e #{@nomcp} ]; then setsid #{@bin}/claude -c 'sleep 300; :' --plugin-dir "$pd" --remote-control "$2" >/dev/null 2>&1 &
          else setsid #{@bin}/claude -c 'sleep 300; :' --mcp-config "$mc" --plugin-dir "$pd" --remote-control "$2" >/dev/null 2>&1 & fi
          echo $! >> #{@pids}; echo $! > #{@base}/pane.pid; echo "$2" > #{@base}/pane.name; date +%s.%N > #{@base}/started_at; exit 0 ;;
        # `list-panes -a -F <name>\t<pid>` (the launch's record of its pane, launched?): the one pane's session + pid
        list-panes) [ -e #{@base}/pane.pid ] || exit 1
          if [ "$2" = -a ]; then printf '%s\t%s\n' "$(cat #{@base}/pane.name)" "$(cat #{@base}/pane.pid)"; else cat #{@base}/pane.pid; fi
          exit 0 ;;
        kill-session) [ -e #{@base}/nokill ] && echo "server busy" >&2 && exit 1; exit 0 ;;
        has-session) grep -qx -- "$3" #{@base}/alive 2>/dev/null && exit 0
          [ -e #{@base}/nokill ] && [ -e #{@base}/pane.pid ] && exit 0; exit 1 ;;
        # `ls`: the names in the ls file; the sessions op's tab-separated format gets each name a path outside the root
        ls) if [ -e #{@base}/ls ]; then
              case "$*" in *"$(printf '\\t')"*) sed 's|$|\\t/elsewhere\\t1\\t0|' #{@base}/ls ;; *) cat #{@base}/ls ;; esac
              exit 0
            fi
            [ -e #{@base}/ls_err ] && cat #{@base}/ls_err >&2; exit 1 ;;
        display-message) exit 1 ;;
        capture-pane)
          if [ -e #{@base}/quoting ]; then
            printf '%s\\n' "Run: echo 'Yes, I trust this folder'?" "❯ 1. Yes" "  2. No" "Enter to confirm · Esc to cancel"
          elif [ -e #{@dialog} ]; then printf '%s\\n' "Do you want to proceed?" "❯ 1. Yes" "Enter to confirm · Esc to cancel"
          elif [ -e #{@refuse} ]; then echo "Temp directory /tmp/claude-1000 is owned by uid 0, expected 1000."; echo '$ '
          elif [ -e #{entered} ]; then echo "> "
          elif [ -e #{@trust_ui} ]; then
            if [ "$(cat #{@base}/trust_cursor 2>/dev/null)" = yes ]; then n='  '; y='❯ '; else n='❯ '; y='  '; fi
            printf '%s\n' " Accessing workspace:" "" " /projects/planted" "" " Quick safety check: Is this a project you created or one you trust?" "" \
              " ${n}No, exit" " ${y}Yes, I trust this folder" "" " Enter to confirm · Esc to cancel"
          else
            printf '%s\\n' "Do you trust the files in this folder?" "❯ 1. Yes, I trust this folder" "  2. No, exit"
          fi
          exit 0 ;;
        send-keys) case " $* " in *" Enter "*) [ -e #{@base}/deaf ] || touch #{entered} ;; *" Down "*) echo yes > #{@base}/trust_cursor ;;
            *" Up "*) echo no > #{@base}/trust_cursor ;; esac; exit 0 ;;
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

  # scopes: nil = no systemd user manager in the sandbox (card 463); a test of the scope sweep gives its own
  def write_config(start_seconds, scopes: nil)
    launch = { "trusted_paths" => [], "commands" => INVOCATIONS, "start_seconds" => start_seconds }.compact
    launch["scopes"] = scopes
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(
      "roots" => [{ "path" => "/projects", "prefix" => "" }], "search_depth" => 2,
      "owner_remotes" => ["github.com/you/"], "author_emails" => ["you@example.com"], "window_days" => 7,
      "reap_protect" => [], "auth" => { "provider" => "none" }, "agents" => { "collector" => "none" },
      "terminal" => { "public_host" => "deny", "max_open" => 4 }, "github_hook" => "none",
      "ci" => { "max_pending_minutes" => 60, "required" => { "o/r" => ["jenkins/ci"] } },
      "skills" => { "max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil },
      "launch" => launch
    ))
  end

  def restart(start_seconds, scopes: nil)
    Process.kill("TERM", @pid)
    Process.wait(@pid)
    @pid = nil
    write_config(start_seconds, scopes: scopes)
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
    ask("op" => "launch", "path" => "/projects/#{name}", "session" => "by_#{name}_s", "type" => "lead",
        "launcher" => "fullclaude", "lead_key" => LEAD_KEY, "settings" => { "id" => 1, "doc" => AGENTS },
        "vars" => { "slug" => name, "session" => "by_#{name}_s", "agent" => "a", "type" => "lead", "cards" => "-" })
  end

  def tmux_calls = File.exist?(@tmux_log) ? File.read(@tmux_log) : ""

  # the trust prompt on the pane: pressed for a repo the launcher made, left for any other
  def test_the_trust_prompt_is_pressed_only_for_a_trusted_repo
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    r = launch("fresh")
    assert_equal "accepted", r["trust"], r.inspect
    assert_match(/send-keys -t =by_fresh_s: Enter/, tmux_calls)
    FileUtils.rm_f(File.join(@base, "entered"))
    File.write(@tmux_log, "")
    Open3.capture3("git", "init", "-q", File.join(@projects, "planted"))
    r = launch("planted")
    assert_equal "left", r["trust"], r.inspect
    assert_includes tmux_calls, "new-session"
    refute_includes tmux_calls, "Enter", "nothing pressed for a repo the launcher did not make"
  end

  # an untrusted repo's trust prompt (unnumbered choices) is a dialog the operator answers from the page —
  # the launcher moves the cursor onto the chosen label, read back off the screen, then presses Enter; a stale hash or a
  # key that is no choice types nothing
  def test_the_operator_answers_an_untrusted_repos_trust_prompt
    FileUtils.touch(@trust_ui)
    Open3.capture3("git", "init", "-q", File.join(@projects, "planted"))
    r = launch("planted")
    assert_equal "left", r["trust"], r.inspect
    refute_match(/send-keys/, tmux_calls, "nothing pressed at the launch")
    File.write(File.join(@base, "alive"), "=by_planted_s\n")

    d = ask("op" => "dialog", "session" => "by_planted_s")["dialog"]
    assert_equal [["1", "No, exit"], ["2", "Yes, I trust this folder"]], d["options"].map { |o| [o["key"], o["label"]] }
    assert_equal "/projects/planted", d["command"]
    refute d.key?("cursor"), "the cursor is the launcher's, never shown"

    %w[esc 3].each do |key|
      a = ask("op" => "answer", "session" => "by_planted_s", "hash" => d["hash"], "key" => key)
      refute a["ok"], a.inspect
    end
    a = ask("op" => "answer", "session" => "by_planted_s", "hash" => "0" * 64, "key" => "2")
    assert_match(/changed — nothing typed/, a["error"])
    refute_match(/send-keys/, tmux_calls, "nothing typed for a refused answer")

    a = ask("op" => "answer", "session" => "by_planted_s", "hash" => d["hash"], "key" => "2")
    assert a["ok"], a.inspect
    keys = tmux_calls.lines.grep(/send-keys/).map { |l| l.split.last }
    assert_equal %w[Down Enter], keys
    assert_match(/answer by_planted_s: trust prompt "Yes, I trust this folder" pressed/, File.read(@log))
  end

  # the cursor on "Yes": choosing "No, exit" steps it Up first (review round 1)
  def test_no_with_the_cursor_on_yes_steps_up
    FileUtils.touch(@trust_ui)
    File.write(File.join(@base, "trust_cursor"), "yes\n")
    Open3.capture3("git", "init", "-q", File.join(@projects, "planted"))
    launch("planted")
    File.write(File.join(@base, "alive"), "=by_planted_s\n")
    d = ask("op" => "dialog", "session" => "by_planted_s")["dialog"]
    assert ask("op" => "answer", "session" => "by_planted_s", "hash" => d["hash"], "key" => "1")["ok"]
    assert_equal %w[Up Enter], tmux_calls.lines.grep(/send-keys/).map { |l| l.split.last }
  end

  # a prompt that stays on screen after Enter (claude ignored the key): the answer fails, said
  def test_a_trust_prompt_still_on_screen_after_enter_is_a_failed_answer
    FileUtils.touch(@trust_ui)
    FileUtils.touch(File.join(@base, "deaf"))
    Open3.capture3("git", "init", "-q", File.join(@projects, "planted"))
    launch("planted")
    File.write(File.join(@base, "alive"), "=by_planted_s\n")
    d = ask("op" => "dialog", "session" => "by_planted_s")["dialog"]
    a = ask("op" => "answer", "session" => "by_planted_s", "hash" => d["hash"], "key" => "1")
    refute a["ok"], a.inspect
    assert_match(/still on screen after Enter/, a["error"])
  end

  # a numbered permission dialog that merely QUOTES the trust choices is answered as that dialog (review round 1)
  def test_a_numbered_dialog_quoting_the_trust_phrase_is_answered_as_itself
    Open3.capture3("git", "init", "-q", File.join(@projects, "planted"))
    launch("planted")
    File.write(File.join(@base, "alive"), "=by_planted_s\n")
    FileUtils.rm_f(File.join(@base, "entered"))
    File.write(File.join(@base, "quoting"), "")
    File.write(@tmux_log, "")
    d = ask("op" => "dialog", "session" => "by_planted_s")["dialog"]
    assert_equal "Run: echo 'Yes, I trust this folder'?", d["question"]
    assert ask("op" => "answer", "session" => "by_planted_s", "hash" => d["hash"], "key" => "1")["ok"]
    assert_equal %w[1], tmux_calls.lines.grep(/send-keys/).map { |l| l.split.last }
  end

  # "No, exit" under the cursor already: Enter alone
  def test_no_on_the_trust_prompt_is_enter_alone
    FileUtils.touch(@trust_ui)
    Open3.capture3("git", "init", "-q", File.join(@projects, "planted"))
    launch("planted")
    File.write(File.join(@base, "alive"), "=by_planted_s\n")
    d = ask("op" => "dialog", "session" => "by_planted_s")["dialog"]
    assert ask("op" => "answer", "session" => "by_planted_s", "hash" => d["hash"], "key" => "1")["ok"]
    assert_equal %w[Enter], tmux_calls.lines.grep(/send-keys/).map { |l| l.split.last }
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
    stage = File.join(@base, "state/skills/by_fresh_s")
    argv = Shellwords.split(File.read(File.join(@base, "command")).chomp.delete_suffix("; exec bash"))
    i = argv.index("--plugin-dir")
    assert_equal stage, argv[i + 1]
    assert argv[i + 2].start_with?("/busyyaks:session Test lead session for fresh"), argv.inspect
    assert_equal ["--remote-control", "by_fresh_s"], argv.last(2)
    assert_equal %w[core agents/lead critic design qa reviewer security session], r["skills"].map { |k| k["name"] }
    assert_equal "none", r["project_skills"]
    assert_equal 0o700, File.stat(stage).mode & 0o777
    assert_equal({ "name" => "busyyaks" }, JSON.parse(File.read(File.join(stage, ".claude-plugin/plugin.json"))))
    entry = File.read(File.join(stage, "skills/session/SKILL.md"))
    assert_includes entry, "# busyyaks session (agent type lead)"
    assert_includes entry, "## Agent type lead (busyyaks)"
    assert_includes entry, "`busyyaks:reviewer`", "an on-demand skill is listed by its plugin name"
    refute_includes entry, "## reviewer"
    refute_includes entry, "Agent type worker", "a worker's part is not a lead's"
    assert_match(%r{skills core\(busyyaks,start,\h{12}\) agents/lead\(busyyaks,start,\h{12}\)}, File.read(@log))
    assert_empty Dir.children(@home), "nothing installed user-wide (no ~/.claude/skills, no plugin install)"
  end

  # busyyaks's core skill is missing: refused before tmux starts anything, no stage left
  def test_a_launch_with_a_broken_skill_set_is_refused_before_it_starts
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    FileUtils.rm_rf(File.join(@co, "skills/busyyaks/core"))
    File.write(@tmux_log, "")
    r = launch("fresh")
    refute r["ok"], r.inspect
    assert_match(%r{\Askills: .*/skills/busyyaks/core/SKILL.md missing \(every session starts with it\)}, r["error"])
    refute_includes tmux_calls, "new-session", "nothing started"
    refute File.exist?(File.join(@base, "state/skills/by_fresh_s"))
  end

  # an agent that comes up WITHOUT the stage (a launcher function dropping the extra flags): refused, killed, stage gone
  def test_an_agent_up_without_its_skills_is_refused
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    FileUtils.touch(@noplugin)
    r = launch("fresh")
    refute r["ok"], r.inspect
    assert_match(/\Aby_fresh_s did not start: the agent runs without its skills: no --plugin-dir /, r["error"])
    assert_match(/kill-session -t =by_fresh_s/, tmux_calls)
    refute File.exist?(File.join(@base, "state/skills/by_fresh_s"))
  end

  # The board's MCP reaches a session busyyaks launches only through its own --mcp-config <stage>/mcp.json (MCP_BOARD_TOKEN,
  # 0600 in the 0700 stage): an agent up without it would work the board with nothing — refused and killed
  def test_an_agent_up_without_the_board_mcp_is_refused
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    FileUtils.touch(@nomcp)
    r = launch("fresh")
    refute r["ok"], r.inspect
    assert_match(/\Aby_fresh_s did not start: the agent runs without the board's MCP: no --mcp-config /, r["error"])
    assert_match(/kill-session -t =by_fresh_s/, tmux_calls)
  end

  # a session busyyaks launches gets the board token in its own stage file — never in an argv, a tmux call or a log
  def test_a_claude_launch_carries_the_board_mcp_in_its_own_stage
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    r = launch("fresh")
    assert r["ok"], r.inspect
    path = File.join(@base, "state/skills/by_fresh_s/mcp.json")
    assert_equal 0o600, File.stat(path).mode & 0o777
    doc = JSON.parse(File.read(path))
    want = { "type" => "http", "url" => "http://127.0.0.1:8081/mcp",
             "headers" => { "Authorization" => "Bearer #{BOARD_TOKEN}" }, }
    assert_equal(want,
                 doc.dig("mcpServers", "busyyaks"))
    [tmux_calls, File.read(@log)].each { |t| refute_includes t, BOARD_TOKEN }
    refute_includes File.read(path), MCP_TOKEN
  end

  # a stage lives while its session does: the next launch removes the stage of a session tmux no longer lists
  def test_the_stage_of_an_ended_session_is_removed
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    ask("op" => "create", "root" => "/projects", "name" => "two", "url" => "")
    assert launch("fresh")["ok"]
    assert File.directory?(File.join(@base, "state/skills/by_fresh_s"))
    File.write(File.join(@base, "ls"), "") # tmux ls: by_fresh_s is gone
    FileUtils.rm_f(File.join(@base, "pane.pid"))
    assert launch("two")["ok"]
    refute File.exist?(File.join(@base, "state/skills/by_fresh_s"))
    assert File.directory?(File.join(@base, "state/skills/by_two_s"))
  end

  # the notifier's watch pass asks `sessions`: a stage goes within a pass of its session's end
  def test_the_sessions_op_removes_the_stage_of_an_ended_session
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    assert launch("fresh")["ok"]
    File.write(File.join(@base, "ls"), "") # tmux ls: by_fresh_s is gone
    assert ask("op" => "sessions")["ok"]
    refute File.exist?(File.join(@base, "state/skills/by_fresh_s"))
    assert_match(/skills sweep \(sessions\): removed by_fresh_s/, File.read(@log))
  end

  # tmux unreadable (ls fails, not "no server"): nothing removed, and the log says the sweep was skipped and why
  def test_a_failed_tmux_ls_never_removes_a_stage
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    assert launch("fresh")["ok"]
    FileUtils.rm_f(File.join(@base, "ls")) # the stub's ls exits 1, no output
    ask("op" => "sessions")
    assert File.directory?(File.join(@base, "state/skills/by_fresh_s"))
    assert_match(/skills sweep skipped \(sessions\): tmux ls failed: no output/, File.read(@log))
  end

  # tmux's real "no server" answers (no server running / the socket missing) = no sessions: the stage goes; any other
  # error (a socket it may not open: Permission denied) = tmux unreadable: kept, the skip logged
  def test_only_a_real_no_server_answer_counts_as_no_sessions
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    assert launch("fresh")["ok"]
    stage = File.join(@base, "state/skills/by_fresh_s")
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

  # a repo's own layer: agents/<type>.md (an addition for that type) + one on-demand skill
  def project_skill(repo, type:)
    base = File.join(@projects, repo, ".busyyaks/skills")
    FileUtils.mkdir_p(File.join(base, "agents"))
    File.write(File.join(base, "agents/#{type}.md"), "Run make deploy.\n")
    FileUtils.mkdir_p(File.join(base, "deploy"))
    File.write(File.join(base, "deploy/SKILL.md"), "---\nname: deploy\ndescription: how this repo deploys\n---\nDetails.\n")
  end

  # a TRUSTED repo's own .busyyaks skills load: its agents/<type>.md after busyyaks's, its skills on demand
  def test_a_trusted_repos_own_skills_load
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    project_skill("fresh", type: "lead")
    r = launch("fresh")
    assert r["ok"], r.inspect
    assert_equal "loaded", r["project_skills"]
    assert_equal [%w[agents/lead start], %w[deploy on_demand]], r["skills"].select { |k|
 k["source"] == "project" }.map { |k| k.values_at("name", "load") }
    entry = File.read(File.join(@base, "state/skills/by_fresh_s/skills/session/SKILL.md"))
    assert_operator entry.index("## Agent type lead (busyyaks)"), :<,
entry.index("## Agent type lead (project)\n\nRun make deploy.")
    assert_includes entry, "- `busyyaks:deploy` (project): how this repo deploys"
  end

  # --- the project's rules per agent type = its .busyyaks/skills/agents/<type>.md (the project page's Settings tab) ---

  def rule_file(repo, type) = File.join(@projects, repo, ".busyyaks/skills/agents/#{type}.md")

  # the file the Settings tab's Save writes (through the writer service)
  def agent_rule(repo, type, text)
    FileUtils.mkdir_p(File.dirname(rule_file(repo, type)))
    File.write(rule_file(repo, type), text)
  end

  # every file of the sandbox (the repos, the launcher's HOME, hermes's home, its state + run dirs, its log, what tmux
  # was asked to type) that holds `text`
  def holding(text)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @base).map { File.join(@base, _1) }.select do |path|
      File.file?(path) && !File.symlink?(path) && File.binread(path).include?(text)
    end.sort
  end

  # the operator: "a session busyyaks launches as <type> gets that type's rules for this project". The real
  # bin/launcher, a Claude Code launcher: the repo's agents/lead.md is the type's last part of the entry skill of the
  # plugin dir THIS session is started with (--plugin-dir); another type's file is not in it
  def test_a_session_busyyaks_launches_as_lead_gets_that_types_rules_for_this_project
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    agent_rule("fresh", "lead", "Always run make e2e before a handoff.\n")
    agent_rule("fresh", "worker", "Workers only: screenshots on the card.\n")
    r = launch("fresh")
    assert r["ok"], r.inspect
    assert_equal %w[core agents/lead agents/lead critic design qa reviewer security session], r["skills"].map { |k| k["name"] }
    assert_equal "project", r["skills"][2]["source"]
    stage = File.join(@base, "state/skills/by_fresh_s")
    assert_includes File.read(File.join(@base, "command")), "--plugin-dir #{stage}"
    entry = File.read(File.join(stage, "skills/session/SKILL.md"))
    assert_includes entry, "## Agent type lead (project)\n\nAlways run make e2e before a handoff."
    assert_operator entry.index("## Agent type lead (busyyaks)"), :<, entry.index("## Agent type lead (project)")
    refute_includes entry, "Workers only"
  end

  # the operator: "bound to the project, but that does NOT mean any session in the directory reads them … the
  # busyyaks skill is loaded by the application when the web application starts the session, never from the terminal".
  # The rule is a file of the repo under .busyyaks/, which no CLI reads on its own; a launch copies it into the
  # session's staged skill (the launcher's state dir, 0700) and names that stage on the command line — the only way
  # it reaches an agent. The launch writes nothing into the repo, and nothing user-wide.
  def test_a_session_started_from_the_terminal_in_the_projects_directory_gets_none_of_the_projects_agent_rules
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    agent_rule("fresh", "lead", "Always run make e2e before a handoff.\n")
    repo = File.join(@projects, "fresh")
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: repo).sort
    r = launch("fresh")
    assert r["ok"], r.inspect
    assert_equal before, Dir.glob("**/*", File::FNM_DOTMATCH, base: repo).sort, "the launch writes nothing into the repo"
    assert_empty(AUTO_LOADED.select { File.exist?(File.join(repo, _1)) }, "no file a CLI reads on its own")
    stage = File.join(@base, "state/skills/by_fresh_s")
    assert_equal [File.join(stage, "skills/session/SKILL.md"), rule_file("fresh", "lead")].sort,
                 holding("Always run make e2e before a handoff."),
                 "the repo's .busyyaks file and the launched session's stage: no home dir, no log, no typed command"
    assert_equal 0o700, File.stat(stage).mode & 0o777
    assert_empty Dir.children(@home), "nothing user-wide: the launcher's HOME is untouched"
    # what makes the launched session read it — and what a session typed in a terminal does not have
    command = File.read(File.join(@base, "command"))
    assert_includes command, "--plugin-dir #{stage}"
    assert_includes command, "/busyyaks:session"
  end

  # the Settings tab asks the launcher what a launch does with the repo's layer (its own trust decision and checks),
  # starting nothing: none · loaded · left: <why> · the refusal a launch would give
  def test_the_launcher_says_what_a_launch_does_with_the_projects_layer
    settings = { "id" => 1, "doc" => AGENTS }
    op = ->(name) { ask("op" => "project_skills", "path" => "/projects/#{name}", "settings" => settings) }
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    r = op.("fresh")
    assert_equal [true, "none", false], r.values_at("ok", "project_skills", "checkout")
    assert_equal %w[lead plain team worker], r["budget"].keys.sort
    room = r["budget"]["lead"]
    assert_operator room, :<, 32_768, "max_start_bytes less busyyaks's own core + agents/lead.md"
    agent_rule("fresh", "lead", "Run make e2e.\n")
    assert_equal "loaded", op.("fresh")["project_skills"]
    # a file that would push the lead's entry skill over max_start_bytes: that launch is refused, and the op says so
    agent_rule("fresh", "lead", "x" * (room + 1))
    r = op.("fresh")
    assert_equal [false, 422], r.values_at("ok", "status")
    assert_match(/\Askills: agent type lead: core \+ agents\/lead.md are \d+ bytes, over skills.max_start_bytes/, r["error"])
    assert_match(/\Askills: agent type lead: /, launch("fresh")["error"])
    agent_rule("fresh", "lead", "Run make e2e.\n")
    planted("planted")
    agent_rule("planted", "lead", "Run make e2e.\n")
    assert_match(/\Aleft: .* is not in config\/busyyaks.yml launch.trusted_paths/, op.("planted")["project_skills"])
    agent_rule("fresh", "boss", "x\n")
    r = op.("fresh")
    assert_equal false, r["ok"]
    assert_match(%r{\Askills: .*agents/boss\.md: boss is not an agent type}, r["error"])
    assert_match(/settings \{id, doc\} are required/, ask("op" => "project_skills", "path" => "/projects/fresh")["error"])
    refute_includes tmux_calls, "new-session"
    refute File.exist?(File.join(@base, "state/skills/by_fresh_s")), "nothing staged"
  end

  # Settings → Agent rules reads busyyaks's own layers from the launcher: the HOST checkout it launches from, read at
  # every ask (an edit there shows at once), in the order a launch stages them, nothing started
  def test_the_operator_reads_every_global_markdown_from_the_checkout_the_launcher_launches_from
    settings = { "id" => 1, "doc" => AGENTS }
    r = ask("op" => "skills_layers", "settings" => settings)
    assert r["ok"], r.inspect
    assert_equal %w[skills/busyyaks/core/SKILL.md skills/busyyaks/agents/lead.md], r.dig("types", "lead", "start")
    assert_equal %w[critic design qa reviewer security], r.dig("types", "lead", "on_demand")
    lead = r["files"].find { _1["path"] == "skills/busyyaks/agents/lead.md" }
    assert_equal [File.read(File.join(@co, "skills/busyyaks/agents/lead.md")), "busyyaks", "agent", "start"],
                 lead.values_at("text", "source", "kind", "load")
    assert_includes r["creatable"], "skills/busyyaks/agents/plain.md"
    # this sandbox's checkout is not under its PROJECTS_ROOT: the writer could not save there — said, never guessed
    assert_nil r.dig("checkout", "mount")
    assert_match(/is not under PROJECTS_ROOT #{Regexp.escape(@projects)}: the writer service cannot write it/,
                 r.dig("checkout", "error"))
    File.write(File.join(@co, "skills/busyyaks/agents/lead.md"), "# Lead\n\nEDITED ON THE HOST\n")
    lead = ask("op" => "skills_layers", "settings" => settings)["files"].find { _1["path"].end_with?("agents/lead.md") }
    assert_equal "# Lead\n\nEDITED ON THE HOST\n", lead["text"]
    FileUtils.rm_rf(File.join(@co, "skills/busyyaks/core"))
    r = ask("op" => "skills_layers", "settings" => settings)
    assert_equal [false, 422], r.values_at("ok", "status")
    assert_match(%r{\Askills: .*core/SKILL.md missing}, r["error"])
    refute_includes tmux_calls, "new-session"
  end

  # an UNTRUSTED repo's .busyyaks skills are left (never read); the launch runs on busyyaks's and says why
  def test_an_untrusted_repos_skills_are_left
    planted("planted")
    project_skill("planted", type: "lead")
    r = launch("planted")
    assert r["ok"], r.inspect
    assert_match(/\Aleft: .* is not in config\/busyyaks.yml launch.trusted_paths/, r["project_skills"])
    refute(r["skills"].any? { |k| k["source"] == "project" })
  end

  # the agent settings with the copywriter preset added (opt-in, under the lead, on the lead's launchers)
  def with_copywriter
    preset = Busyyaks::AgentPresets.load!.find { |p| p["key"] == "copywriter" }
    lead = AGENTS["agent_types"].find { |t| t["key"] == "lead" }
    AGENTS.merge("agent_types" => AGENTS["agent_types"] + [Busyyaks::AgentPresets.type(preset, launchers: lead["launchers"])])
  end

  def agents_file(repo, text) = File.write(File.join(@projects, repo, ".busyyaks/agents.yml"), text)

  def under_lead(dir, session, type, doc, over = {})
    ask({ "op" => "launch", "path" => "/projects/#{dir}", "launcher" => "fullclaude", "session" => session,
          "type" => type, "lead" => "by_#{dir}_s", "settings" => { "id" => 2, "doc" => doc },
          "vars" => { "slug" => dir, "session" => session, "agent" => "a", "type" => type, "cards" => "-" }, }.merge(over))
  end

  # the real bin/launcher reads the repo's .busyyaks/agents.yml itself (its own trust decision) — a role's
  # brief follows its type's parts in the staged entry skill; an opt-in type starts only on a board that uses it; a
  # role from an untrusted repo, a role of another type, an invalid file: refused before tmux
  def test_a_board_role_and_an_opt_in_type_reach_the_session_only_as_the_repos_file_says
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    doc = with_copywriter
    agent_rule("fresh", "changelog", "Changelog role: one entry per card under Unreleased.\n")
    agents_file("fresh", "roles:\n  changelog: {label: Changelog writer, like: worker}\n")
    a = ask("op" => "project_agents", "path" => "/projects/fresh", "settings" => { "id" => 2, "doc" => doc })
    assert_equal ["loaded", ["copywriter"], { "label" => "Changelog writer", "like" => "worker" }],
                 [a["state"], a["opt_in"], a.dig("agents", "roles", "changelog")]
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "by_fresh_s", "type" => "lead",
            "launcher" => "fullclaude", "lead_key" => LEAD_KEY, "settings" => { "id" => 2, "doc" => doc },
            "vars" => { "slug" => "fresh", "session" => "by_fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
    assert r["ok"], r.inspect
    File.write(File.join(@base, "alive"), "=by_fresh_s\n")
    File.write(@tmux_log, "")
    assert_match(/agent types: agent type copywriter is opt-in and this board does not use it \(.*use: none\)/,
                 under_lead("fresh", "by_c1", "copywriter", doc)["error"])
    assert_match(/role changelog runs as agent type worker/,
                 under_lead("fresh", "by_c1", "copywriter", doc, "role" => "changelog")["error"])
    refute_includes tmux_calls, "new-session", "nothing was started"
    r = under_lead("fresh", "by_w1", "worker", doc, "role" => "changelog")
    assert r["ok"], r.inspect
    assert_equal "changelog", r["role"]
    assert_includes r["skills"].map { |k| k["name"] }, "agents/changelog"
    entry = File.read(File.join(@base, "state/skills/by_w1/skills/session/SKILL.md"))
    assert_includes entry, "## Agent role changelog (project)\n\nChangelog role: one entry per card under Unreleased."
    assert_operator entry.index("## Agent type worker (busyyaks)"), :<, entry.index("## Agent role changelog (project)")
    assert_match(/launched by_w1 \(worker role changelog\//, File.read(@log))
    agents_file("fresh", "use: [copywriter]\nroles:\n  changelog: {label: Changelog writer, like: worker}\n")
    r = under_lead("fresh", "by_c2", "copywriter", doc)
    assert r["ok"], r.inspect
    entry = File.read(File.join(@base, "state/skills/by_c2/skills/session/SKILL.md"))
    assert_includes entry, "## Agent type copywriter (busyyaks)", "the preset's brief ships with busyyaks"
    agents_file("fresh", "colums: {}\n")
    assert_match(/agent types: \.busyyaks\/agents\.yml: unknown keys colums/,
under_lead("fresh", "by_w2", "worker", doc)["error"])
    assert_match(/unknown keys colums/,
                 ask("op" => "project_agents", "path" => "/projects/fresh", "settings" => { "id" => 2, "doc" => doc })["error"])
  end

  def test_an_untrusted_repos_agents_file_is_left_and_its_roles_never_start
    planted("planted")
    agent_rule("planted", "changelog", "Changelog role.\n")
    agents_file("planted", "roles:\n  changelog: {label: Changelog writer, like: worker}\n")
    a = ask("op" => "project_agents", "path" => "/projects/planted", "settings" => { "id" => 1, "doc" => AGENTS })
    assert_match(/\Aleft: .* is not in config\/busyyaks.yml launch.trusted_paths/, a["state"])
    assert_nil a["agents"], "never read"
    r = launch("planted")
    assert r["ok"], r.inspect
    File.write(File.join(@base, "alive"), "=by_planted_s\n")
    r = under_lead("planted", "by_w1", "worker", AGENTS, "role" => "changelog")
    assert_match(%r{agent types: this board's \.busyyaks/agents\.yml is not read \(.* launch.trusted_paths}, r["error"])
    assert_match(/: no session is started for its cards/, r["error"])
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
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "by_fresh_s", "type" => "plain", "launcher" => "hermes",
            "settings" => { "id" => 3, "doc" => doc },
            "vars" => { "slug" => "fresh", "session" => "by_fresh_s", "agent" => "a", "type" => "plain", "cards" => "-" })
    refute r["ok"], r.inspect
    assert_match(/the agent runs without its skills: hermes does not list busyyaks-session-\h{12}: /, r["error"])
    assert_includes r["error"], "#{@hermes_home}/config.yaml needs `- ${BUSYYAKS_SKILLS_DIR}/busyyaks-skills`"
    assert_match(/kill-session -t =by_fresh_s/, tmux_calls)
    refute File.exist?(File.join(@base, "state/skills/by_fresh_s"))
  end

  # claude never came up (it refused to start; the pane is a bare shell): the launch is refused with the pane's last
  # lines and the session killed — never an ok the engine would register an owner on
  def test_a_launch_without_claude_remote_control_is_refused_and_killed
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    File.write(@refuse, "")
    r = launch("fresh")
    refute r["ok"], r.inspect
    assert_equal 422, r["status"]
    assert_match(/\Aby_fresh_s did not start: the command exited after \d+s, no claude --remote-control by_fresh_s: /,
r["error"])
    assert_match(/: Temp directory .* owned by uid 0/, r["error"])
    assert_match(/kill-session -t =by_fresh_s/, tmux_calls)
  end

  def test_a_refused_launch_whose_kill_failed_says_the_session_still_runs
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    File.write(@refuse, "")
    File.write(File.join(@base, "nokill"), "")
    r = launch("fresh")
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    assert_match(/kill-session failed \(server busy\): the tmux session by_fresh_s is still running\z/, r["error"])
  end

  def test_a_launch_with_claude_remote_control_up_is_ok_and_kept
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    r = launch("fresh")
    assert_equal [true, "on", "by_fresh_s"], r.values_at("ok", "remote_control", "remote_control_name"), r.inspect
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
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "by_fresh_s", "type" => "lead",
            "launcher" => "fullclaude",
            "lead_key" => LEAD_KEY,
            "settings" => { "id" => 7, "doc" => doc },
            "vars" => { "slug" => "fresh", "session" => "by_fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
    refute r["ok"], r.inspect
    assert r["error"].start_with?("agent settings revision 7: launcher fullclaude " \
                                  "(claude_code: bash --permission-mode bypassPermissions): not an invocation on this " \
                                  "host's allowlist config/busyyaks.yml launch.commands"), r["error"]
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "by_fresh_s", "type" => "lead",
            "launcher" => "fullclaude",
            "lead_key" => LEAD_KEY,
            "vars" => { "slug" => "fresh", "session" => "by_fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
    assert_match(/settings \{id, doc\} are required/, r["error"])
    # a prompt starting with "-" (an option of the allowlisted command) is refused before tmux too
    types = AGENTS["agent_types"].map { |t| t["key"] == "lead" ? t.merge("prompt" => "--mcp-config=/tmp/x {slug}") : t }
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "by_fresh_s", "type" => "lead",
            "launcher" => "fullclaude",
            "lead_key" => LEAD_KEY,
            "settings" => { "id" => 8, "doc" => AGENTS.merge("agent_types" => types) },
            "vars" => { "slug" => "fresh", "session" => "by_fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
    assert_match(/agent settings revision 8: agent_types\[lead\].prompt must not start with "-"/, r["error"])
    refute_includes tmux_calls, "new-session", "nothing was started"
  end

  # A lead of project "fresh" (made by the launcher: trusted) started on a hermes launcher → the launcher's answer.
  # The block runs after the repo exists, before the launch (to put files into it).
  def launch_hermes
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    yield if block_given?
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
    ask("op" => "launch", "path" => "/projects/fresh", "session" => "by_fresh_s", "type" => "lead", "launcher" => "hermes",
        "lead_key" => LEAD_KEY, "settings" => { "id" => 3, "doc" => doc },
        "vars" => { "slug" => "fresh", "session" => "by_fresh_s", "agent" => "a", "type" => "lead", "cards" => "-" })
  end

  # the operator: "ensure it works this way for every harness, not only Claude — also Hermes". The real bin/launcher
  # on a hermes launcher: the project's rule is in the entry skill hermes is started with (-s busyyaks-session-<token>,
  # found through this session's BUSYYAKS_SKILLS_DIR only)
  def test_a_hermes_launch_gets_the_same_rules
    r = launch_hermes { agent_rule("fresh", "lead", "Hermes too: run make e2e.\n") }
    assert r["ok"], r.inspect
    assert_equal "loaded", r["project_skills"]
    assert_includes r["skills"].map { |k| k.values_at("name", "source") }, %w[agents/lead project]
    started = tmux_calls.lines.find { |l| l.start_with?("new-session") }
    token = started[/-s busyyaks-session-(\h{12}) /, 1]
    stage = File.join(@base, "state/skills/by_fresh_s")
    assert_includes started, "-e BUSYYAKS_SKILLS_DIR=#{stage} "
    entry = File.join(stage, "busyyaks-skills/busyyaks-session-#{token}/SKILL.md")
    assert_includes File.read(entry), "## Agent type lead (project)\n\nHermes too: run make e2e."
    assert_equal [entry, rule_file("fresh", "lead")].sort, holding("Hermes too: run make e2e.")
    assert_empty(AUTO_LOADED.select { File.exist?(File.join(@projects, "fresh", _1)) })
    refute_includes File.read(File.join(@hermes_home, "config.yaml")), "Hermes too"
  end

  # a hermes launcher (kind hermes): the prompt goes as -q, no trust prompt is answered (it is Claude Code's), and the
  # start counts as up when the pane runs hermes — there is no remote control to wait for
  def test_a_hermes_launch_is_up_when_its_pane_runs_hermes
    r = launch_hermes
    assert_equal [true, "hermes", "on", "hermes"], r.values_at("ok", "kind", "process", "process_name"), r.inspect
    refute r.key?("remote_control"), r.inspect
    started = tmux_calls.lines.find { |l| l.start_with?("new-session") }
    token = started[/-s busyyaks-session-(\h{12}) /, 1]
    refute_nil token, started
    assert_match(/hermes chat -s busyyaks-session-#{token} -q work\\ on\\ fresh/, started)
    stage = File.join(@base, "state/skills/by_fresh_s")
    assert_includes started, "-e BUSYYAKS_SKILLS_DIR=#{stage} ", "the stage reaches hermes through this session's env only"
    entry = File.join(stage, "busyyaks-skills/busyyaks-session-#{token}/SKILL.md")
    assert_match(/\A---\nname: busyyaks-session-#{token}\n/, File.read(entry))
    assert File.file?(File.join(stage, "busyyaks-skills/busyyaks-reviewer-#{token}/SKILL.md"))
    assert_includes File.read(entry), "## Agent type lead (busyyaks)"
    assert_equal %w[core agents/lead critic design qa reviewer security session], r["skills"].map { |k|
 k["name"] }, "lead: core + its part + the on-demand briefs + the entry skill"
    refute_match(/--remote-control/, started)
    refute_match(/send-keys/, tmux_calls, "no trust prompt answered for hermes")
    # the overlay reached it through this session's env, its token only in the 0600 file
    managed = File.join(stage, "hermes-managed")
    assert_includes started, "-e HERMES_MANAGED_DIR=#{managed} "
    assert_equal 0o600, File.stat(File.join(managed, "config.yaml")).mode & 0o777
    # the board token (MCP_BOARD_TOKEN) in this session's own overlay only — never the operator's MCP_TOKEN, never an
    # argv or a log line
    overlay = File.read(File.join(managed, "config.yaml"))
    assert_includes overlay, "Bearer #{BOARD_TOKEN}"
    refute_includes overlay, MCP_TOKEN
    [tmux_calls, File.read(@log)].each { |t| refute_includes t, BOARD_TOKEN }
    refute_includes File.read(File.join(@hermes_home, "config.yaml")), "Bearer", "the operator's config is never written"
    assert_equal ["by_fresh_s"], JSON.parse(File.read(File.join(@base, "state/hermes-board.json"))).map { _1["session"] }
  end

  # the checks run the ALLOWLISTED command; a program a pane's process names is never executed
  def test_the_hermes_checks_never_run_the_panes_program
    FileUtils.mkdir_p(File.dirname(@pane_hermes))
    File.write(@pane_hermes, <<~SH)
      #!/bin/sh
      [ "$1" = chat ] || : > #{@pane_hermes_ran}
      sleep 300
    SH
    File.chmod(0o755, @pane_hermes)
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
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "by_fresh_s", "type" => "plain", "launcher" => "hermes",
            "settings" => { "id" => 3, "doc" => doc },
            "vars" => { "slug" => "fresh", "session" => "by_fresh_s", "agent" => "a", "type" => "plain", "cards" => "-" })
    refute File.exist?(@pane_hermes_ran), "the launcher ran the pane's program"
    assert r["ok"], r.inspect
  end

  # Hermes skips MCP discovery when the user's config has no mcp_servers: refused, naming the line, file unchanged
  def test_a_hermes_launch_without_mcp_servers_is_refused_naming_the_line
    config = File.join(@hermes_home, "config.yaml")
    File.write(config, YAML.dump("skills" => { "external_dirs" => ["${BUSYYAKS_SKILLS_DIR}/busyyaks-skills"] }))
    before = File.read(config)
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
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => "by_fresh_s", "type" => "plain", "launcher" => "hermes",
            "settings" => { "id" => 3, "doc" => doc },
            "vars" => { "slug" => "fresh", "session" => "by_fresh_s", "agent" => "a", "type" => "plain", "cards" => "-" })
    refute r["ok"], r.inspect
    assert_includes r["error"], "#{config} has no mcp_servers"
    assert_includes r["error"], Busyyaks::HermesBoard::INERT
    assert_match(/kill-session -t =by_fresh_s/, tmux_calls)
    refute File.exist?(File.join(@base, "state/skills/by_fresh_s")), "the stage (with the token) is gone"
    assert_equal before, File.read(config)
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
    File.write(@pane,
"sleep 13; exec #{@bin}/claude -c 'sleep 300; :' --mcp-config \"$3\" --plugin-dir \"$2\" --remote-control \"$1\"\n")
    r = Elapsed.at_least(12, "the wrapper's 13 s were waited out") { launch("slow") }
    assert_equal [true, "on", "by_slow_s"], r.values_at("ok", "remote_control", "remote_control_name"), r.inspect
    refute_includes tmux_calls, "kill-session"
  end

  # the command exited into the pane's bare shell: refused at once (3 checks), well before launch.start_seconds
  def test_a_command_that_exits_at_once_is_refused_fast_with_the_pane_tail
    planted("gone")
    File.write(@refuse, "")
    r = assert_refused_at_once("by_gone_s") { launch("gone") }
    assert_match(/: Temp directory/, r["error"])
    assert_match(/kill-session -t =by_gone_s/, tmux_calls)
  end

  # a command that keeps working and never starts claude: refused once launch.start_seconds passed
  def test_a_command_that_never_starts_claude_is_refused_after_start_seconds
    restart(4)
    planted("stuck")
    File.write(@pane, "sleep 30; :\n")
    r = Elapsed.at_least(4, "launch.start_seconds 4 waited out") { launch("stuck") }
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    m = r["error"].match(
      /\Aby_stuck_s did not start: no claude --remote-control by_stuck_s after (\d+)s \(launch.start_seconds 4\)/
    )
    assert m, r["error"]
    assert_operator m[1].to_i, :>=, 4
    assert_match(/kill-session -t =by_stuck_s/, tmux_calls)
  end

  # a pane that merely looks like a dialog, with no claude process: a failed start, never a kept session
  def test_a_dialog_looking_pane_without_claude_is_refused
    planted("dlg")
    File.write(@refuse, "")
    File.write(@dialog, "")
    r = launch("dlg")
    assert_equal [false, 422], r.values_at("ok", "status"), r.inspect
    assert_match(/\Aby_dlg_s did not start: the command exited after \d+s, no claude --remote-control by_dlg_s: /, r["error"])
    assert_match(/: Do you want to proceed/, r["error"])
    assert_match(/kill-session -t =by_dlg_s/, tmux_calls)
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
    assert_equal [["by_fresh_s", "lead", File.realpath(File.join(@projects, "fresh")), LEAD_KEY]],
                 leads.map { |e| e.values_at("session", "type", "dir", "key") }
    assert_equal "600", format("%o", File.stat(File.join(@base, "state/leads.json")).mode & 0o777)
    assert_match(/by_fresh_s: its tmux session is not running/, ask("op" => "lead_key", "session" => "by_fresh_s")["error"])
    File.write(File.join(@base, "alive"), "=by_fresh_s\n")
    assert_equal [true, LEAD_KEY], ask("op" => "lead_key", "session" => "by_fresh_s").values_at("ok", "key")
    assert_match(/nobody: no lead this launcher started/, ask("op" => "lead_key", "session" => "nobody")["error"])
    File.write(@tmux_log, "")
    vars = ->(dir, s, t) { { "slug" => dir, "session" => s, "agent" => "a", "type" => t, "cards" => "-" } }
    req = lambda do |dir, s, t, over = {}|
      ask({ "op" => "launch", "path" => "/projects/#{dir}", "launcher" => "fullclaude", "session" => s, "type" => t,
            "settings" => { "id" => 1, "doc" => AGENTS }, "vars" => vars.(dir, s, t), }.merge(over))
    end
    assert_match(/needs its lead key/, req.("fresh", "by_l2", "lead")["error"])
    assert_match(/needs its lead key/, req.("fresh", "by_l2", "lead", "lead_key" => "x")["error"])
    assert_match(/runs under no lead/, req.("fresh", "by_l2", "lead", "lead_key" => LEAD_KEY, "lead" => "by_fresh_s")["error"])
    assert_match(/runs under the board's lead: no lead session given/, req.("fresh", "by_w1", "worker")["error"])
    assert_match(/by_gone_s is no lead this launcher started/, req.("fresh", "by_w1", "worker", "lead" => "by_gone_s")["error"])
    assert_match(%r{by_fresh_s leads .*/fresh, not .*/other: a session runs under its own board's lead},
                 req.("other", "by_w1", "worker", "lead" => "by_fresh_s")["error"])
    assert_match(/a plain session gets no lead key/, req.("fresh", "by_p1", "plain", "lead_key" => LEAD_KEY)["error"])
    # a revision with a worker under no lead does not even load (review round 1, blocker)
    unled = ->(t) { t["key"] == "worker" ? t.except("under", "launchable") : t }
    leaderless = AGENTS.merge("agent_types" => AGENTS["agent_types"].map(&unled))
    r = req.("fresh", "by_w1", "worker", "lead" => "by_fresh_s", "settings" => { "id" => 9, "doc" => leaderless })
    assert_match(/agent settings revision 9: .*agent_types\[worker\] runs without a lead/, r["error"])
    refute_includes tmux_calls, "new-session", "nothing was started"
    r = req.("fresh", "by_w1", "worker", "lead" => "by_fresh_s")
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
    r = assert_refused_at_once("by_tgone_s") { launch("tgone") }
    refute_match(/trust/i, r["error"])
    refute_includes tmux_calls, "Enter", "nothing answered on a pane that is a bare shell"
  end

  # a TRUSTED repo whose wrapper works longer than the trust wait, then starts claude: its prompt answered, up, kept
  def test_a_trusted_repo_with_a_slow_wrapper_is_ok
    ask("op" => "create", "root" => "/projects", "name" => "tslow", "url" => "")
    File.write(@pane,
"sleep 13; exec #{@bin}/claude -c 'sleep 300; :' --mcp-config \"$3\" --plugin-dir \"$2\" --remote-control \"$1\"\n")
    r = Elapsed.at_least(12, "the wrapper's 13 s were waited out") { launch("tslow") }
    assert_equal [true, "accepted", "on", "by_tslow_s"], r.values_at("ok", "trust", "remote_control", "remote_control_name"),
                 r.inspect
    refute_includes tmux_calls, "kill-session"
  end

  # --- docs/USE-CASES-session-isolation.md: the live run's checks, without a model or a real session -----------------

  # the launched claude's own argv (what the stub tmux was asked to run), as a list of words
  def started_argv = Shellwords.split(File.read(File.join(@base, "command")).chomp.delete_suffix("; exec bash"))

  # U2, the operator: only sessions busyyaks starts get the busyyaks skill and the board. The live run read the argv of
  # the web-launched lead and Sub team: each carries ITS stage as --plugin-dir and <stage>/mcp.json as --mcp-config,
  # both BEFORE the prompt, the prompt opens with /busyyaks:session, and --remote-control <session> is last
  # (the negative — a session started by hand gets none of it — is U1: no_global_skill_test, mcp_test, collector_test)
  def test_a_session_busyyaks_starts_gets_its_skill_and_the_board_lead_and_sub_team_alike
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    assert launch("fresh")["ok"]
    File.write(File.join(@base, "alive"), "=by_fresh_s\n") # the lead runs: its sub team may start under it
    lead_argv = started_argv
    team = "by_fresh_team"
    r = ask("op" => "launch", "path" => "/projects/fresh", "session" => team, "type" => "team", "launcher" => "fullclaude",
            "lead" => "by_fresh_s", "settings" => { "id" => 1, "doc" => AGENTS },
            "vars" => { "slug" => "fresh", "session" => team, "agent" => "a", "type" => "team", "cards" => "-" })
    assert r["ok"], r.inspect
    { "by_fresh_s" => [lead_argv, "lead"], team => [started_argv, "team"] }.each do |session, (argv, type)|
      stage = File.join(@base, "state/skills", session)
      prompt = argv.index { |w| w.start_with?("/busyyaks:session ") }
      refute_nil prompt, "#{session}: a prompt opening with /busyyaks:session in #{argv.inspect}"
      assert_equal "/busyyaks:session Test #{type} session for fresh", argv[prompt][/\A\S+ \S+ \S+ \S+ \S+ \S+/]
      { "--plugin-dir" => stage, "--mcp-config" => File.join(stage, "mcp.json") }.each do |flag, value|
        i = argv.index(flag)
        refute_nil i, "#{session}: #{flag}"
        assert_equal value, argv[i + 1], "#{session}: #{flag} names its own stage"
        assert_operator i, :<, prompt, "#{session}: #{flag} before the prompt"
      end
      assert_equal ["--remote-control", session], argv.last(2)
      assert_equal 0o600, File.stat(File.join(stage, "mcp.json")).mode & 0o777
      assert_includes File.read(File.join(stage, "skills/session/SKILL.md")), "# busyyaks session (agent type #{type})"
    end
  end

  # U3, the operator: "start with BY so we can easily identify and isolate them" — the launcher itself refuses to start
  # a session whose name has no `by_` prefix (whatever the request says), before anything is staged or started
  def test_the_launcher_starts_no_session_whose_name_does_not_start_with_by
    ask("op" => "create", "root" => "/projects", "name" => "fresh", "url" => "")
    File.write(@tmux_log, "")
    %w[fresh_s BY_fresh_s by_].each do |name|
      r = ask("op" => "launch", "path" => "/projects/fresh", "session" => name, "type" => "lead", "launcher" => "fullclaude",
              "lead_key" => LEAD_KEY, "settings" => { "id" => 1, "doc" => AGENTS },
              "vars" => { "slug" => "fresh", "session" => name, "agent" => "a", "type" => "lead", "cards" => "-" })
      assert_equal [false, 400], r.values_at("ok", "status"), "#{name}: #{r.inspect}"
      assert_equal "session #{name.inspect} has no \"by_\" prefix: every session busyyaks starts is named so " \
                   "(agent settings session_name)", r["error"]
      refute File.exist?(File.join(@base, "state/skills", name)), "#{name}: nothing staged"
    end
    refute_includes tmux_calls, "new-session", "nothing started"
  end

  # U8, the operator: "when a busyyaks session ends, what it left running in the background is cleaned up". The live
  # run: a busyyaks-by_* scope with no tmux session, then the `sessions` op → stopped, its processes logged. Here a stub
  # systemctl: the scope of the ended session is stopped; the running session's, a hand-run session's (no by_) and any
  # other unit are left
  def test_a_busyyaks_sessions_background_processes_are_stopped_once_the_session_ended
    stub("systemctl", <<~SH)
      echo "$*" >> #{@base}/systemctl.log
      case "$2" in
        list-units) printf '%s\\n' \
          "busyyaks-by_gone_worker.scope loaded active running bash supervise.sh" \
          "busyyaks-by_live_lead.scope loaded active running claude" \
          "busyyaks-hand.scope loaded active running claude" \
          "other.scope loaded active running x" ;;
      esac
      exit 0
    SH
    # tmux ls: by_gone_worker ended; `hand` is NOT listed either — its scope is kept only because it has no by_ prefix
    File.write(File.join(@base, "ls"), "by_live_lead\n")
    restart(START_SECONDS, scopes: { "lead_oomd" => "avoid", "session_memory_max" => "16G" })
    File.write(File.join(@base, "systemctl.log"), "")
    assert ask("op" => "sessions")["ok"]
    stops = File.readlines(File.join(@base, "systemctl.log"), chomp: true).grep(/\A--user stop /)
    assert_equal ["--user stop busyyaks-by_gone_worker.scope"], stops
    assert_match(/scope sweep \(sessions\): busyyaks-by_gone_worker.scope stopped · no processes/, File.read(@log))
    # systemctl unreadable: nothing stopped, the skip said — never read as "no scopes"
    stub("systemctl", "echo \"$*\" >> #{@base}/systemctl.log; echo 'Failed to connect to bus' >&2; exit 1")
    File.write(File.join(@base, "systemctl.log"), "")
    ask("op" => "sessions")
    refute_match(/ stop /, File.read(File.join(@base, "systemctl.log")))
    assert_match(/scope sweep skipped \(sessions\): systemctl: Failed to connect to bus/, File.read(@log))
  end

  # U7, the operator: nothing busyyaks in any global harness setting. A hermes launch reads the operator's
  # ~/.hermes/config.yaml and writes nothing into it, and a claude launch nothing into the launcher's HOME (no
  # ~/.claude.json, ~/.claude/, ~/.codex): every file a session gets lives in its own stage
  def test_a_launch_writes_nothing_into_any_harness_settings_of_the_user
    files = lambda do |dir|
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.to_h do |f|
        [f, File.file?(File.join(dir, f)) && File.binread(File.join(dir, f))]
      end
    end
    before = files.(@hermes_home)
    assert launch_hermes["ok"]
    assert_equal before, files.(@hermes_home), "the operator's hermes config: byte for byte"
    FileUtils.rm_f(@hermes) # the next pane runs claude
    ask("op" => "create", "root" => "/projects", "name" => "two", "url" => "")
    assert launch("two")["ok"]
    assert_empty Dir.children(@home), "no ~/.claude.json, ~/.claude, ~/.codex, ~/.hermes"
  end
end
