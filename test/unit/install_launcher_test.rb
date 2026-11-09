# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "etc"

# deploy/install-launcher.sh run for real against stub tools (systemctl, git, tmux, claude; ruby is the real one: the
# script reads .env through bin/env) in a throwaway
# checkout: a successful install exits 0 however long `systemctl status` is (`status | head -5` under
# pipefail exited 141 from SIGPIPE), and a unit that is not active after the restart fails loudly with its status.
class InstallLauncherTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "deploy/install-launcher.sh")
  UNIT = File.join(ROOT, "deploy/busyyaks-launcher.service")
  # what the script runs from its own checkout: the one .env reader and the file it requires
  ENV_READER = %w[bin/env lib/busyyaks/env_file.rb lib/busyyaks/launcher_rules.rb].freeze

  def setup
    # under this user's home, never /tmp: the run dir's parents must not be writable by another user
    @root = File.realpath(Dir.mktmpdir("install-launcher", Etc.getpwuid(Process.uid).dir))
    # a checkout path holding sed's specials: the rendered unit must still name it exactly
    @dir = File.join(@root, "check#out&co")
    @run = File.join(@root, "state/run")
    @projects = File.join(@root, "projects")
    FileUtils.mkdir_p(@projects)
    @bin = File.join(@root, "bin")
    @home = File.join(@root, "home")
    @log = File.join(@root, "systemctl.log")
    FileUtils.mkdir_p([File.join(@dir, "deploy"), File.join(@dir, "config"), @bin, @home])
    ENV_READER.each do |f|
      FileUtils.mkdir_p(File.join(@dir, File.dirname(f)))
      FileUtils.cp(File.join(ROOT, f), File.join(@dir, f), preserve: true)
    end
    FileUtils.cp(SCRIPT, File.join(@dir, "deploy"))
    FileUtils.cp(UNIT, File.join(@dir, "deploy"))
    write_env(@run)
    %w[busyyaks.yml kanban.yml].each { |f| File.write(File.join(@dir, "config", f), "{}\n") }
    %w[git tmux claude].each { |c| stub(c, "exit 0") }
    File.symlink(RbConfig.ruby, File.join(@bin, "ruby"))
    stub("sleep", "exit 0")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_an_active_unit_exits_zero_with_a_long_status
    systemctl(active: true)
    out, err, status = install
    assert_equal 0, status.exitstatus, err
    assert_equal "busyyaks-launcher.service: active\n", out
    refute_includes File.read(@log), "status", "an active unit's status is not printed"
    assert_includes File.read(@log), "restart busyyaks-launcher.service"
    assert File.exist?(File.join(@home, ".config/systemd/user/busyyaks-launcher.service"))
  end

  def test_an_inactive_unit_fails_with_its_status
    systemctl(active: false)
    out, err, status = install
    assert_equal 1, status.exitstatus
    assert_empty out
    assert_includes err, "status line 1999"
    assert_includes err, "(systemctl status exited 3)"
    assert_includes err, "busyyaks-launcher.service is not active after the restart"
  end

  def test_the_unit_names_the_checkout_and_the_run_dir_is_private
    systemctl(active: true)
    _out, err, status = install
    assert_equal 0, status.exitstatus, err
    unit = File.read(File.join(@home, ".config/systemd/user/busyyaks-launcher.service"))
    assert_includes unit, "WorkingDirectory=#{@dir}\n"
    assert_includes unit, "ExecStart=#{File.join(@bin, "ruby")} #{@dir}/bin/launcher"
    assert_equal 0o700, File.stat(@run).mode & 0o777
  end

  def test_a_run_dir_under_data_is_refused
    systemctl(active: true)
    write_env(File.join(@dir, "data/run"))
    _out, err, status = install
    assert_equal 1, status.exitstatus
    assert_includes err, "overlaps the busyyaks checkout"
    refute File.exist?(File.join(@home, ".config/systemd/user/busyyaks-launcher.service"))
  end

  def test_a_relative_run_dir_is_refused
    systemctl(active: true)
    write_env("run")
    _out, err, status = install
    assert_equal 1, status.exitstatus
    assert_includes err, "must be an absolute path"
  end

  def test_a_run_dir_under_projects_root_is_refused
    systemctl(active: true)
    write_env(File.join(@projects, "busyyaks/run"))
    _out, err, status = install
    assert_equal 1, status.exitstatus
    assert_includes err, "overlaps PROJECTS_ROOT"
  end

  private

  def write_env(run_dir)
    File.write(File.join(@dir, ".env"), "HOST_UID=#{Process.uid}\nHOST_GID=#{Process.gid}\nLAUNCHER_RUN_DIR=#{run_dir}\n" \
                                        "PROJECTS_ROOT=#{@projects}\n")
  end

  def stub(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  # `status` prints far more than a pipe buffer, as a real unit with a long journal does, and exits 3 (inactive)
  def systemctl(active:)
    stub("systemctl", <<~SH)
      echo "$*" >> #{@log}
      case "$*" in
        *is-active*) exit #{active ? 0 : 3} ;;
        *" status "*) i=0; while [ $i -lt 2000 ]; do echo "status line $i"; i=$((i+1)); done; exit 3 ;;
      esac
      exit 0
    SH
  end

  def install
    env = { "PATH" => "#{@bin}:/usr/bin:/bin", "HOME" => @home }
    Open3.capture3(env, "bash", File.join(@dir, "deploy/install-launcher.sh"))
  end
end
