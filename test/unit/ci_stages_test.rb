# frozen_string_literal: true

# Standalone (no test_helper, no app, no git): runs on the oldest host Ruby (scripts/ci/test.sh host). The stages' own
# logic is test/unit/ci_gates_test.rb's; this is how test.sh reads its ARGUMENTS: `test.sh lint frontend`
# once ran lint alone, quietly.
require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

# scripts/ci/test.sh copied into a temp dir with stub lint scripts and a stub `docker` that logs its argv.
class CiStagesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # docker: logs; `info` answers rootful, `inspect` (inside a container: host_path) maps the dir to itself
  DOCKER = <<~SH
    #!/bin/sh
    printf '%s\\n' "$*" >> "$STUB_LOG"
    case "$1" in
      inspect) printf '%s|%s\\n' "$STUB_DIR" "$STUB_DIR" ;;
      info) echo '["name=seccomp"]' ;;
      run) case "$*" in *"$STUB_FAIL"*) [ -n "$STUB_FAIL" ] && exit 1 ;; esac ;;
    esac
    exit 0
  SH
  # a lint wrapper: logs its name, fails when it is LINT_FAIL
  LINT = <<~SH
    #!/bin/sh
    echo "lint: $(basename "$0")" >> "$STUB_LOG"
    [ "$(basename "$0")" != "$LINT_FAIL" ]
  SH

  def setup
    @dir = File.realpath(Dir.mktmpdir("ci-stages"))
    @log = File.join(@dir, "calls.log")
    { "scripts/ci/test.sh" => File.read(File.join(ROOT, "scripts/ci/test.sh")),
      "scripts/ci/runner.env" => File.read(File.join(ROOT, "scripts/ci/runner.env")),
      "scripts/ci/host-tests" => File.read(File.join(ROOT, "scripts/ci/host-tests")),
      "scripts/lint/rubocop" => LINT, "scripts/lint/shellcheck" => LINT, "bin/docker" => DOCKER, }.each do |rel, body|
      FileUtils.mkdir_p(File.dirname(File.join(@dir, rel)))
      File.write(File.join(@dir, rel), body)
      File.chmod(0o755, File.join(@dir, rel))
    end
  end

  def teardown = FileUtils.rm_rf(@dir)

  def ci(*args, lint_fail: "", fail: "")
    env = { "PATH" => "#{@dir}/bin:#{ENV.fetch('PATH')}", "STUB_LOG" => @log, "STUB_DIR" => @dir,
            "LINT_FAIL" => lint_fail, "STUB_FAIL" => fail, "DOCKER_HOST" => nil, "BUILD_TAG" => nil, }
    out, err, st = Open3.capture3(env, File.join(@dir, "scripts/ci/test.sh"), *args, chdir: @dir)
    [st.exitstatus, out, err]
  end

  def calls = File.exist?(@log) ? File.readlines(@log, chomp: true) : []

  def runs = calls.select { _1.start_with?("run ") }

  def test_several_stages_run_in_order_and_each_is_summed_up
    code, out, err = ci("lint", "host")
    assert_equal [0, ""], [code, err]
    assert_operator out.index("════ lint ════"), :<, out.index("════ host ════")
    assert_includes out, "ci: lint exit 0 · host exit 0"
    order = calls.grep(/\Alint: |\Arun .*ruby:3\.2\.3/).map { _1[/\Alint: \S+|ruby:3\.2\.3/] }
    assert_equal ["lint: rubocop", "lint: shellcheck", "ruby:3.2.3"], order
    assert_equal 2, runs.size, "host: the Ruby tests + the Quickstart replay"
  end

  # a red stage does not stop the next one; the run fails naming each red one
  def test_a_red_stage_fails_the_run_and_the_rest_still_runs
    code, out, err = ci("lint", "host", lint_fail: "shellcheck")
    assert_equal 1, code
    assert_includes out, "ci: lint exit 1 · host exit 0"
    assert_includes err, "ci: failed: lint"
    assert_equal 2, runs.size, "host ran after the red lint"
    code, out, err = ci("host", "lint", fail: "quickstart-test")
    assert_equal 1, code
    assert_includes out, "ci: host exit 1 · lint exit 0"
    assert_includes err, "ci: failed: host"
  end

  def test_one_stage_runs_alone_with_its_own_exit
    code, out, = ci("lint", lint_fail: "rubocop")
    assert_equal 1, code
    refute_includes out, "════"
    assert_empty runs
  end

  # refused before any Docker call: a typo never runs a subset
  def test_an_unknown_stage_or_all_beside_another_is_refused_first
    [%w[lint frontnd], %w[all lint], %w[lint all], []].each do |args|
      code, _, err = ci(*args)
      assert_equal 2, code, args.inspect
      assert_includes err, "usage:", args.inspect
      assert_empty calls, args.inspect
    end
    assert_includes ci("lint", "frontnd")[2], "ci: unknown stage 'frontnd'"
    assert_includes ci("all", "lint")[2], "ci: 'all' runs every stage: name it alone"
  end
end
