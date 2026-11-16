# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# The gate scripts' own logic: scripts/ci/test.sh (secrets, audit, all, host_path) and scripts/hooks/run, each copied
# into a throwaway git repo and run there with a stub `docker` on PATH that records its argv, answers `inspect` with
# STUB_MOUNT as the container's one mount (the fixture by default, so host_path resolves inside a container too) and
# exits DOCKER_EXIT for a call whose argv matches DOCKER_FAIL (an ERE), 0 otherwise. Every refusal must fail BEFORE any
# container starts; a passing run must hand Docker exactly the mounts and flags the gate depends on; a failing
# container must fail its stage and `all`. The containers themselves (gitleaks, overcommit, the suites) run in the real
# CI stages.
class CiGatesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  TEST_SH = File.join(ROOT, "scripts/ci/test.sh")
  RUNNER_ENV = File.join(ROOT, "scripts/ci/runner.env")
  HOOKS_RUN = File.join(ROOT, "scripts/hooks/run")

  STUB_DOCKER = <<~SH
    #!/bin/sh
    printf '%s\\n' "$*" >> "$DOCKER_LOG"
    # a run's compose override (the runner's pin, the flake repeats), kept for the test: the script removes it after
    for a; do case "$a" in */compose.ci.yml) cat "$a" >> "$DOCKER_LOG.yml" ;; esac; done
    case "$1" in
      inspect) printf '%s|%s\\n' "$STUB_MOUNT" "$STUB_MOUNT" ;;
      info) case "$*" in *NCPU*) echo "$STUB_NCPU" ;; esac ;;
      image) exit 0 ;;
      pull) printf '%s\\n' "$STUB_PULL_NOISE" >&2; [ -z "$STUB_PULL_FAIL" ] || exit 1; exit 0 ;;
      *) # the quota probe: what cpu.max says in a container given --cpus (stdout), docker's own noise
         # (a pull's progress, a warning) on stderr
         case "$*" in "run "*" cat /sys/fs/cgroup/cpu.max") printf '%s\\n' "$STUB_PIN_ERR" >&2; printf '%s\\n' "$STUB_PIN"; exit 0 ;; esac
         # the ruby-pg smoke's wrong-password probe: a real PostgreSQL refuses it, so a passing run must see the refusal
         if printf '%s' "$*" | grep -q -- "POSTGRES_PASSWORD=wrong"; then echo "password authentication failed"; exit 1; fi
         if [ -n "$DOCKER_FAIL" ] && printf '%s' "$*" | grep -qE -- "$DOCKER_FAIL"; then exit "$DOCKER_EXIT"; fi ;;
    esac
  SH
  # scripts/hooks/image builds the hooks image from a dozen inputs; the fixture's prints a tag (run's own logic is tested)
  STUB_IMAGE = "#!/usr/bin/env bash\necho busyyaks:hooks-stub\n"
  # the lint wrappers and the lint image script, for `audit` / `all` (their own runs are the lint stage's business)
  STUB_OK = "#!/bin/sh\necho stub\n"
  # the stages `all` runs, as the script lists them
  STAGES = File.read(TEST_SH)[/^STAGES=\((.+)\)$/, 1].split

  def setup
    @dir = File.realpath(Dir.mktmpdir("ci-gates"))
    @bin = File.join(@dir, "bin")
    @log = File.join(@dir, "docker.log")
    FileUtils.mkdir_p(@bin)
    write_exe(File.join(@bin, "docker"), STUB_DOCKER)
  end

  def teardown = FileUtils.rm_rf(@dir)

  # what a pull prints on a fresh image cache
  PULL_NOISE = "Unable to find image 'docker:28.5.2-cli' locally\n28.5.2-cli: Pulling from library/docker"

  def env(path: "#{@bin}:#{ENV.fetch('PATH')}", fail: nil, code: 1, mount: @dir, ncpu: 32, base: "HEAD~1",
          read_token: "ghs_#{'s' * 36}", pin: "400000 100000", pin_err: "", pull_fail: nil)
    { "PATH" => path, "DOCKER_LOG" => @log, "STUB_MOUNT" => mount, "DOCKER_FAIL" => fail.to_s, "DOCKER_EXIT" => code.to_s,
      "STUB_NCPU" => ncpu.to_s, "STUB_PIN" => pin, "STUB_PIN_ERR" => pin_err, "STUB_PULL_FAIL" => pull_fail,
      "STUB_PULL_NOISE" => PULL_NOISE, "CI_BASE_REF" => base, "CI_GITHUB_READ_TOKEN" => read_token,
      "CI_GITHUB_CACHE_DIR" => File.join(@dir, "cache"),
      "GIT_AUTHOR_NAME" => "ci", "GIT_AUTHOR_EMAIL" => "ci@example.invalid",
      "GIT_COMMITTER_NAME" => "ci", "GIT_COMMITTER_EMAIL" => "ci@example.invalid",
      "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil,
      "BUILD_TAG" => nil, }
  end

  def write_exe(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def sh!(*cmd, chdir:)
    out, status = Open3.capture2e(env, *cmd, chdir: chdir)
    assert_predicate status, :success?, "#{cmd.join(' ')}: #{out}"
    out
  end

  def run_in(dir, *cmd, **opts) = Open3.capture3(env(**opts), *cmd, chdir: dir)

  def docker_calls = File.exist?(@log) ? File.readlines(@log, chomp: true) : []

  PROBE = " cat /sys/fs/cgroup/cpu.max"

  # the containers a stage started (the quota probe aside)
  def docker_runs = docker_calls.select { _1.start_with?("run ") && !_1.end_with?(PROBE) }

  def pin_probes = docker_calls.select { _1.start_with?("run ") && _1.end_with?(PROBE) }

  def one_run
    runs = docker_runs
    assert_equal 1, runs.size, "one container: #{runs}"
    runs.first
  end

  # a repo holding the given scripts (and extra tracked files) in three commits
  def repo(name, scripts, extra = {})
    dir = File.join(@dir, name)
    sh!("git", "init", "-q", "-b", "main", dir, chdir: @dir)
    scripts.each { |rel, src| write_exe(File.join(dir, rel), src.start_with?("#!") ? src : File.read(src)) }
    extra.each do |rel, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
      File.write(File.join(dir, rel), body)
    end
    3.times do |i|
      File.write(File.join(dir, "file.txt"), i.to_s)
      sh!("git", "add", "-A", chdir: dir)
      sh!("git", "commit", "-q", "-m", "commit #{i}", chdir: dir)
    end
    dir
  end

  def ci_scripts = { "scripts/ci/test.sh" => TEST_SH, "scripts/ci/runner.env" => RUNNER_ENV }

  def ci_repo(extra = {}) = repo("ci", ci_scripts, extra)

  def overrides = File.exist?("#{@log}.yml") ? File.read("#{@log}.yml") : ""

  # everything `all` touches besides docker: the lint wrappers, the lint image, .env.example (the Ruby stage's compose env),
  # a test file (the flake stage repeats the whole suite for an unmapped change)
  def full_ci_repo
    stubs = %w[scripts/lint/image scripts/lint/rubocop scripts/lint/shellcheck].to_h { [_1, STUB_OK] }
    repo("full", ci_scripts.merge(stubs), ".env.example" => "SOME_KEY=\n", "test/unit/some_test.rb" => "x\n")
  end

  def hooks_repo = repo("hooks", { "scripts/hooks/run" => HOOKS_RUN, "scripts/hooks/image" => STUB_IMAGE })

  # ── scripts/ci/test.sh secrets ──

  def test_secrets_refuses_a_shallow_clone_before_any_container
    full = ci_repo
    sh!("git", "clone", "-q", "--depth", "1", "file://#{full}", "shallow", chdir: @dir)
    _out, err, status = run_in(File.join(@dir, "shallow"), "scripts/ci/test.sh", "secrets")

    assert_equal 1, status.exitstatus
    assert_match "secrets: shallow checkout (1 commits) — the full history is not here to scan", err
    assert_empty docker_runs
  end

  def test_secrets_refuses_an_in_tree_gitleaks_allowlist
    [".gitleaksignore", "nested/.gitleaks.toml"].each_with_index do |file, i|
      dir = repo("allow#{i}", ci_scripts, file => "x\n")
      _out, err, status = run_in(dir, "scripts/ci/test.sh", "secrets")

      assert_equal 1, status.exitstatus, file
      assert_match "secrets: refused — #{file} in the tree; findings are fixed, never allowlisted", err
    end
    assert_empty docker_runs
  end

  def test_secrets_scans_the_full_history_with_allow_comments_ignored
    dir = ci_repo
    out, err, status = run_in(dir, "scripts/ci/test.sh", "secrets")

    assert_predicate status, :success?, err
    assert_match "over 3 commits", out
    run = one_run
    assert_includes run, "-v #{dir}:/repo:ro"
    assert_includes run, "-w /tmp"
    assert run.end_with?("git --redact --verbose --no-banner --exit-code 1 --ignore-gitleaks-allow /repo"), run
  end

  def test_secrets_fails_when_gitleaks_finds_something
    dir = ci_repo
    _out, _err, status = run_in(dir, "scripts/ci/test.sh", "secrets", fail: "gitleaks")

    assert_equal 1, status.exitstatus
  end

  def test_secrets_in_a_worktree_mounts_the_shared_git_dir
    main = ci_repo
    sh!("git", "worktree", "add", "-q", File.join(@dir, "wt"), chdir: main)
    _out, err, status = run_in(File.join(@dir, "wt"), "scripts/ci/test.sh", "secrets")

    assert_predicate status, :success?, err
    assert_includes one_run, "-v #{main}/.git:#{main}/.git:ro"
  end

  def test_host_path_never_guesses_a_checkout_on_no_mount
    dir = ci_repo
    _out, err, status = run_in(dir, "scripts/ci/test.sh", "secrets", mount: "/elsewhere")

    if File.exist?("/.dockerenv")
      # in a container (the CI suites always are): the checkout is on none of its mounts → refused, nothing started
      assert_equal 1, status.exitstatus
      assert_match "ci: #{dir} is not on any mount of container", err
      assert_empty docker_runs
    else
      # on a host the checkout's own path is the daemon's: no mount is asked for
      assert_predicate status, :success?, err
      refute docker_calls.any? { _1.start_with?("inspect") }, docker_calls.inspect
    end
  end

  # ── scripts/ci/test.sh audit / all ──

  # three checks: Gemfile.lock, the image's libgit2 against its security releases, the frontend lockfile
  def test_audit_fails_when_any_check_has_an_advisory_and_still_runs_all
    dir = full_ci_repo
    checks = [[nil, 0], ["bundle-audit check --update", 1], ["libgit2-audit.rb", 1], ["npm audit --audit-level=low", 1]]
    checks.each do |fail, code|
      FileUtils.rm_f(@log)
      _out, err, status = run_in(dir, "scripts/ci/test.sh", "audit", fail: fail)

      assert_equal code, status.exitstatus, "#{fail.inspect}: #{err}"
      assert_equal 3, docker_runs.size, "every check runs even when one fails: #{docker_runs}"
    end
  end

  # the libgit2 release list is read with CI_GITHUB_READ_TOKEN, handed in by name (never its value on argv),
  # with the user's ETag cache mounted; no token → that check is refused (the other two still run), never anonymous
  def test_audit_reads_github_with_the_token_by_name_or_refuses_without_one
    dir = full_ci_repo
    _out, err, status = run_in(dir, "scripts/ci/test.sh", "audit")
    assert_predicate status, :success?, err
    run = docker_runs.find { _1.include?("libgit2-audit.rb") }
    assert_includes run, " -e CI_GITHUB_READ_TOKEN "
    refute_includes run, "ghs_"
    assert_includes run, "-v #{File.join(@dir, 'cache')}:/cache "
    assert run.end_with?("/src/scripts/ci/libgit2-audit.rb /src/Dockerfile /cache"), run

    FileUtils.rm_f(@log)
    _out, err, status = run_in(dir, "scripts/ci/test.sh", "audit", read_token: nil)
    assert_equal 1, status.exitstatus
    assert_match "audit: CI_GITHUB_READ_TOKEN is not set", err
    assert_equal 2, docker_runs.size, "bundle-audit and npm audit still ran: #{docker_runs}"
    refute docker_runs.any? { _1.include?("libgit2-audit.rb") }
  end

  # the script itself refuses without a token, before any request
  def test_the_libgit2_audit_script_refuses_without_a_token
    _out, err, status = Open3.capture3({ "CI_GITHUB_READ_TOKEN" => nil }, RbConfig.ruby,
                                       File.expand_path("../../scripts/ci/libgit2-audit.rb", __dir__),
                                       File.expand_path("../../Dockerfile", __dir__), @dir)

    assert_equal 1, status.exitstatus
    assert_match "libgit2-audit: CI_GITHUB_READ_TOKEN is not set", err
  end

  def test_all_runs_every_stage_and_fails_when_one_fails
    dir = full_ci_repo
    out, err, status = run_in(dir, "scripts/ci/test.sh", "all")

    assert_predicate status, :success?, out + err
    assert_match "ci: #{STAGES.map { "#{_1} exit 0" }.join(' · ')}", out

    out, _err, status = run_in(dir, "scripts/ci/test.sh", "all", fail: "gitleaks")

    assert_equal 1, status.exitstatus
    assert_match "ci: #{STAGES.map { "#{_1} exit #{_1 == 'secrets' ? 1 : 0}" }.join(' · ')}", out
  end

  # ── the runner's shape ──

  def test_the_runners_shape_is_read_from_its_file_and_checked_before_any_container
    dir = repo("noshape", { "scripts/ci/test.sh" => TEST_SH })
    _out, err, status = run_in(dir, "scripts/ci/test.sh", "frontend")
    assert_equal 1, status.exitstatus
    assert_match "ci: scripts/ci/runner.env is missing", err

    { "CI_RUNNER_CPUS=0" => "CI_RUNNER_CPUS must be a positive integer (is '0')",
      "CI_RUNNER_CPUS=four" => "CI_RUNNER_CPUS must be a positive integer (is 'four')",
      "CI_RUNNER_MEMORY=16g" => "unknown line: CI_RUNNER_MEMORY=16g", }.each do |line, refusal|
      File.write(File.join(dir, "scripts/ci/runner.env"), "CI_RUNNER_CPUS=4\nCI_FLAKE_REPEATS=5\n#{line}\n")
      _out, err, status = run_in(dir, "scripts/ci/test.sh", "frontend")
      assert_equal 1, status.exitstatus, line
      assert_match refusal, err
    end
    File.write(File.join(dir, "scripts/ci/runner.env"), "CI_RUNNER_CPUS=4\n")
    _out, err, = run_in(dir, "scripts/ci/test.sh", "frontend")
    assert_match "CI_FLAKE_REPEATS must be a positive integer (is '')", err

    _out, err, status = run_in(ci_repo, "scripts/ci/test.sh", "frontend", ncpu: 2)
    assert_equal 1, status.exitstatus
    assert_match "ci: the Docker host has 2 CPUs, the runner's shape needs 4", err
    assert_empty docker_runs
  end

  # only the quota stages need the runner's CPUs: lint, audit, secrets and host run on a smaller host
  def test_the_stages_with_no_quota_run_on_a_host_with_fewer_cpus
    dir = full_ci_repo
    %w[ruby ruby-pg frontend].each do |stage|
      _out, err, status = run_in(dir, "scripts/ci/test.sh", stage, ncpu: 2)
      assert_equal 1, status.exitstatus, stage
      assert_match "ci: the Docker host has 2 CPUs, the runner's shape needs 4", err, stage
    end
    %w[lint audit secrets host].each do |stage|
      _out, err, status = run_in(dir, "scripts/ci/test.sh", stage, ncpu: 2)
      assert_predicate status, :success?, "#{stage}: #{err}"
      refute_match "CPUs", err, stage
    end
  end

  def test_the_test_stages_run_on_the_runners_cpu_quota
    cpus = Integer(File.read(RUNNER_ENV)[/^CI_RUNNER_CPUS=(\d+)$/, 1])
    dir = full_ci_repo
    _out, err, status = run_in(dir, "scripts/ci/test.sh", "frontend")
    assert_predicate status, :success?, err
    assert_includes one_run, "--cpus #{cpus} -e CI_RUNNER_CPUS=#{cpus} "
    assert_includes File.read(TEST_SH), %(npx vitest run --maxWorkers="$CI_RUNNER_CPUS"), "N workers, never the host nproc"
    refute_includes one_run, "cpuset", "a quota on no fixed cores (concurrent builds spread over the host)"
    assert_equal ["run --rm --cpus #{cpus} docker:28.5.2-cli#{PROBE}"], pin_probes

    %w[ruby ruby-pg].each do |stage|
      FileUtils.rm_f("#{@log}.yml")
      _out, err, status = run_in(dir, "scripts/ci/test.sh", stage)
      assert_predicate status, :success?, err
      yml = YAML.safe_load(overrides.split(/^(?=services:)/).first)
      assert_equal [cpus] * 2, yml["services"].values_at("test", "test-postgres").map { _1["cpus"] }, stage
      assert_equal cpus.to_s, yml.dig("services", "test", "environment", "MT_CPU"), "minitest's threads = the runner's CPUs"
      assert_equal cpus.to_s, yml.dig("services", "test", "environment", "TEST_WORKERS"), "test processes at a time"
      adapter = yml.dig("services", "test", "environment", "DATABASE_ADAPTER")
      stage == "ruby-pg" ? assert_equal("postgresql", adapter) : assert_nil(adapter)
      refute(yml["services"].values.any? { _1.key?("cpuset") }, stage)
    end
  end

  # A rootless dockerd DISCARDED --cpuset-cpus with a warning: every limited stage asks
  # first and refuses a daemon whose container's cpu.max is not exactly the runner's quota
  def test_a_daemon_that_ignores_the_quota_is_refused_before_the_stage_starts
    dir = full_ci_repo
    [["max 100000", ""], ["max 100000", "WARNING: Your kernel does not support CPU CFS scheduler. CPU limit discarded."],
     ["200000 100000", ""],].each do |pin, pin_err|
      %w[frontend ruby flake].each do |stage|
        FileUtils.rm_f(@log)
        _out, err, status = run_in(dir, "scripts/ci/test.sh", stage, pin: pin, pin_err: pin_err)
        assert_equal 1, status.exitstatus, "#{stage}: #{err}"
        assert_match "ci: the Docker daemon did not limit a container to 4 CPUs (cpu.max in it: '#{pin}'", err
        assert_match "want '400000 100000'", err
        assert_empty docker_runs, stage
      end
    end
  end

  # a fresh image cache — the probe's pull progress was read as cpu.max. The image is pulled first, only
  # the run's stdout is read, and anything that is not `<quota> <period>` is "could not read", never "not limited"
  def test_the_quota_probe_reads_only_cpu_max
    dir = full_ci_repo
    _out, err, status = run_in(dir, "scripts/ci/test.sh", "frontend", pin_err: PULL_NOISE)
    assert_predicate status, :success?, err
    assert_includes docker_calls, "pull -q docker:28.5.2-cli"
    assert_operator docker_calls.index("pull -q docker:28.5.2-cli"), :<, docker_calls.index { _1.end_with?(PROBE) }

    ["Unable to find image 'docker:28.5.2-cli' locally", "", "400000"].each do |pin|
      FileUtils.rm_f(@log)
      _out, err, status = run_in(dir, "scripts/ci/test.sh", "frontend", pin: pin)
      assert_equal 1, status.exitstatus, pin
      assert_match "ci: could not read cpu.max from the CPU-quota probe: '#{pin}'", err
      refute_match "did not limit", err
      assert_empty docker_runs
    end

    FileUtils.rm_f(@log)
    _out, err, status = run_in(dir, "scripts/ci/test.sh", "frontend", pull_fail: "1")
    assert_equal 1, status.exitstatus
    assert_match "ci: could not pull docker:28.5.2-cli for the CPU-quota probe: Unable to find image", err
    assert_empty pin_probes, "no probe without its image"
    assert_empty docker_runs
  end

  # ── scripts/ci/test.sh flake ──

  def flake_repo
    dir = repo("flake", ci_scripts, ".env.example" => "SOME_KEY=\n",
                                    "lib/busyyaks/foo_bar.rb" => "module Busyyaks; module FooBar; end; end\n",
                                    "test/unit/foo_bar_test.rb" => "Busyyaks::FooBar\n",
                                    "test/unit/uses_path_test.rb" => "require \"busyyaks/foo_bar\"\n",
                                    "test/unit/foo_bar_baz_test.rb" => "Busyyaks::FooBarBaz\n",
                                    "test/unit/other_test.rb" => "Other\n",
                                    "test/unit/changed_test.rb" => "Changed\n")
    File.write(File.join(dir, "lib/busyyaks/foo_bar.rb"), "module Busyyaks; module FooBar; X = 1; end; end\n")
    File.write(File.join(dir, "test/unit/changed_test.rb"), "Changed 2\n")
    sh!("git", "commit", "-qam", "the change", chdir: dir)
    dir
  end

  def test_flake_repeats_the_tests_the_change_touches_on_the_runners_cpus
    repeats = File.read(RUNNER_ENV)[/^CI_FLAKE_REPEATS=(\d+)$/, 1]
    out, err, status = run_in(flake_repo, "scripts/ci/test.sh", "flake")

    assert_predicate status, :success?, err
    assert_match "flake: 2 files changed since", out
    yml = YAML.safe_load(overrides)["services"]["test"]
    assert_equal %w[bundle exec rake test:repeat], yml["command"]
    workers = File.read(RUNNER_ENV)[/^CI_RUNNER_CPUS=(\d+)$/, 1]
    assert_equal({ "MT_CPU" => workers, "TEST_WORKERS" => workers, "TEST_REPEAT_TIMES" => repeats,
                   "TEST_REPEAT_WORKERS" => workers,
                   "TEST_REPEAT_FILES" => "test/unit/changed_test.rb test/unit/foo_bar_test.rb test/unit/uses_path_test.rb", },
                 yml["environment"])
  end

  def test_flake_fails_its_repeats_and_refuses_an_unknown_base
    dir = flake_repo
    _out, _err, status = run_in(dir, "scripts/ci/test.sh", "flake", fail: "compose .*run --rm --build test")
    assert_equal 1, status.exitstatus, "a red repeat fails the stage"

    FileUtils.rm_f(@log)
    [[nil, "flake: CI_BASE_REF is not set"],
["nope", "flake: CI_BASE_REF=nope is not a commit this checkout has"],].each do |base, refusal|
      _out, err, status = run_in(dir, "scripts/ci/test.sh", "flake", base: base)
      assert_equal 1, status.exitstatus, base.inspect
      assert_match refusal, err
    end
    assert_empty docker_runs
  end

  # fails closed: a path the selection does not map, or a lib file no test names, repeats the whole suite
  def test_flake_repeats_the_whole_suite_for_a_path_it_does_not_map
    every = "test/unit/changed_test.rb test/unit/foo_bar_baz_test.rb test/unit/foo_bar_test.rb test/unit/other_test.rb " \
            "test/unit/uses_path_test.rb"
    { "app/actions/x.rb" => "x", "docs/NOTES.md" => "n", "test/support/helper.rb" => "h", "Rakefile" => "r",
      "lib/busyyaks/nobody_names_me.rb" => "module Busyyaks; module NobodyNamesMe; end; end", }.each do |path, body|
      dir = flake_repo
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), body)
      sh!("git", "add", "-A", chdir: dir)
      sh!("git", "commit", "-qm", "touch #{path}", chdir: dir)
      FileUtils.rm_f("#{@log}.yml")
      out, err, status = run_in(dir, "scripts/ci/test.sh", "flake", base: "HEAD~1")

      assert_predicate status, :success?, err
      assert_match "the whole suite is repeated", out, path
      assert_equal every, YAML.safe_load(overrides)["services"]["test"]["environment"]["TEST_REPEAT_FILES"], path
      FileUtils.rm_rf(dir)
    end
  end

  # a deleted lib file is named by no test any more: the whole suite; a deleted test file alone repeats nothing of its own
  def test_flake_repeats_the_whole_suite_for_a_deleted_path
    dir = flake_repo
    sh!("git", "rm", "-q", "lib/busyyaks/foo_bar.rb", chdir: dir)
    sh!("git", "commit", "-qm", "delete foo_bar", chdir: dir)
    out, err, status = run_in(dir, "scripts/ci/test.sh", "flake", base: "HEAD~1")
    assert_predicate status, :success?, err
    assert_match "flake: lib/busyyaks/foo_bar.rb was deleted — the whole suite is repeated", out
    assert_match "flake: 1 files changed since", out
    assert_includes YAML.safe_load(overrides)["services"]["test"]["environment"]["TEST_REPEAT_FILES"], "other_test.rb"

    FileUtils.rm_f("#{@log}.yml")
    sh!("git", "rm", "-q", "test/unit/other_test.rb", chdir: dir)
    sh!("git", "commit", "-qm", "delete a test", chdir: dir)
    out, err, status = run_in(dir, "scripts/ci/test.sh", "flake", base: "HEAD~1")
    assert_predicate status, :success?, err
    assert_match "flake: only test files were deleted — nothing to repeat", out
    assert_empty overrides
  end

  def test_flake_with_nothing_changed_repeats_nothing_and_with_no_tests_fails
    out, err, status = run_in(ci_repo, "scripts/ci/test.sh", "flake", base: "HEAD")
    assert_predicate status, :success?, err
    assert_match "flake: nothing changed — nothing to repeat", out

    _out, err, status = run_in(File.join(@dir, "ci"), "scripts/ci/test.sh", "flake")
    assert_equal 1, status.exitstatus
    assert_match "flake: 1 files changed and no test file was found to repeat", err
    assert_empty docker_runs
  end

  def test_an_unknown_stage_is_a_usage_error
    _out, err, status = run_in(ci_repo, "scripts/ci/test.sh", "nope")

    assert_equal 2, status.exitstatus
    assert_match "usage:", err
  end

  # ── scripts/hooks/run ──

  def worktree_config(dir)
    Open3.capture2(env, "git", "config", "--local", "--get", "extensions.worktreeConfig", chdir: dir).first.strip
  end

  def test_hooks_run_needs_a_hook_name
    _out, err, status = run_in(hooks_repo, "scripts/hooks/run")

    refute_predicate status, :success?
    assert_match "usage: scripts/hooks/run pre-commit|sign", err
  end

  def test_hooks_run_refuses_without_docker
    nodocker = File.join(@dir, "nodocker")
    FileUtils.mkdir_p(nodocker)
    %w[bash git].each { |tool| File.symlink(which(tool), File.join(nodocker, tool)) }
    _out, err, status = run_in(hooks_repo, "scripts/hooks/run", "pre-commit", path: nodocker)

    assert_equal 1, status.exitstatus
    assert_match "hooks: docker not found — the hooks run only in Docker; nothing was checked, so the commit is " \
                 "refused", err
    assert_empty docker_calls
  end

  def test_hooks_run_refuses_a_hook_while_signatures_are_shared
    dir = hooks_repo
    [nil, "false"].each do |value|
      sh!("git", "config", "--local", "extensions.worktreeConfig", value, chdir: dir) if value
      _out, err, status = run_in(dir, "scripts/hooks/run", "pre-commit")

      assert_equal 1, status.exitstatus
      assert_match "extensions.worktreeConfig is #{value || 'not set'} in this repo's config (--local)", err
      assert_match "run scripts/hooks/run sign", err
      assert_equal value.to_s, worktree_config(dir), "a refused hook changes no config"
    end
    assert_empty docker_calls
  end

  def test_sign_turns_per_worktree_signatures_on_and_signs
    dir = hooks_repo
    _out, err, status = run_in(dir, "scripts/hooks/run", "sign")

    assert_predicate status, :success?, err
    assert_match "extensions.worktreeConfig turned on", err
    assert_equal "true", worktree_config(dir)
    assert one_run.end_with?("busyyaks:hooks-stub sign"), one_run
  end

  def test_pre_commit_hands_docker_the_index_and_the_git_dir_never_the_working_tree
    dir = hooks_repo
    sh!("git", "config", "--local", "extensions.worktreeConfig", "true", chdir: dir)
    _out, err, status = run_in(dir, "scripts/hooks/run", "pre-commit")

    assert_predicate status, :success?, err
    run = one_run
    git = File.join(dir, ".git")
    assert_includes run, "-e GIT_DIR=#{git} -e GIT_WORK_TREE=/deps/snap -e GIT_INDEX_FILE=/tmp/index"
    assert_includes run, "-e GIT_AUTHOR_NAME=ci -e GIT_AUTHOR_EMAIL=ci@example.invalid"
    assert_includes run, "-v #{git}:#{git} -v #{git}/index:/deps/index.in:ro --tmpfs /deps/snap:exec,mode=1777"
    assert run.end_with?("busyyaks:hooks-stub pre-commit"), run
    assert_equal 2, run.scan(" -v ").size, "only the git dir and the index are mounted: #{run}"
  end

  def test_pre_commit_fails_when_the_hooks_fail
    dir = hooks_repo
    sh!("git", "config", "--local", "extensions.worktreeConfig", "true", chdir: dir)
    _out, _err, status = run_in(dir, "scripts/hooks/run", "pre-commit", fail: "pre-commit$", code: 3)

    assert_equal 3, status.exitstatus
  end

  def which(tool)
    found = ENV.fetch("PATH").split(":").map { File.join(_1, tool) }.find { File.executable?(_1) }
    found or raise "#{tool} not on PATH"
  end
end
