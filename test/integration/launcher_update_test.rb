# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/wait"
require "tmpdir"
require "fileutils"
require "socket"
require "json"
require "etc"
require "open3"
require "yaml"

# bin/launcher's `update` op (card 536), the launcher itself run as a process in a sandbox checkout that is a real git
# clone of a bare "remote": status checks in the background, apply starts the real `bin/yaks update` detached, which
# moves the checkout, runs the stub docker / install-launcher.sh, checks the stack (a stub web + MCP on loopback) and
# records each step in the state dir's update.json.
class LauncherUpdateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BOOT_SECONDS = 60
  COPY = %w[bin/launcher bin/yaks bin/setup cli lib/busyyaks vendor/agents_kanban/ruby/lib config/engines.yml
            config/harnesses.yml].freeze
  FIXTURE = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__))
  GIT_ENV = { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.test", "GIT_COMMITTER_NAME" => "t",
              "GIT_COMMITTER_EMAIL" => "t@example.test", }.freeze

  def setup
    @base = File.realpath(Dir.mktmpdir("launcher-update", Etc.getpwuid(Process.uid).dir))
    @remote = File.join(@base, "remote.git")
    @work = File.join(@base, "work")
    @co = File.join(@base, "checkout")
    @bin = File.join(@base, "bin")
    FileUtils.mkdir_p([File.join(@base, "projects/app/.git"), @bin, File.join(@base, "sessions")])
    sh(@base, "git", "init", "-q", "--bare", "-b", "main", @remote)
    sh(@base, "git", "clone", "-q", @remote, @work)
    sh(@work, "git", "checkout", "-q", "-b", "main")
    # what the checkout keeps untracked: the copied programs, config, .env, data (an update never touches them)
    File.write(File.join(@work, ".gitignore"), "/*\n!/.gitignore\n!/release*.txt\n")
    @v1 = commit("release1")
    sh(@work, "git", "tag", "v1.0.0")
    sh(@work, "git", "push", "-q", "origin", "main", "v1.0.0")
    sh(@base, "git", "clone", "-q", @remote, @co)
    COPY.each do |f|
      FileUtils.mkdir_p(File.dirname(File.join(@co, f)))
      FileUtils.cp_r(File.join(ROOT, f), File.join(@co, f))
    end
    FileUtils.cp(File.join(ROOT, "test/fixtures/kanban.yml"), File.join(@co, "config/kanban.yml"))
    config("origin")
    FileUtils.mkdir_p(File.join(@co, "deploy"))
    File.write(File.join(@co, "deploy/install-launcher.sh"), "#!/bin/sh\necho install-launcher >> #{@base}/docker.log\n")
    File.chmod(0o755, File.join(@co, "deploy/install-launcher.sh"))
    File.write(File.join(@co, "docker-compose.yml"), "x: 1\n")
    @http = stack
    File.write(File.join(@co, ".env"), <<~ENV)
      PROJECTS_ROOT=#{File.join(@base, 'projects')}
      PROJECTS_MOUNT=/projects
      LAUNCHER_RUN_DIR=#{File.join(@base, 'run')}
      LAUNCHER_STATE_DIR=#{File.join(@base, 'state')}
      CLAUDE_SESSIONS_DIR=#{File.join(@base, 'sessions')}
      CLAUDE_SESSION_URL=https://claude.example/{id}
      WEB_HOST_PORT=#{@http.addr[1]}
      MCP_HOST=127.0.0.1
      MCP_HOST_PORT=#{@http.addr[1]}
      MCP_TOKEN=secret-token
      DATABASE_ADAPTER=sqlite
    ENV
    File.chmod(0o600, File.join(@co, ".env"))
    stub("tmux", "exit 1")
    stub("systemctl", "echo active")
    stub("docker", "echo \"$*\" >> #{File.join(@base, 'docker.log')}; " \
                   "case \"$*\" in *' ps '*) printf 'web\\nmcp\\nscanner\\ngithub\\nnotifier\\nwriter\\n';; " \
                   "'image inspect'*) echo sha256:old-image;; esac")
    start
  end

  def teardown
    if @pid && !Process.waitpid(@pid, Process::WNOHANG)
      Process.kill("TERM", @pid)
      Process.wait(@pid)
    end
    @http&.close
    @serve&.kill
    FileUtils.rm_rf(@base)
  end

  def sh(dir, *argv)
    out, st = Open3.capture2e(GIT_ENV, *argv, chdir: dir)
    raise "#{argv.join(' ')}: #{out}" unless st.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(@work, "#{name}.txt"), name)
    sh(@work, "git", "add", ".")
    sh(@work, "git", "commit", "-q", "-m", name)
    sh(@work, "git", "rev-parse", "HEAD")
  end

  def config(remote)
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(FIXTURE.merge(
      "launch" => FIXTURE["launch"].merge("trusted_paths" => []),
      "updates" => { "remote" => remote, "branch" => "main", "tags" => "v*", "channel" => "tags", "check_minutes" => 60 }
    )))
  end

  # /up and MCP tools/list answer 200 (what `yaks server status` asks after the update)
  def stack
    server = TCPServer.new("127.0.0.1", 0)
    @serve = Thread.new do
      loop do
        c = server.accept
        loop { break if [nil, "\r\n"].include?(c.gets) }
        body = JSON.generate(result: { tools: [{}] })
        c.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        c.close
      rescue IOError, SystemCallError
        break
      end
    end
    server
  end

  def stub(name, body)
    File.write(File.join(@bin, name), "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, File.join(@bin, name))
  end

  def start
    @log = File.join(@base, "launcher.log")
    env = { "PATH" => "#{@bin}:/usr/local/bin:/usr/bin:/bin", "HOME" => @base }
    env.merge!(GIT_ENV)
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

  def status = ask(op: "update", step: "status")
  def head = sh(@co, "git", "rev-parse", "HEAD")
  def docker_log
    File.exist?(File.join(@base, "docker.log")) ? File.readlines(File.join(@base, "docker.log"), chomp: true) : []
  end

  def checked
    Wait.for(-> { "a check: #{status.inspect} #{File.read(@log)}" }, seconds: 60, every: 0.1) do
      s = status
      s["check"] && !s["checking"] ? s : nil
    end
    status
  end

  def test_status_checks_in_the_background_then_answers_from_the_record
    v11 = commit("release2")
    sh(@work, "git", "tag", "v1.1.0")
    sh(@work, "git", "push", "-q", "origin", "main", "v1.1.0")
    first = status
    assert first["ok"], first.inspect
    assert_nil first["check"]
    assert_equal({ "remote" => "origin", "branch" => "main", "tags" => "v*", "channel" => "tags", "check_minutes" => 60 },
                 first["settings"])
    s = checked
    assert_equal ["v1.1.0", v11, "available", 1], s["check"]["tag"].values_at("name", "sha", "state", "behind")
    assert_equal [@v1, "main"], s["check"]["head"].values_at("sha", "branch")
    assert s["check"]["available"]
    refute s["running"]
    assert_nil s["last"]
  end

  def test_apply_runs_bin_yaks_update_detached_to_the_end
    v11 = commit("release2")
    sh(@work, "git", "tag", "v1.1.0")
    sh(@work, "git", "push", "-q", "origin", "main", "v1.1.0")
    res = ask(op: "update", step: "apply", mode: "tags", sha: v11)
    assert res["ok"], res.inspect
    assert_match(%r{state/update-\d{8}T\d{6}Z\.log\z}, res.dig("started", "log"))
    Wait.for(-> { "the update: #{status['last'].inspect} #{File.read(res.dig('started', 'log'))}" }, seconds: 60,
             every: 0.2) { %w[done failed].include?(status.dig("last", "state")) }
    last = status["last"]
    assert_equal "done", last["state"], File.read(res.dig("started", "log"))
    assert_equal [@v1, v11, "v1.1.0", res.dig("started", "log"), "sha256:old-image"],
                 last.values_at("from", "to", "name", "log", "previous_image")
    assert_equal v11, head
    log = docker_log
    assert(log.any? { |l| l.include?("exec -T web sqlite3") }, log.inspect)
    assert_includes log, "build -t busyyaks:update-#{v11[0, 12]} #{@co}"
    assert_includes log, "tag busyyaks:update-#{v11[0, 12]} busyyaks:local"
    assert(log.any? { |l| l.include?("up -d --wait --no-build web mcp scanner github notifier writer") }, log.inspect)
    assert_includes log, "install-launcher"
    # the record's HEAD moved: the next status checks again and finds nothing newer
    assert_equal "current", checked.dig("check", "tag", "state")
  end

  def test_apply_refusals
    v11 = commit("release2")
    sh(@work, "git", "tag", "v1.1.0")
    sh(@work, "git", "push", "-q", "origin", "main", "v1.1.0")
    moved = ask(op: "update", step: "apply", mode: "tags", sha: "0" * 40)
    assert_equal [false, 422], moved.values_at("ok", "status")
    assert_match(/moved since it was shown/, moved["error"])
    assert_equal [false, 400], ask(op: "update", step: "apply", mode: "tags", sha: "abc").values_at("ok", "status")
    assert_equal [false, 422], ask(op: "update", step: "apply", mode: "nightly", sha: v11).values_at("ok", "status")
    assert_equal [false, 400], ask(op: "update", step: "bogus").values_at("ok", "status")
    File.write(File.join(@co, "release1.txt"), "changed")
    dirty = ask(op: "update", step: "apply", mode: "tags", sha: v11)
    assert_match(/tracked files changed: release1.txt/, dirty["error"])
    assert_equal @v1, head
    assert_empty docker_log
  end

  # a record an update left "running" (killed: no lock held) is said as interrupted and holds nothing back
  def test_a_record_left_running_without_an_update_is_interrupted
    FileUtils.mkdir_p(File.join(@base, "state"))
    File.write(File.join(@base, "state/update.json"),
               JSON.generate(state: "running", step: "build", log: "/x/update.log", from: @v1))
    last = status["last"]
    assert_equal "interrupted", last["state"]
    assert_match(%r{stopped at build without finishing .* see /x/update\.log}, last["error"])
    refute status["running"]
    v11 = commit("release2")
    sh(@work, "git", "tag", "v1.1.0")
    sh(@work, "git", "push", "-q", "origin", "main", "v1.1.0")
    assert ask(op: "update", step: "apply", mode: "tags", sha: v11)["ok"]
  end

  # a failed check is not fetched again on every status poll: the next one waits check_minutes (or a "Check now")
  def test_a_failed_check_backs_off
    config("nowhere")
    refute ask(op: "update", step: "check")["ok"]
    at = status.dig("check_error", "at")
    refute_nil at
    3.times { refute status["checking"], "no background re-check while the failure is fresh" }
    assert_equal at, status.dig("check_error", "at")
  end

  def test_a_bad_config_or_remote_is_said_never_read_as_up_to_date
    config("nowhere")
    res = ask(op: "update", step: "check")
    assert_equal [false, 422], res.values_at("ok", "status")
    assert_match(/git fetch --no-tags/, res["error"])
    s = status
    assert_match(/git fetch/, s.dig("check_error", "error")) if s["check_error"]
    File.write(File.join(@co, "config/busyyaks.yml"), YAML.dump(FIXTURE.except("updates")))
    bad = ask(op: "update", step: "status")
    assert_equal [false, 422], bad.values_at("ok", "status")
    assert_match(/no updates key/, bad["error"])
  end
end
