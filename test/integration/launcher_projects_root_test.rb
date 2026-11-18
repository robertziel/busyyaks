# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/wait"
require_relative "../../lib/busyyaks/projects_root"
require "tmpdir"
require "fileutils"
require "socket"
require "json"
require "etc"
require "yaml"

# bin/launcher's projects dir ops (card 532), the launcher itself run as a process in a sandbox checkout with a stub
# `docker`: browse lists a host dir, plan checks a new PROJECTS_ROOT, apply rewrites .env, runs compose and exits so
# systemd starts it on the new .env — or, compose failing, puts the old .env back and records why.
class LauncherProjectsRootTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60
  COPY = %w[bin/launcher lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml config/harnesses.yml].freeze
  INVOCATIONS = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands")

  def setup
    @base = File.realpath(Dir.mktmpdir("launcher-root", Etc.getpwuid(Process.uid).dir))
    @co = File.join(@base, "checkout")
    @bin = File.join(@base, "bin")
    @old = File.join(@base, "projects")
    @new = File.join(@base, "code")
    FileUtils.mkdir_p([File.join(@old, "app/.git"), File.join(@base, "checkout/data/app/.git"),
                       File.join(@new, "app/.git"), File.join(@new, "lib/.git"),
                       File.join(@new, ".hidden"), File.join(@new, "notes"), @bin, File.join(@co, "config"),
                       File.join(@base, "sessions"),])
    File.write(File.join(@new, "README"), "a file, never listed")
    COPY.each do |f|
      FileUtils.mkdir_p(File.dirname(File.join(@co, f)))
      FileUtils.cp_r(File.join(ROOT, f), File.join(@co, f))
    end
    FileUtils.cp(File.join(ROOT, "test/fixtures/kanban.yml"), File.join(@co, "config/kanban.yml"))
    config(trusted: ["/projects/app"])
    @env = <<~ENV
      # the sandbox's .env
      PROJECTS_ROOT=#{@old}
      PROJECTS_MOUNT=/projects
      LAUNCHER_RUN_DIR=#{File.join(@base, 'run')}
      LAUNCHER_STATE_DIR=#{File.join(@base, 'state')}
      CLAUDE_SESSIONS_DIR=#{File.join(@base, 'sessions')}
      CLAUDE_SESSION_URL=https://claude.example/{id}
    ENV
    File.write(File.join(@co, ".env"), @env)
    File.chmod(0o600, File.join(@co, ".env"))
    stub("tmux", "exit 1")
    docker(0)
    start
  end

  def teardown
    if @pid && !Process.waitpid(@pid, Process::WNOHANG)
      Process.kill("TERM", @pid)
      Process.wait(@pid)
    end
    FileUtils.rm_rf(@base)
  end

  def config(trusted:)
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(
      "roots" => [{ "path" => "/projects", "prefix" => "" }], "search_depth" => 2,
      "owner_remotes" => ["github.com/you/"], "author_emails" => ["you@example.com"], "window_days" => 7,
      "reap_protect" => [], "auth" => { "provider" => "none" }, "agents" => { "collector" => "none" },
      "dictation" => "none", "terminal" => { "public_host" => "deny", "max_open" => 4 }, "github_hook" => "none",
      "ci" => { "max_pending_minutes" => 60, "required" => { "o/r" => ["jenkins/ci"] } },
      "skills" => { "max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil },
      "launch" => { "trusted_paths" => trusted, "commands" => INVOCATIONS, "start_seconds" => 30, "scopes" => nil }
    ))
  end

  def stub(name, body)
    File.write(File.join(@bin, name), "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, File.join(@bin, name))
  end

  # the stub docker: its argv + the PROJECTS_ROOT .env holds when it runs, one line per run; exits `code`
  def docker(code)
    stub("docker", "echo \"$* | $(grep ^PROJECTS_ROOT= #{File.join(@co, '.env')})\" >> #{File.join(@base, 'docker.log')}; " \
                   "echo compose said no; exit #{code}")
  end

  def docker_runs
    File.exist?(File.join(@base, "docker.log")) ? File.readlines(File.join(@base, "docker.log"), chomp: true) : []
  end

  def start
    @log = File.join(@base, "launcher.log")
    env = { "PATH" => "#{@bin}:/usr/local/bin:/usr/bin:/bin", "HOME" => @base }
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

  def plan(path) = ask(op: "projects_root", step: "plan", path: path)
  def state = JSON.parse(File.read(File.join(@base, "state/projects-root.json")))

  def test_browse_lists_subdirs_only_and_marks_repos
    res = ask(op: "browse", path: @new)
    assert res["ok"], res.inspect
    assert_equal [@new, @base], res.values_at("path", "parent")
    assert_equal [{ "name" => "app", "git" => true }, { "name" => "lib", "git" => true },
                  { "name" => "notes", "git" => false },], res["entries"]
    assert_equal [2, false], res.values_at("repos", "truncated")
    refute ask(op: "browse", path: "relative")["ok"]
    gone = ask(op: "browse", path: File.join(@base, "nope"))
    assert_equal [false, 422], gone.values_at("ok", "status")
  end

  def test_plan_checks_the_new_root_and_names_the_trusted_repo_it_would_trust
    res = plan(@new)
    assert res["ok"], res.inspect
    p = res["plan"]
    assert_equal [@old, @new, 2], p.values_at("from", "to", "repos")
    assert_equal [{ "path" => "/projects", "host" => @new }], p["roots"]
    assert_equal [{ "path" => "/projects/app", "from" => File.join(@old, "app"), "to" => File.join(@new, "app") }],
                 p["trusted"]
    assert_equal [], p["loses_trust"] # this launcher's create made nothing here
    assert_equal %w[web mcp scanner github notifier], p["services"]
    assert_match(/\A\h{64}\z/, p["plan_id"])
  end

  def test_plan_refusals
    {
      @old => /already the projects dir/,
      "/" => /whole disk/,
      "code" => /absolute path/,
      File.join(@base, "nope") => /No such file/,
      File.join(@new, "notes") => %r{trusted_paths /projects/app .*launcher would not start},
      @base => /overlaps LAUNCHER_RUN_DIR/,
      File.join(@co, "data") => %r{lies in ./data},
      "#{@new}/" => /real path/,
    }.each do |path, why|
      res = plan(path)
      assert_equal [false, 422], res.values_at("ok", "status"), "#{path}: #{res.inspect}"
      assert_match why, res["error"], path
    end
    assert_empty docker_runs
  end

  # a second apply while compose runs is refused; the stub docker waits on a fifo the test then writes
  def test_one_apply_at_a_time
    fifo = File.join(@base, "go")
    File.mkfifo(fifo)
    # only the first run (the apply's) waits; the rollback's compose run must not block on the drained fifo
    once = File.join(@base, "waited")
    stub("docker", "[ -e #{once} ] || { touch #{once}; cat #{fifo} > /dev/null; }; exit 1")
    id = plan(@new)["plan"]["plan_id"]
    assert ask(op: "projects_root", step: "apply", path: @new, plan_id: id)["ok"]
    again = ask(op: "projects_root", step: "apply", path: @new, plan_id: id)
    assert_equal [false, 409, "a projects dir change is already running"], again.values_at("ok", "status", "error")
    assert ask(op: "projects_root", step: "status")["applying"]
    File.write(fifo, "go")
    Wait.for(-> { "the failure record: #{File.read(@log)}" }, seconds: 60, every: 0.1) do
      !ask(op: "projects_root", step: "status")["applying"]
    end
    assert_equal %w[failed restored], state.values_at("state", "env")
  end

  # the apply's record cannot be written (a dir where the file goes; root in the test container too): refused with
  # the reason, the .env it had rewritten put back, nothing run, the next apply may run
  def test_a_failed_start_puts_the_env_back_and_leaves_nothing_running
    id = plan(@new)["plan"]["plan_id"]
    FileUtils.mkdir_p(File.join(@base, "state/projects-root.json/x"))
    res = ask(op: "projects_root", step: "apply", path: @new, plan_id: id)
    assert_equal [false, 500], res.values_at("ok", "status")
    assert_match(/projects-root\.json/, res["error"])
    assert_equal @env, File.read(File.join(@co, ".env"))
    assert_empty docker_runs
    refute ask(op: "projects_root", step: "status")["applying"]
  end

  # compose succeeded but neither the log nor the record can be written (dirs where the files go): the launcher still
  # restarts on the new .env — the services already run on the new dir
  def test_a_compose_that_succeeded_restarts_the_launcher_even_when_nothing_can_be_recorded
    id = plan(@new)["plan"]["plan_id"]
    st = File.join(@base, "state")
    # the log is named by the apply's stamp, the backup's too: the stub reads it there
    stub("docker", "b=$(ls #{st} | grep env.bak-projects-root-); s=${b##*-}; " \
                   "for f in #{st}/projects-root-$s.log #{st}/projects-root.json; " \
                   "do rm -f \"$f\"; mkdir -p \"$f/x\"; done; exit 0")
    assert ask(op: "projects_root", step: "apply", path: @new, plan_id: id)["ok"]
    Wait.for(-> { "the launcher's exit: #{File.read(@log)}" }, seconds: 60, every: 0.1) { Process.waitpid(@pid, Process::WNOHANG) }
    @pid = nil
    assert_equal "PROJECTS_ROOT=#{@new}", File.read(File.join(@co, ".env"))[/^PROJECTS_ROOT=.*$/]
    log = File.read(@log)
    assert_match(/log .* NOT written/, log)
    assert_match(/record NOT written/, log)
    assert_match(/restarting the launcher on the new \.env/, log)
    # started again on the new .env: the record still says applying — status answers what the launcher knows
    FileUtils.rm_rf(File.join(@base, "state/projects-root.json"))
    Busyyaks::ProjectsRoot.record!(File.join(@base, "state"), { "state" => "applying", "from" => @old, "to" => @new,
                                                                "env" => "new", "log" => "l", "at" => "t", })
    start
    last = ask(op: "projects_root", step: "status")["last"]
    assert_equal ["done", @new], last.values_at("state", "to")
    assert_match(/record was not finished/, last["note"])
  end

  # the .env cannot be rewritten (two PROJECTS_ROOT lines appear after the check): refused before anything is
  # written — no backup, nothing run, the next apply may run. (An Errno from the write cannot be forced here: the
  # test container runs as root.)
  def test_an_env_that_cannot_be_rewritten_refuses_and_leaves_nothing_running
    id = plan(@new)["plan"]["plan_id"]
    File.write(File.join(@co, ".env"), "#{@env}PROJECTS_ROOT=#{@old}\n")
    res = ask(op: "projects_root", step: "apply", path: @new, plan_id: id)
    assert_equal [false, 422], res.values_at("ok", "status")
    assert_match(/2 PROJECTS_ROOT lines/, res["error"])
    assert_empty docker_runs
    assert_empty Dir.children(File.join(@base, "state")).grep(/env\.bak/)
    refute ask(op: "projects_root", step: "status")["applying"]
  end

  def test_apply_needs_the_plan_it_was_shown
    res = ask(op: "projects_root", step: "apply", path: @new, plan_id: "0" * 64)
    assert_equal [false, 409], res.values_at("ok", "status")
    assert_equal @env, File.read(File.join(@co, ".env"))
    assert_empty docker_runs
  end

  def test_apply_rewrites_env_recreates_the_services_and_restarts_the_launcher
    id = plan(@new)["plan"]["plan_id"]
    res = ask(op: "projects_root", step: "apply", path: @new, plan_id: id)
    assert res["ok"], res.inspect
    assert_equal "applying", res["state"]["state"]
    Wait.for(-> { "the launcher's exit: #{File.read(@log)}" }, seconds: 60, every: 0.1) { Process.waitpid(@pid, Process::WNOHANG) }
    @pid = nil
    assert_equal @env.sub("PROJECTS_ROOT=#{@old}", "PROJECTS_ROOT=#{@new}"), File.read(File.join(@co, ".env"))
    assert_equal 0o600, File.stat(File.join(@co, ".env")).mode & 0o777
    assert_equal ["compose --project-directory #{@co} up -d --wait --no-build web mcp scanner github notifier | " \
                  "PROJECTS_ROOT=#{@new}"], docker_runs
    st = state
    assert_equal ["done", @old, @new], st.values_at("state", "from", "to")
    assert_equal @env, File.read(st["backup"])
    assert_equal File.join(@base, "state"), File.dirname(st["backup"]) # the launcher's state dir, not the checkout
    assert_empty Dir.children(@co).grep(/\.env\./)
    assert_equal 0o600, File.stat(st["backup"]).mode & 0o777
    # started again (systemd's part), it runs on the new root and reports the change
    start
    s = ask(op: "projects_root", step: "status")
    assert_equal [@new, false, "done"], [s["current"], s["applying"], s["last"]["state"]]
  end

  def test_a_failed_compose_puts_the_old_env_back
    docker(1)
    id = plan(@new)["plan"]["plan_id"]
    assert ask(op: "projects_root", step: "apply", path: @new, plan_id: id)["ok"]
    Wait.for(-> { "the failure record: #{File.read(@log)}" }, seconds: 60, every: 0.1) do
      File.exist?(File.join(@base, "state/projects-root.json")) && state["state"] == "failed"
    end
    assert_equal @env, File.read(File.join(@co, ".env"))
    assert_equal ["PROJECTS_ROOT=#{@new}", "PROJECTS_ROOT=#{@old}"], docker_runs.map { |l| l.split(" | ").last }
    assert_match(/compose up exit 1: compose said no/, state["error"])
    assert_equal [false, "restored"], state.values_at("rolled_back", "env")
    s = ask(op: "projects_root", step: "status") # still running, on the old root
    assert_equal [@old, false], s.values_at("current", "applying")
  end
end
