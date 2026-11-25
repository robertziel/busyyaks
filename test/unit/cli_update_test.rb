# frozen_string_literal: true

# Standalone (no test_helper, no app): `yaks update` (card 536) in-process on a REAL git checkout cloned from a bare
# "remote" — git runs for real, docker / install-launcher.sh are recorded (and made to fail where a test says).
require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "socket"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../../cli/yaks"

class CliUpdateTest < Minitest::Test
  CLI = Busyyaks::CLI
  GIT_ENV = { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.test", "GIT_COMMITTER_NAME" => "t",
              "GIT_COMMITTER_EMAIL" => "t@example.test", }.freeze

  # git for real; every other program recorded, `fail` = the argv heads that exit non-zero
  class Runner
    attr_reader :calls

    def initialize(fail: [], ps: CLI::SERVICES, raise_on: nil, no_image: false)
      @no_image = no_image
      @fail = fail
      @raise_on = raise_on
      @ps = ps
      @calls = []
    end

    def which(name) = "/usr/bin/#{name}"

    attr_reader :git_opts

    def capture_all(*argv, env: {}, timeout: nil)
      raise "unexpected #{argv.inspect}" unless argv.first == "git"

      @git_opts = { env: env, timeout: timeout }
      out, err, st = Open3.capture3(GIT_ENV.merge(env), *argv)
      [out, err, st.exitstatus]
    end

    def capture(*argv)
      @calls << [:capture, argv]
      return ["#{@ps.join("\n")}\n", true] if argv.include?("ps")
      return ["active\n", true] if argv.first == "systemctl"
      return (@no_image ? ["", false] : ["sha256:old-image\n", true]) if argv.first(3) == %w[docker image inspect]

      ["", true]
    end

    def system(*argv)
      @calls << [:system, argv]
      raise Errno::ENOSPC, argv.join(" ") if @raise_on && argv.include?(@raise_on)
      @fail.none? { |head| argv.first(head.size) == head || argv.include?(head.last) && argv.first == head.first }
    end

    def spawn(*argv, out:, err:)
      @calls << [:spawn, argv]
      out.write("PGDMP")
      Process.spawn("true")
    end
  end

  class Http
    def get(*) = [200, "ok"]
    def post(*) = [200, JSON.generate(result: { tools: [{}] })]
  end

  def setup
    @dir = File.realpath(Dir.mktmpdir("yaks-update"))
    @remote = File.join(@dir, "remote.git")
    @work = File.join(@dir, "work")
    @home = File.join(@dir, "home")
    @state = File.join(@dir, "state")
    @run = File.join(@dir, "run")
    FileUtils.mkdir_p([@state, @run])
    File.chmod(0o700, @run)
    sh(@dir, "git", "init", "-q", "--bare", "-b", "main", @remote)
    sh(@dir, "git", "clone", "-q", @remote, @work)
    sh(@work, "git", "checkout", "-q", "-b", "main")
    File.write(File.join(@work, ".gitignore"), ".env\nconfig/busyyaks.yml\ndata/\ndocker-compose.yml\n")
    @v1 = commit("one")
    sh(@work, "git", "tag", "v1.0.0")
    sh(@work, "git", "push", "-q", "origin", "main", "v1.0.0")
    sh(@dir, "git", "clone", "-q", @remote, @home)
    FileUtils.mkdir_p(File.join(@home, "config"))
    File.write(File.join(@home, "config/busyyaks.yml"),
               YAML.dump("updates" => { "remote" => "origin", "branch" => "main", "tags" => "v*", "channel" => "tags",
                                        "check_minutes" => 60, }))
    File.write(File.join(@home, "docker-compose.yml"), "x: 1\n")
    write_env("sqlite")
    @runner = Runner.new
  end

  def teardown = FileUtils.rm_rf(@dir)

  def write_env(adapter)
    File.write(File.join(@home, ".env"), <<~ENV)
      WEB_HOST_PORT=8080
      MCP_HOST=127.0.0.1
      MCP_HOST_PORT=8081
      MCP_TOKEN=secret-token
      LAUNCHER_RUN_DIR=#{@run}
      LAUNCHER_STATE_DIR=#{@state}
      DATABASE_ADAPTER=#{adapter}
    ENV
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

  def release(name, tag: nil)
    sha = commit(name)
    sh(@work, "git", "tag", tag) if tag
    sh(@work, "git", "push", "-q", "origin", "main", *tag)
    sha
  end

  def head = sh(@home, "git", "rev-parse", "HEAD")
  def record = JSON.parse(File.read(File.join(@state, "update.json")))

  def yaks(*argv)
    out = StringIO.new
    err = StringIO.new
    sock = UNIXServer.new(File.join(@run, "launcher.sock"))
    code = CLI.run(["update", *argv], home: @home, env: { "PATH" => "/usr/bin" }, out: out, err: err, os: "Linux",
                                      ruby: "3.4.1", runner: @runner, http: Http.new)
    [code, out.string, err.string]
  ensure
    sock&.close
    FileUtils.rm_f(File.join(@run, "launcher.sock"))
  end

  def compose(*args) = ["docker", "compose", "--project-directory", @home, "-f", "#{@home}/docker-compose.yml", *args]

  def systems = @runner.calls.select { |k, _| k == :system }.map(&:last)

  def test_check_prints_and_changes_nothing
    v11 = release("two", tag: "v1.1.0")
    code, out, = yaks("--check")
    assert_equal 0, code
    assert_match(/^newest tag\s+v1.1.0 #{v11[0, 7]} · available, 1 commits$/, out)
    assert_match(%r{^origin/main\s+main #{v11[0, 7]} · available, 1 commits$}, out)
    assert_match(/^update available \(channel tags\)$/, out)
    assert_equal @v1, head
    assert_empty @runner.calls
    refute File.exist?(File.join(@state, "update.json"))
  end

  def test_update_to_the_newest_tag_runs_the_deploy_steps_in_order
    v11 = release("two", tag: "v1.1.0")
    release("three") # the branch moves on: the tag is the target, not the branch head
    code, out, err = yaks
    assert_equal 0, code, err
    assert_equal v11, head
    assert_equal "main", sh(@home, "git", "symbolic-ref", "--short", "HEAD")
    built = "busyyaks:update-#{v11[0, 12]}"
    # the build under its own tag; the backup right before busyyaks:local is moved to it and compose starts it
    # the new version's secrets first (bin/setup secrets: a key it added is written before compose reads it)
    assert_equal [File.join(@home, "bin", "setup"), "secrets"], systems[0]
    assert_equal ["docker", "build", "-t", built, @home], systems[1]
    backup = systems[2]
    assert_equal compose("exec", "-T", "web", "sqlite3", "/data/busyyaks.sqlite3"), backup[0..-2]
    assert_match(%r{\AVACUUM INTO '/data/backups/busyyaks-update-\d{8}T\d{6}Z\.sqlite3'\z}, backup.last)
    assert_equal [["docker", "tag", built, "busyyaks:local"],
                  compose("up", "-d", "--wait", "--no-build", *CLI::SERVICES),
                  [File.join(@home, "deploy", "install-launcher.sh")],], systems.drop(3)
    assert_includes out, "updated to v1.1.0 #{v11[0, 7]}"
    r = record
    assert_equal ["done", nil, "tags", @v1, v11, "v1.1.0"], r.values_at("state", "step", "mode", "from", "to", "name")
    assert_match(%r{/data/backups/busyyaks-update-.*\.sqlite3\z}, r["backup"])
  end

  def test_main_follows_the_branch_head
    tip = release("two")
    code, _, err = yaks("--main")
    assert_equal 0, code, err
    assert_equal tip, head
    assert_equal "branch", record["mode"]
  end

  def test_a_failed_build_puts_the_checkout_back_and_restarts_nothing
    release("two", tag: "v1.1.0")
    @runner = Runner.new(fail: [%w[docker build]])
    code, _, err = yaks
    assert_equal 1, code
    assert_equal @v1, head
    assert_includes err, "build: docker build failed — the checkout is back on #{@v1[0, 7]}, the stack unchanged"
    refute(systems.any? { |a| a.include?("up") })
    assert_equal %w[failed build], record.values_at("state", "step")
  end

  def test_a_failed_backup_puts_the_checkout_back_and_leaves_the_live_image_alone
    release("two", tag: "v1.1.0")
    @runner = Runner.new(fail: [%w[docker exec]])
    code, _, err = yaks
    assert_equal 1, code
    assert_equal @v1, head
    assert_includes err, "backup: the SQLite backup (VACUUM INTO) failed — the checkout is back on #{@v1[0, 7]}"
    refute(systems.any? { |a| a.first(2) == %w[docker tag] || a.include?("up") })
    assert_equal %w[failed backup], record.values_at("state", "step")
  end

  # no busyyaks:local to come back to: refused before the backup, the checkout back, nothing tagged or started
  def test_a_failed_image_inspect_puts_the_checkout_back
    release("two", tag: "v1.1.0")
    @runner = Runner.new(no_image: true)
    code, _, err = yaks
    assert_equal 1, code
    assert_equal @v1, head
    assert_includes err, "backup: docker image inspect busyyaks:local failed: no image to come back to — the checkout " \
                         "is back on #{@v1[0, 7]}, the stack unchanged"
    refute_includes err, "migrated database"
    refute(systems.any? { |a| a.first(2) == %w[docker tag] || a.include?("up") || a.include?("exec") })
    assert_equal %w[failed backup], record.values_at("state", "step")
  end

  # anything that is not a refusal is recorded as a failure too: never a "running" left behind
  def test_an_unexpected_error_is_recorded_failed
    release("two", tag: "v1.1.0")
    @runner = Runner.new(raise_on: "build")
    code, _, err = yaks
    assert_equal 1, code
    assert_includes err, "build: Errno::ENOSPC"
    assert_includes err, "the checkout is back on #{@v1[0, 7]}"
    assert_equal @v1, head
    assert_equal %w[failed build], record.values_at("state", "step")
  end

  def test_a_failed_compose_up_is_not_undone_and_names_the_backup_and_the_previous_commit
    v11 = release("two", tag: "v1.1.0")
    @runner = Runner.new(fail: [%w[docker up]])
    code, _, err = yaks
    assert_equal 1, code
    assert_equal v11, head
    r = record
    assert_equal %w[failed up], r.values_at("state", "step")
    assert_includes r["error"], "up: docker compose up failed"
    assert_includes r["error"], "backup #{r['backup']}, previous commit #{@v1}, previous image sha256:old-image"
    assert_equal "sha256:old-image", r["previous_image"]
    assert_includes err, "migrated database"
  end

  def test_postgres_is_dumped_through_the_postgres_service
    write_env("postgresql")
    release("two", tag: "v1.1.0")
    code, _, err = yaks
    assert_equal 0, code, err
    spawn = @runner.calls.find { |k, _| k == :spawn }.last
    assert_equal compose("exec", "-T", "postgres", "sh", "-c"), spawn[0..-2]
    assert_includes spawn.last, "pg_dump -h /var/run/postgresql"
    assert_equal "PGDMP", File.read(record["backup"])
    assert_equal 0o600, File.stat(record["backup"]).mode & 0o777
  end

  def test_refusals_change_nothing
    code, _, err = yaks
    assert_equal 1, code
    assert_includes err, "already on the newest v* tag"
    assert_equal "failed", record["state"]

    release("two", tag: "v1.1.0")
    File.write(File.join(@home, "one.txt"), "changed")
    code, _, err = yaks
    assert_equal 1, code
    assert_includes err, "tracked files changed: one.txt"
    assert_equal @v1, head
    assert_empty systems

    sh(@home, "git", "checkout", "-q", "one.txt")
    code, _, err = yaks("--expect", "0" * 40)
    assert_equal 1, code
    assert_includes err, "moved since it was shown"
    assert_equal 2, yaks("--expect", "abc").first
    assert_empty systems
  end

  # every git call has a deadline and no terminal prompt; one that never answers is killed and named
  def test_git_calls_have_a_deadline_and_a_stalled_one_is_killed
    release("two", tag: "v1.1.0")
    yaks("--check")
    assert_equal({ env: Busyyaks::Updates::GIT_ENV, timeout: Busyyaks::Updates::GIT_TIMEOUT_S }, @runner.git_opts)
    bin = File.join(@dir, "stall")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "git"), "#!/bin/sh\nexec sleep 600\n")
    File.chmod(0o755, File.join(bin, "git"))
    ctx = CLI::Context.new(home: @home, env: {}, runner: CLI::Runner.new({ "PATH" => bin }), out: StringIO.new,
                           err: StringIO.new, os: "Linux", ruby: RUBY_VERSION, http: Http.new, stdin: StringIO.new)
    git = CLI::Update.git_for(ctx, timeout: 0.2)
    e = assert_raises(CLI::Refused) { git.call(%w[fetch origin]) }
    assert_equal "git -C #{@home} fetch did not finish within 0.2 s: killed", e.message
  end

  def test_one_update_at_a_time
    release("two", tag: "v1.1.0")
    held = Busyyaks::Updates.lock(@state)
    code, _, err = yaks
    assert_equal 1, code
    assert_includes err, "an update is already running"
    assert_equal @v1, head
  ensure
    held&.close
  end
end
