# frozen_string_literal: true

# Standalone (no test_helper, no app): Busyyaks::Updates is loaded by host programs (bin/yaks, bin/launcher). Real git
# repos in a temp dir: a bare "remote" with release tags and a main branch, and a clone of it as the checkout.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../../lib/busyyaks/updates"

class UpdatesTest < Minitest::Test
  U = Busyyaks::Updates
  OK = { "remote" => "origin", "branch" => "main", "tags" => "v*", "channel" => "tags", "check_minutes" => 60 }.freeze
  NOW = Time.utc(2026, 11, 18, 12)

  def setup
    @dir = Dir.mktmpdir("updates-test")
    @remote = File.join(@dir, "remote.git")
    @work = File.join(@dir, "work") # where the "releases" are made, pushed to the remote
    @co = File.join(@dir, "checkout")
    sh(@dir, "git", "init", "-q", "--bare", "-b", "main", @remote)
    sh(@dir, "git", "clone", "-q", @remote, @work)
    sh(@work, "git", "checkout", "-q", "-b", "main")
    commit(@work, "one")
    sh(@work, "git", "tag", "v1.0.0")
    sh(@work, "git", "push", "-q", "origin", "main", "v1.0.0")
    sh(@dir, "git", "clone", "-q", @remote, @co)
    @settings = U.parse!(OK)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def sh(dir, *argv)
    out, st = Open3.capture2e({ "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.test",
                                "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.test", },
                              *argv, chdir: dir)
    raise "#{argv.join(' ')}: #{out}" unless st.success?

    out.strip
  end

  def commit(dir, name)
    File.write(File.join(dir, "#{name}.txt"), name)
    sh(dir, "git", "add", ".")
    sh(dir, "git", "commit", "-q", "-m", name)
    sh(dir, "git", "rev-parse", "HEAD")
  end

  def release(name, tag: nil, annotated: false)
    sha = commit(@work, name)
    if tag
      annotated ? sh(@work, "git", "tag", "-a", "-m", tag, tag) : sh(@work, "git", "tag", tag)
    end
    sh(@work, "git", "push", "-q", "origin", "main", *tag)
    sha
  end

  def git
    lambda do |args|
      out, err, st = Open3.capture3("git", "-C", @co, *args)
      [out, err, st.success?]
    end
  end

  def check(settings = @settings) = U.check(settings, git: git, now: NOW)

  def test_parse_takes_exactly_the_keys
    s = U.parse!(OK)
    assert_equal ["origin", "main", "v*", "tags", 3600], [s.remote, s.branch, s.tags, s.channel, s.check_seconds]
    assert_match(/exactly branch, channel, check_minutes, remote, tags/, assert_raises(U::Invalid) {
 U.parse!(OK.except("tags")) }.message)
    assert_raises(U::Invalid) { U.parse!(OK.merge("extra" => 1)) }
    assert_raises(U::Invalid) { U.parse!(nil) }
    { "remote" => "-x", "branch" => "a..b" }.each do |k, v|
      assert_match(/updates.#{k} must be a git/, assert_raises(U::Invalid) { U.parse!(OK.merge(k => v)) }.message)
    end
    %w[v ** v*-* a b*].first(3).each do |g|
      assert_match(/exactly one \*/, assert_raises(U::Invalid) { U.parse!(OK.merge("tags" => g)) }.message)
    end
    assert_match(/channel must be/, assert_raises(U::Invalid) { U.parse!(OK.merge("channel" => "nightly")) }.message)
    [0, 10_081, "60", nil].each do |m|
      assert_match(/check_minutes/, assert_raises(U::Invalid) { U.parse!(OK.merge("check_minutes" => m)) }.message)
    end
  end

  def test_version_of_reads_only_what_the_star_matches
    s = U.parse!(OK.merge("tags" => "release-*-final"))
    assert_equal Gem::Version.new("1.2.0"), s.version_of("release-1.2.0-final")
    assert_nil s.version_of("release-x-final")
    assert_nil s.version_of("v1.2.0")
    assert_operator @settings.version_of("v1.0.0"), :>, @settings.version_of("v1.0.0-beta.2")
    assert_operator @settings.version_of("v1.10.0"), :>, @settings.version_of("v1.9.0")
    assert_nil @settings.version_of("vnext")
  end

  def test_current_when_nothing_is_newer
    c = check
    assert_equal "current", c[:tag][:state]
    assert_equal "v1.0.0", c[:tag][:name]
    assert_equal "current", c[:branch][:state]
    assert_equal "main", c[:head][:branch]
    assert_equal "v1.0.0", c[:head][:describe]
    refute c[:available]
    assert_equal NOW.iso8601, c[:checked_at]
    assert_equal @remote, c[:url]
  end

  # a token in an https remote's userinfo is never stored nor shown: not in the check's url, not in git's own words
  def test_a_remotes_userinfo_never_leaves_the_check
    secret = "https://me:tok3n@git.example.test/me/busyyaks.git"
    said = lambda do |args|
      next [secret, "", true] if args.first(2) == %w[ls-remote --get-url]

      git.call(args)
    end
    assert_equal "https://git.example.test/me/busyyaks.git", U.check(@settings, git: said, now: NOW)[:url]
    failing = lambda do |args|
      next ["", "fatal: unable to access '#{secret}/': 403", false] if args.first == "fetch"

      said.call(args)
    end
    e = assert_raises(U::Refused) { U.check(@settings, git: failing, now: NOW) }
    assert_equal "git fetch --no-tags: fatal: unable to access 'https://git.example.test/me/busyyaks.git/': 403", e.message
    refute_includes e.message, "tok3n"
    assert_equal "git@host:me/r.git ssh://host/r", U.without_userinfo("git@host:me/r.git ssh://u:p@host/r")
  end

  # the checkout's own config: a key that runs a program or rewrites the fetch, and that a command-scope value cannot
  # switch off, refuses the check naming it — nothing is fetched
  def test_preflight_refuses_config_that_runs_a_program_or_rewrites_the_fetch
    { "filter.x.smudge" => "touch /tmp/x", "url.https://evil.test/.insteadOf" => @remote,
      "include.path" => "/tmp/other", "includeIf.gitdir:/.path" => "/tmp/other",
      "credential.https://example.test.helper" => "!touch /tmp/x", "remote.origin.uploadpack" => "touch /tmp/x",
      "remote.origin.vcs" => "x", "http.proxy" => "http://p.test", "http.https://example.test.proxy" => "http://p.test",
      "core.gitProxy" => "touch", "core.worktree" => "/tmp", "gpg.program" => "touch",
      "gpg.ssh.program" => "touch", }.each do |key, value|
      sh(@co, "git", "config", key, value)
      e = assert_raises(U::Refused, key) { check }
      assert_match(/\.git\/config sets #{Regexp.escape(key)}: /i, e.message)
      sh(@co, "git", "config", "--unset", key)
    end
    check # clean again
  end

  # what `-c` CAN switch off is switched off for every update git call (GIT_ENV's command-scope config): the repo's
  # fsmonitor / hooks never run, the system and global config are not read
  def test_git_env_switches_off_the_programs_a_repo_config_names
    mark = File.join(@dir, "ran")
    hook = File.join(@dir, "hook.sh")
    File.write(hook, "#!/bin/sh\ntouch #{mark}\n")
    File.chmod(0o755, hook)
    sh(@co, "git", "config", "core.fsmonitor", hook)
    hooks = File.join(@co, ".git", "hooks")
    File.write(File.join(hooks, "post-merge"), "#!/bin/sh\ntouch #{mark}\n")
    File.chmod(0o755, File.join(hooks, "post-merge"))
    release("two", tag: "v1.1.0")
    safe = lambda do |args|
      out, err, st = Open3.capture3(U::GIT_ENV, "git", "-C", @co, *args)
      [out, err, st.success?]
    end
    c = U.check(@settings, git: safe, now: NOW)
    U.move!(U.target!(c, @settings, mode: "tags"), git: safe)
    refute File.exist?(mark), "a repo-configured program ran"
    assert_equal "/dev/null", U::GIT_ENV["GIT_CONFIG_GLOBAL"]
    assert_equal U::GIT_CONFIG.size.to_s, U::GIT_ENV["GIT_CONFIG_COUNT"]
    sh(@co, "git", "status") # the plain git (no GIT_ENV) does run it: the test's hook is real
    assert File.exist?(mark)
  end

  def test_a_newer_tag_and_branch_head_are_fast_forwards_the_newest_version_wins_not_the_newest_tag
    v11 = release("two", tag: "v1.1.0", annotated: true) # annotated: the commit, not the tag object
    release("three", tag: "v1.0.1") # tagged later, but an older version
    head = release("four")
    sh(@work, "git", "tag", "vnext")
    sh(@work, "git", "push", "-q", "origin", "vnext")
    c = check
    assert_equal({ name: "v1.1.0", sha: v11, version: "1.1.0", state: "available", behind: 1 }, c[:tag])
    assert_equal({ name: "main", sha: head, state: "available", behind: 3 }, c[:branch])
    assert_equal ["vnext"], c[:ignored_tags]
    assert c[:available]
    assert check(U.parse!(OK.merge("channel" => "branch")))[:available]
  end

  def test_ahead_diverged_and_dirty
    release("two", tag: "v1.1.0")
    sh(@co, "git", "pull", "-q", "--ff-only")
    commit(@co, "mine") # a local commit: ahead of the tag, diverged once the branch moves
    assert_equal "ahead", check[:tag][:state]
    assert_equal "ahead", check[:branch][:state]
    release("theirs")
    c = check
    assert_equal "diverged", c[:branch][:state]
    assert_equal 1, c[:branch][:behind]
    File.write(File.join(@co, "one.txt"), "changed")
    File.write(File.join(@co, "untracked.bak"), "x")
    assert_equal ["one.txt"], check[:dirty] # untracked files never count
  end

  def test_target_refuses_what_would_lose_or_guess
    assert_match(/already on the newest v\* tag/, assert_raises(U::Refused) {
 U.target!(check, @settings, mode: "tags") }.message)
    sha = release("two", tag: "v1.1.0")
    c = check
    assert_match(/moved since it was shown/, assert_raises(U::Refused) {
      U.target!(c, @settings, mode: "tags", expect: "0" * 40)
    }.message)
    assert_match(/mode must be/, assert_raises(U::Refused) { U.target!(c, @settings, mode: "nightly") }.message)
    File.write(File.join(@co, "one.txt"), "changed")
    assert_match(/tracked files changed: one.txt/, assert_raises(U::Refused) {
 U.target!(check, @settings, mode: "tags") }.message)
    sh(@co, "git", "checkout", "-q", "one.txt")
    sh(@co, "git", "checkout", "-q", "-b", "dev")
    assert_match(/checkout is on dev; updates follow main/,
                 assert_raises(U::Refused) { U.target!(check, @settings, mode: "tags") }.message)
    sh(@co, "git", "checkout", "-q", "main")
    t = U.target!(check, @settings, mode: "tags", expect: sha)
    assert_equal({ mode: "tags", name: "v1.1.0", sha: sha, behind: 1, branch: "main" }, t.except(:from))
  end

  def test_no_version_tag_is_said
    s = U.parse!(OK.merge("tags" => "release-*"))
    assert_equal({ state: "none" }, check(s)[:tag])
    assert_match(/no release-\* tag that is a version/, assert_raises(U::Refused) {
 U.target!(check(s), s, mode: "tags") }.message)
  end

  def test_move_on_the_branch_fast_forwards_it_and_back_returns
    from = sh(@co, "git", "rev-parse", "HEAD")
    sha = release("two", tag: "v1.1.0")
    t = U.target!(check, @settings, mode: "tags")
    U.move!(t, git: git)
    assert_equal sha, sh(@co, "git", "rev-parse", "HEAD")
    assert_equal "main", sh(@co, "git", "symbolic-ref", "--short", "HEAD")
    U.back!(t, git: git)
    assert_equal from, sh(@co, "git", "rev-parse", "HEAD")
    assert_equal "main", sh(@co, "git", "symbolic-ref", "--short", "HEAD")
  end

  def test_move_detached_checks_out_the_commit
    sh(@co, "git", "checkout", "-q", "--detach", "v1.0.0")
    head = release("two")
    t = U.target!(check, @settings, mode: "branch")
    assert_nil t[:branch]
    U.move!(t, git: git)
    assert_equal head, sh(@co, "git", "rev-parse", "HEAD")
    U.back!(t, git: git)
    assert_equal t[:from], sh(@co, "git", "rev-parse", "HEAD")
  end

  def test_a_local_tag_that_differs_from_the_remote_is_refused_never_clobbered
    sh(@co, "git", "tag", "v2.0.0") # here: on "one"
    release("two", tag: "v2.0.0")    # the remote's: on "two"
    assert_match(/git fetch --no-tags:.*(clobber|rejected)/, assert_raises(U::Refused) { check }.message)
  end

  # the remote's tags decide: a release deleted there is not offered, a local-only tag is not one (and is not pruned)
  def test_only_the_remotes_tags_are_releases
    release("two", tag: "v1.1.0")
    sh(@co, "git", "fetch", "-q", "origin", "refs/tags/v1.1.0:refs/tags/v1.1.0")
    sh(@work, "git", "push", "-q", "origin", ":refs/tags/v1.1.0")
    sh(@co, "git", "tag", "v9.0.0")
    c = check
    assert_equal ["v1.0.0", "current"], c[:tag].values_at(:name, :state)
    assert_includes sh(@co, "git", "tag"), "v9.0.0"
  end

  def test_records_and_the_one_update_lock
    U.write_json!(@dir, U::RECORD_FILE, { "state" => "running" })
    assert_equal({ "state" => "running" }, U.read_json(@dir, U::RECORD_FILE))
    assert_equal 0o600, File.stat(File.join(@dir, U::RECORD_FILE)).mode & 0o777
    assert_nil U.read_json(@dir, "nope.json")
    File.write(File.join(@dir, "bad.json"), "{")
    assert_equal "unreadable", U.read_json(@dir, "bad.json")["state"]
    refute U.running?(@dir)
    held = U.lock(@dir)
    assert U.running?(@dir)
    assert_nil U.lock(@dir)
    held.close
    refute U.running?(@dir)
  end

  def test_load_reads_the_checkouts_config
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "busyyaks.yml"), YAML.dump("updates" => OK))
    assert_equal "origin", U.load!(@dir).remote
    File.write(File.join(@dir, "config", "busyyaks.yml"), YAML.dump("roots" => []))
    assert_match(/no updates key/, assert_raises(U::Invalid) { U.load!(@dir) }.message)
    assert_match(/no config/, assert_raises(U::Invalid) { U.load!(File.join(@dir, "none")) }.message)
  end
end
