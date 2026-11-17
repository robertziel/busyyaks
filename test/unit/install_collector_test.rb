# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "etc"
require "yaml"

# deploy/install-collector.sh (card #479) run for real against stub tools (systemctl, tmux, sleep; ruby is the real one:
# the script runs bin/collector --check) in a throwaway checkout: the unit names the checkout, the collector's dir is
# created private, a bad agents.collector stops the install before any unit is written, and a unit that comes up without
# a snapshot fails with its status.
class InstallCollectorTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  COPY = %w[bin/collector lib/busyyaks vendor/agents_kanban/ruby/lib/agents_kanban/session_dialog.rb config/engines.yml
            deploy/install-collector.sh deploy/busyyaks-collector.service].freeze

  def setup
    # under this user's home, never /tmp: the collector's dir's parents must not be writable by another user
    @root = File.realpath(Dir.mktmpdir("install-collector", Etc.getpwuid(Process.uid).dir))
    @dir = File.join(@root, "check#out&co")
    @coll = File.join(@root, "state/collector")
    @bin = File.join(@root, "bin")
    @home = File.join(@root, "home")
    @log = File.join(@root, "systemctl.log")
    FileUtils.mkdir_p([File.join(@dir, "config"), @bin, @home, File.join(@root, "projects")])
    COPY.each do |f|
      FileUtils.mkdir_p(File.dirname(File.join(@dir, f)))
      FileUtils.cp_r(File.join(ROOT, f), File.join(@dir, f))
    end
    File.write(File.join(@dir, ".env"), "PROJECTS_ROOT=#{@root}/projects\nLAUNCHER_RUN_DIR=#{@root}/state/run\n" \
                                        "CLAUDE_SESSIONS_DIR=#{@root}/sessions\n")
    config(@coll)
    stub("tmux", "exit 0")
    stub("sleep", "exit 0")
    File.symlink(RbConfig.ruby, File.join(@bin, "ruby"))
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def config(dir, collector = { "snapshot" => "#{dir}/sessions.json", "read_socket" => "#{dir}/read.sock",
                                       "tmux_timeout_seconds" => 5, "answer_timeout_seconds" => 30, })
    File.write(File.join(@dir, "config/busyyaks.yml"), YAML.dump("agents" => { "collector" => collector }))
  end

  def stub(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  # writes: the unit "started" writes its snapshot on restart (as bin/collector does before it listens)
  def systemctl(active:, writes: true)
    stub("systemctl", <<~SH)
      echo "$*" >> #{@log}
      case "$*" in
        *is-active*) exit #{active ? 0 : 3} ;;
        *" status "*) echo "status of the unit"; exit 3 ;;
        *restart*) #{writes ? "echo '{}' > #{@coll}/sessions.json" : ':'} ;;
      esac
      exit 0
    SH
  end

  def install
    Open3.capture3({ "PATH" => "#{@bin}:/usr/bin:/bin", "HOME" => @home }, "bash",
                   File.join(@dir, "deploy/install-collector.sh"))
  end

  def unit = File.join(@home, ".config/systemd/user/busyyaks-collector.service")

  def test_installs_the_unit_for_this_checkout
    systemctl(active: true)
    out, err, status = install
    assert_equal 0, status.exitstatus, err
    assert_match(/\Abin\/collector: ok · #{Regexp.escape(@coll)}\/sessions.json/, out)
    assert_includes out, "busyyaks-collector.service: active · #{@coll}/sessions.json\n"
    assert_includes out, "next: deploy/install-launcher.sh"
    text = File.read(unit)
    assert_includes text, "WorkingDirectory=#{@dir}\n"
    assert_includes text, "ExecStart=#{File.join(@bin, 'ruby')} #{@dir}/bin/collector\n"
    assert_includes text, "KillMode=process\n"
    assert_equal 0o700, File.stat(@coll).mode & 0o777
    assert_includes File.read(@log), "restart busyyaks-collector.service"
  end

  def test_no_snapshot_after_the_start_fails_with_the_status
    systemctl(active: true, writes: false)
    out, err, status = install
    assert_equal 1, status.exitstatus
    refute_includes out, ": active"
    assert_includes err, "status of the unit"
    assert_includes err, "is not active with a snapshot written since this start at #{@coll}/sessions.json"
  end

  # a snapshot an earlier run left proves nothing: a reinstall whose collector writes none fails
  def test_an_old_snapshot_is_no_proof
    FileUtils.mkdir_p(@coll, mode: 0o700)
    File.write(File.join(@coll, "sessions.json"), "{}")
    systemctl(active: true, writes: false)
    _out, err, status = install
    assert_equal 1, status.exitstatus
    assert_includes err, "is not active with a snapshot written since this start"
  end

  def test_a_bad_collector_config_writes_no_unit
    systemctl(active: true)
    apart = { "snapshot" => "#{@coll}/s.json", "read_socket" => "#{@root}/r.sock", "tmux_timeout_seconds" => 5,
              "answer_timeout_seconds" => 30, }
    { "none" => "agents.collector is none", apart =>
      "same dir", }.each do |c, why|
      config(@coll, c)
      _out, err, status = install
      assert_equal 1, status.exitstatus, c.inspect
      assert_includes err, why
    end
    config(File.join(@root, "state/run/collector"))
    _out, err, status = install
    assert_equal 1, status.exitstatus
    assert_includes err, "overlaps LAUNCHER_RUN_DIR"
    refute File.exist?(unit)
  end
end
