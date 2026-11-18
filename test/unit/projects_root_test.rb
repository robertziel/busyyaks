# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "minitest/mock"
require_relative "../../lib/busyyaks/projects_root"

# The projects dir change (card 532): the pure parts bin/launcher runs — the .env rewrite and its backup, the checks
# a new root must pass. The launcher's ops themselves: test/integration/launcher_projects_root_test.rb.
class ProjectsRootTest < Minitest::Test
  P = Busyyaks::ProjectsRoot
  ENV_TEXT = "# mine\nPROJECTS_ROOT=/old/code\nPROJECTS_MOUNT=/projects\nSECRET='keep me'\n"

  def setup
    @tmp = File.realpath(Dir.mktmpdir("projects-root"))
    @new = File.join(@tmp, "code")
    FileUtils.mkdir_p([File.join(@new, "a/.git"), File.join(@tmp, "old"), File.join(@tmp, "run")])
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def plan(path, **over)
    P.plan(path, **{ current: File.join(@tmp, "old"), container_root: "/projects", roots: ["/projects"], trusted: [],
                     apart: { "LAUNCHER_RUN_DIR" => File.join(@tmp, "run") }, docker: "/usr/bin/docker", }.merge(over))
  end

  # the services an apply recreates are the stack's (yaks names them in one constant)
  def test_the_services_are_the_clis
    require_relative "../../cli/yaks"
    assert_equal Busyyaks::CLI::SERVICES, P::SERVICES
  end

  def test_rewrite_changes_only_the_projects_root_line
    assert_equal ENV_TEXT.sub("/old/code", "/srv/code"), P.rewrite_env(ENV_TEXT, "/srv/code")
    assert_equal "PROJECTS_ROOT=/srv/x", P.rewrite_env("PROJECTS_ROOT=/a", "/srv/x")
  end

  def test_rewrite_refuses_what_env_cannot_hold_or_an_ambiguous_file
    ["/a b", "/a$b", "/a#b", "/a'b", "/a\"b"].each do |bad|
      assert_raises(P::Invalid, bad) { P.rewrite_env(ENV_TEXT, bad) }
    end
    assert_match(/0 PROJECTS_ROOT lines/, assert_raises(P::Invalid) { P.rewrite_env("X=1\n", "/a") }.message)
    assert_match(/2 PROJECTS_ROOT lines/,
                 assert_raises(P::Invalid) { P.rewrite_env("PROJECTS_ROOT=/a\nPROJECTS_ROOT=/b\n", "/c") }.message)
  end

  def test_write_keeps_a_private_backup_and_the_mode_and_restore_puts_it_back
    env = File.join(@tmp, ".env")
    File.write(env, ENV_TEXT)
    File.chmod(0o640, env)
    state = File.join(@tmp, "state")
    Dir.mkdir(state, 0o700)
    backup = P.write_env!(env, "/srv/code", stamp: "20261117T000000Z", backup_dir: state)
    assert_equal state, File.dirname(backup) # never beside .env in the checkout
    assert_equal ENV_TEXT.sub("/old/code", "/srv/code"), File.read(env)
    assert_equal 0o640, File.stat(env).mode & 0o777
    assert_equal [ENV_TEXT, 0o600], [File.read(backup), File.stat(backup).mode & 0o777]
    P.restore_env!(env, backup)
    assert_equal ENV_TEXT, File.read(env)
    assert_equal [".env"], Dir.children(@tmp).grep(/env/)
    # one backup per stamp: an existing one is never overwritten
    assert_raises(Errno::EEXIST) { P.write_env!(env, "/srv/code", stamp: "20261117T000000Z", backup_dir: state) }
  end

  # the rename of the new .env fails (disk full): .env untouched, the backup taken a moment before removed, the error raised
  def test_a_failed_env_replace_leaves_env_untouched_and_no_backup
    env = File.join(@tmp, ".env")
    File.write(env, ENV_TEXT)
    state = File.join(@tmp, "state")
    Dir.mkdir(state, 0o700)
    File.stub(:rename, ->(*) { raise Errno::ENOSPC }) do
      assert_raises(Errno::ENOSPC) { P.write_env!(env, "/srv/code", stamp: "20261117T000000Z", backup_dir: state) }
    end
    assert_equal ENV_TEXT, File.read(env)
    assert_empty Dir.children(state)
    assert_equal [".env"], Dir.children(@tmp).grep(/env/)
  end

  def test_a_plan_has_a_stable_id_of_what_it_shows
    a = plan(@new)
    assert_equal [File.join(@tmp, "old"), @new, 1, [{ path: "/projects", host: @new }]],
                 a.values_at(:from, :to, :repos, :roots)
    assert_equal a, plan(@new)
    FileUtils.mkdir_p(File.join(@new, "b/.git"))
    refute_equal a[:plan_id], plan(@new)[:plan_id]
  end

  def test_plan_refusals
    assert_match(/roots \/projects\/group would be/,
                 assert_raises(P::Invalid) { plan(@new, roots: ["/projects", "/projects/group"]) }.message)
    assert_match(/docker is not on/, assert_raises(P::Invalid) { plan(@new, docker: nil) }.message)
    assert_match(/overlaps LAUNCHER_RUN_DIR/, assert_raises(P::Invalid) { plan(File.join(@tmp, "run")) }.message)
    assert_match(/not a directory/, assert_raises(P::Invalid) { plan(File.join(@new, "f").tap { |f|
 File.write(f, "") }) }.message)
  end

  # ./data may sit in the projects dir (busyyaks scanning itself), never the projects dir in ./data
  def test_a_root_inside_a_not_inside_dir_is_refused_one_holding_it_is_not
    data = File.join(@new, "a/data")
    FileUtils.mkdir_p(data)
    assert plan(@new, not_inside: { "./data" => data })
    assert_match(%r{lies in ./data}, assert_raises(P::Invalid) { plan(data, not_inside: { "./data" => data }) }.message)
  end

  def test_the_plan_lists_the_created_repos_that_lose_their_trust
    old = File.join(@tmp, "old")
    p = plan(@new, created: [File.join(old, "made"), "/elsewhere/x", File.join(old, "b")])
    assert_equal [File.join(old, "b"), File.join(old, "made")], p[:loses_trust]
  end

  def test_browse_stops_at_the_limit
    dir = File.join(@tmp, "many")
    (P::MAX_ENTRIES + 5).times { |i| FileUtils.mkdir_p(File.join(dir, format("d%05d", i))) }
    b = P.browse(dir)
    assert_equal [P::MAX_ENTRIES, true], [b[:entries].size, b[:truncated]]
    refute P.browse(@new)[:truncated]
  end

  def test_an_unfinished_record_is_settled_by_what_the_launcher_runs_on
    rec = { "state" => "applying", "to" => "/new", "env" => "new" }
    assert_equal rec, P.settled(rec, current: "/old", running: true)
    assert_equal "done", P.settled(rec, current: "/new", running: false)["state"]
    # a stale record's env is never repeated: a rollback may have put the old .env back after it was written
    assert_equal ["interrupted", "unknown", "the record was not finished: the launcher does not run on /new"],
                 P.settled(rec, current: "/old", running: false).values_at("state", "env", "note")
    assert_equal "new", P.settled(rec.merge("env" => "restored"), current: "/new", running: false)["env"]
    assert_nil P.settled(nil, current: "/old", running: false)
    assert_equal({ "state" => "failed" }, P.settled({ "state" => "failed" }, current: "/x", running: false))
  end

  def test_state_is_nil_until_recorded
    assert_nil P.state(@tmp)
    P.record!(@tmp, { "state" => "done" })
    assert_equal({ "state" => "done" }, P.state(@tmp))
    assert_equal 0o600, File.stat(File.join(@tmp, P::STATE_FILE)).mode & 0o777
  end
end
