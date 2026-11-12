# frozen_string_literal: true

# Standalone (no test_helper, no app): also runs on the oldest host Ruby yaks supports (scripts/ci/test.sh host).
require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# bin/yaks run for real: a throwaway checkout holding ONLY bin/yaks and the files it requires (so the CLI
# loads on a host without the app's gems), reached through a symlink on PATH from another directory, against stub
# docker / xdg-open that log their argv. The checkout it runs is the symlink's target, whatever the cwd.
class YaksTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FILES = ["bin/yaks", "cli/yaks.rb", *Dir.glob("cli/yaks/*.rb", base: ROOT),
           "lib/busyyaks/env_file.rb", "lib/busyyaks/dashboard_url.rb", "lib/busyyaks/deploy_template.rb",].freeze

  def setup
    @root = File.realpath(Dir.mktmpdir("yaks"))
    # a checkout path with a space and shell specials: argv arrays carry it as one word
    @home = File.join(@root, "my check$out")
    @bin = File.join(@root, "bin")
    @cwd = File.join(@root, "elsewhere")
    @log = File.join(@root, "calls.log")
    FILES.each do |f|
      FileUtils.mkdir_p(File.join(@home, File.dirname(f)))
      FileUtils.cp(File.join(ROOT, f), File.join(@home, f), preserve: true)
    end
    FileUtils.mkdir_p([@bin, @cwd])
    File.write(File.join(@home, ".env"), "PUBLIC_HOST=\nWEB_HOST_PORT=8080\n")
    File.symlink(File.join(@home, "bin/yaks"), File.join(@bin, "yaks"))
    File.symlink(RbConfig.ruby, File.join(@bin, "ruby"))
    %w[docker xdg-open].each { |c| stub(c) }
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def stub(name)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\nprintf '%s' '#{name}' >> '#{@log}'\nfor a; do printf ' [%s]' \"$a\" >> '#{@log}'; done\n" \
                     "echo >> '#{@log}'\n")
    File.chmod(0o755, path)
  end

  def yaks(*argv)
    Open3.capture3({ "PATH" => "#{@bin}:/usr/bin:/bin", "DISPLAY" => ":0" }, "yaks", *argv, chdir: @cwd,
                   unsetenv_others: true)
  end

  def calls = File.exist?(@log) ? File.read(@log) : ""

  def test_logs_run_compose_on_the_symlinked_checkout
    _out, err, status = yaks("server", "logs", "-f", "web")
    assert_equal 0, status.exitstatus, err
    assert_equal "docker [compose] [--project-directory] [#{@home}] [-f] [#{@home}/docker-compose.yml] [logs] " \
                 "[--follow] [web]\n", calls
  end

  def test_panel_opens_the_dashboard
    _out, err, status = yaks("panel")
    assert_equal 0, status.exitstatus, err
    assert_equal "xdg-open [http://127.0.0.1:8080]\n", calls
    out, _err, status = yaks("panel", "--print")
    assert_equal [0, "http://127.0.0.1:8080\n"], [status.exitstatus, out]
  end

  def test_a_usage_error_exits_2
    _out, err, status = yaks("nope")
    assert_equal 2, status.exitstatus
    assert_includes err, 'yaks: unknown command "nope"'
    assert_empty calls
  end
end
