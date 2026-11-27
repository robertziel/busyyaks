# frozen_string_literal: true

require_relative "wait"
require "tmpdir"
require "fileutils"
require "open3"
require "socket"
require "json"
require "etc"
require "yaml"

# bin/collector + the real bin/launcher, run as processes in a sandbox checkout (card #479's contract;
# test/integration/collector_test.rb and test/integration/session_isolation_test.rb): the REAL /proc (each agent is a
# copy of bash named claude / hermes, so its comm is the family's) and a stub tmux that answers list-panes / ls with
# three sessions and records every input — no tmux server, no model, no AI session:
#   by_app_lead  a claude busyyaks launched (a stage with the launch's record of its pane: pid + start time)
#   by_desk      a hermes busyyaks launched (the same)
#   hand         a claude the operator started from a terminal in the same project: no prefix, no stage
# A `launch` op gets as far as `tmux new-session`, which waits while the file `hold-start` exists (a start in flight,
# held by the test, never by the clock) and then fails: nothing starts in the sandbox.
# Stdlib only: collector_test is a host test (scripts/ci/host-tests).
module CollectorSandbox
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60
  COPY = %w[bin/launcher bin/collector lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml
            config/harnesses.yml skills config/agent_presets.yml].freeze
  INVOCATIONS = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands")
  # the agent settings revision a launch carries (card #277): the suite's
  AGENTS = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))

  def sandbox_up!
    @base = File.realpath(Dir.mktmpdir("collector-contract", Etc.getpwuid(Process.uid).dir))
    @co = File.join(@base, "checkout")
    @bin = File.join(@base, "bin")
    @coll = File.join(@base, "collector")
    tmux_dir = File.join(@base, "tmuxtmp", "tmux-#{Process.uid}")
    # projects/app: a repo (a launch starts only in one)
    FileUtils.mkdir_p([File.join(@base, "projects/app/.git"), @bin, File.join(@co, "config"), File.join(@base, "sessions")])
    FileUtils.mkdir_p(tmux_dir, mode: 0o700)
    COPY.each do |f|
      FileUtils.mkdir_p(File.dirname(File.join(@co, f)))
      FileUtils.cp_r(File.join(ROOT, f), File.join(@co, f))
    end
    FileUtils.cp(File.join(ROOT, "test/fixtures/kanban.yml"), File.join(@co, "config/kanban.yml"))
    write_sandbox_config
    write_sandbox_env
    spawn_agents
    # this uid's tmux server, as the collector finds it: a socket in $TMUX_TMPDIR/tmux-<uid>
    @tmux_server = UNIXServer.new(File.join(tmux_dir, "default"))
    stub("tmux", tmux_stub)
    record_launches
    @env = { "PATH" => "#{@bin}:#{ENV.fetch('PATH')}", "TMUX_TMPDIR" => File.join(@base, "tmuxtmp") }
    @collector = spawn_up("bin/collector", "collector.log", File.join(@coll, "read.sock"))
    @launcher = spawn_up("bin/launcher", "launcher.log", launcher_socket)
  end

  def sandbox_down!
    FileUtils.rm_f(File.join(@base, "hold-start")) if @base # a held start lets its launch thread end
    [@launcher, @collector].compact.each do |p|
      Process.kill("TERM", p)
      Process.wait(p)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    [@agent, @hermes].compact.each do |p|
      Process.kill("TERM", -p)
      Process.wait(p)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    @tmux_server&.close
    FileUtils.rm_rf(@base) if @base
  end

  def write_sandbox_config
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(
      "roots" => [{ "path" => "/projects", "prefix" => "" }], "search_depth" => 2,
      "owner_remotes" => ["github.com/you/"], "author_emails" => ["you@example.com"], "window_days" => 7,
      "reap_protect" => [], "auth" => { "provider" => "none" },
      "agents" => { "collector" => { "snapshot" => File.join(@coll, "sessions.json"),
                                     "read_socket" => File.join(@coll, "read.sock"), "tmux_timeout_seconds" => 2,
                                     "answer_timeout_seconds" => 9, } },
      "terminal" => { "public_host" => "deny", "max_open" => 4 },
      "ci" => { "max_pending_minutes" => 60, "required" => { "o/r" => ["jenkins/ci"] } },
      "skills" => { "max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil },
      "updates" => { "remote" => "origin", "branch" => "main", "tags" => "v*", "channel" => "tags", "check_minutes" => 60 },
      "launch" => { "trusted_paths" => [], "commands" => INVOCATIONS, "start_seconds" => 30, "scopes" => nil }
    ))
  end

  def write_sandbox_env
    File.write(File.join(@co, ".env"), <<~ENV)
      PROJECTS_ROOT=#{File.join(@base, 'projects')}
      PROJECTS_MOUNT=/projects
      LAUNCHER_RUN_DIR=#{File.join(@base, 'run')}
      LAUNCHER_STATE_DIR=#{File.join(@base, 'state')}
      CLAUDE_SESSIONS_DIR=#{File.join(@base, 'sessions')}
      CLAUDE_SESSION_URL=https://claude.example/{id}
      MCP_HOST=127.0.0.1
      MCP_HOST_PORT=8081
      MCP_BOARD_TOKEN=#{'ef' * 32}
    ENV
  end

  def start_ticks(pid) = Integer(File.read("/proc/#{pid}/stat").then { |s| s[(s.rindex(")") + 2)..].split[19] }, 10)

  def spawn_agents
    # the agent: a copy of bash named claude, its cwd in the project
    FileUtils.cp(Open3.capture2("sh", "-c", "command -v bash").first.strip, File.join(@bin, "claude"))
    @agent = Process.spawn(File.join(@bin, "claude"), "-c", "sleep 300; :", %i[out err] => File::NULL, pgroup: true,
                                                                             chdir: File.join(@base, "projects/app"))
    # a Hermes pane: a copy of bash named hermes whose argv carries the launcher's bootstrap
    FileUtils.cp(File.join(@bin, "claude"), File.join(@bin, "hermes"))
    @hermes = Process.spawn(File.join(@bin, "hermes"), "-c", "sleep 300; : hermes_bootstrap", %i[out err] => File::NULL,
                            pgroup: true, chdir: File.join(@base, "projects/app"))
    File.write(File.join(@base, "sessions/#{@agent}.json"), JSON.generate(
      "pid" => @agent, "procStart" => start_ticks(@agent).to_s, "sessionId" => "24ec2128-9e6a-4d9d-b0b1-3a3e7f2744a4",
      "status" => "idle", "name" => "app-7", "statusUpdatedAt" => 1_700_000_000_000
    ))
  end

  # by_app_lead + by_desk: busyyaks launched them (a stage each, with the launch's record of its pane: pid + start
  # time); `hand`: a claude the operator started from a terminal — no prefix, no stage
  def record_launches
    { "by_app_lead" => @agent, "by_desk" => @hermes }.each do |n, pid|
      dir = File.join(@base, "state/skills", n)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.write(File.join(dir, "launched.json"), JSON.generate("pane_pid" => pid, "start_ticks" => start_ticks(pid)))
    end
  end

  def tmux_stub
    b = @base
    <<~SH
      echo "$*" >> #{b}/tmux.log
      for a; do case "$a" in -S) ;; *) [ -n "$cmd" ] || case "$a" in /*|-*) ;; *) cmd=$a ;; esac ;; esac; done
      case "$cmd" in
        list-panes) [ -f #{b}/fail-list ] && { echo "server exited unexpectedly" >&2; exit 1; }
                    # bin/launcher's own `list-panes -a -F <name>\t<pid>` (launched?): one tab-separated line per session
                    case "$*" in *"$(printf '\t')"*)
                      printf 'by_app_lead\t%s\nby_desk\t%s\nhand\t%s\n' #{@agent} #{@hermes} #{@agent}; exit 0 ;; esac
                    echo "#{@agent} %7 0 0 0 1700000000 1700000100 1700000200 1 by_app_lead"
                    echo "#{@hermes} %8 0 0 0 1700000000 1700000100 1700000300 1 by_desk"
                    echo "#{@agent} %9 0 0 0 1700000000 1700000100 1700000400 1 hand"; exit 0 ;;
        # bin/launcher's `ls`: the sessions op (tab-separated fields) or bare names (live_session_names)
        ls) case "$*" in *"$(printf '\\t')"*)
              printf 'by_app_lead\\t#{b}/projects/app\\t1\\t0\\nby_desk\\t#{b}/projects/app\\t1\\t0\\nhand\\t#{b}/projects/app\\t1\\t0\\n' ;;
            *) printf 'by_app_lead\\nby_desk\\nhand\\n' ;; esac; exit 0 ;;
        capture-pane) [ "$1" = -S ] && [ -f #{b}/hang-capture ] && exec sleep 3001; printf '❯ \\n'; exit 0 ;;
        display-message) echo "✳ app-7"; exit 0 ;;
        load-buffer) cat > #{b}/pasted; echo "load $*" >> #{b}/inputs; exit 0 ;;
        paste-buffer) [ -f #{b}/hang-paste ] && exec sleep 3001; echo "$cmd $*" >> #{b}/inputs; exit 0 ;;
        send-keys) echo "$cmd $*" >> #{b}/inputs; exit 0 ;;
        # a launch's start: in flight while hold-start exists (the test removes it), then refused — nothing starts
        new-session) touch #{b}/starting; while [ -e #{b}/hold-start ]; do sleep 0.05; done
                     echo "the sandbox starts no session" >&2; exit 1 ;;
      esac
      exit 1
    SH
  end

  def stub(name, body)
    File.write(File.join(@bin, name), "#!/bin/sh\ncmd=\n#{body}")
    File.chmod(0o755, File.join(@bin, name))
  end

  def spawn_up(prog, log, sock)
    path = File.join(@base, log)
    pid = Process.spawn(@env, RbConfig.ruby, File.join(@co, prog), %i[out err] => [path, "w"])
    Wait.for(-> { "#{prog}'s socket: #{File.read(path)}" }, seconds: BOOT_SECONDS, every: 0.1) do
      flunk "#{prog} exited: #{File.read(path)}" if Process.waitpid(pid, Process::WNOHANG)
      File.socket?(sock) && (UNIXSocket.open(sock) { true } rescue false)
    end
    pid
  end

  def launcher_socket = File.join(@base, "run/launcher.sock")

  def launcher(req)
    UNIXSocket.open(launcher_socket) do |s|
      s.puts(JSON.generate(req))
      JSON.parse(s.gets)
    end
  end

  # the launch op of a `plain` session (no lead, no key) in the sandbox's project, as the web's Launch sends it
  def plain_launch(session)
    launcher("op" => "launch", "path" => "/projects/app", "session" => session, "type" => "plain",
             "launcher" => "fullclaude", "settings" => { "id" => 1, "doc" => AGENTS },
             "vars" => { "slug" => "app", "session" => session, "agent" => "a", "type" => "plain", "cards" => "-" })
  end
end
