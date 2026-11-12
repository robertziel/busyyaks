# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "etc"
require_relative "../../lib/busyyaks/launcher_rules"
require_relative "../../lib/busyyaks/owner_remotes"

# What bin/launcher accepts from a container: the repo dir it starts a session in, the prompt values, and whose
# folder-trust prompt it answers.
class LauncherRulesTest < Minitest::Test
  R = Busyyaks::LauncherRules

  def setup
    # under this user's home, never /tmp: a run dir's parents must not be writable by another user (sticky or not)
    @tmp = File.realpath(Dir.mktmpdir("launcher-rules", Etc.getpwuid(Process.uid).dir))
    @root = File.join(@tmp, "projects")
    FileUtils.mkdir_p(File.join(@root, "g/repo/.git"))
    FileUtils.mkdir_p(File.join(@tmp, "outside/.git"))
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def host_dir(path) = R.host_dir(path, container_root: "/projects", projects_root: @root)

  # the start check's clock: a start 3.6 s in with start_seconds 4 was refused when the elapsed seconds were rounded up
  def test_a_start_is_not_overdue_before_start_seconds_passed
    refute R.start_overdue?(100.0, 103.6, 4)
    refute R.start_overdue?(100.0, 103.999, 4)
    assert_equal 3, R.start_elapsed(100.0, 103.6)
  end

  def test_a_start_is_overdue_once_start_seconds_passed
    assert R.start_overdue?(100.0, 104.0, 4)
    assert R.start_overdue?(100.0, 104.4, 4)
    assert_equal 4, R.start_elapsed(100.0, 104.4)
  end

  def test_host_dir_maps_a_repo_under_the_root
    assert_equal File.realpath(File.join(@root, "g/repo")), host_dir("/projects/g/repo")
  end

  def test_host_dir_refuses_paths_outside_and_dot_segments
    assert_raises(ArgumentError) { host_dir("/elsewhere/g/repo") }
    assert_raises(ArgumentError) { host_dir("/projects/g/../repo") }
    assert_raises(ArgumentError) { host_dir("/projects/g//repo") }
    assert_raises(ArgumentError) { host_dir("/projects/g") } # no .git
  end

  # a symlink under the root that leads out of it is refused (the name passes the segment check)
  def test_host_dir_refuses_a_symlink_out_of_the_root
    File.symlink(File.join(@tmp, "outside"), File.join(@root, "g/escape"))
    e = assert_raises(ArgumentError) { host_dir("/projects/g/escape") }
    assert_match(/outside/, e.message)
  end

  # the real path it checked is the one returned (tmux and the trust check use it: no symlink followed afterwards)
  def test_host_dir_returns_the_real_path_it_checked
    link = File.join(@tmp, "link-root")
    File.symlink(@root, link)
    real = File.realpath(File.join(@root, "g/repo"))
    assert_equal real, R.host_dir("/projects/g/repo", container_root: "/projects", projects_root: link)
    File.symlink(File.join(@root, "g/repo"), File.join(@root, "g/alias"))
    assert_equal real, host_dir("/projects/g/alias")
  end

  def test_launch_vars_never_take_dir_from_the_request
    vars = { "slug" => "g/repo", "session" => "s", "agent" => "a", "type" => "lead", "cards" => "#1" }
    assert_equal "/real", R.launch_vars(vars, dir: "/real")[:dir]
    assert_raises(ArgumentError) { R.launch_vars(vars.merge("dir" => "/evil"), dir: "/real") }
    assert_raises(ArgumentError) { R.launch_vars(vars.merge("x" => "y"), dir: "/real") }
    assert_raises(ArgumentError) { R.launch_vars("nope", dir: "/real") }
  end

  OWNERS = ["github.com/me/", "github.com:me/"].freeze

  # the scanner's `own` flag (OwnerRemotes): a host / path segment boundary, never a substring
  def owned?(origin) = Busyyaks::OwnerRemotes.owned?(origin, OWNERS)

  def test_owner_match_is_anchored
    %w[https://github.com/me/x.git git@github.com:me/x.git ssh://git@github.com/me/x.git https://tok@GitHub.com:443/me/x
       ssh://github.com:22/me/x https://github.com/me/x/ https://user:tok-en~1@github.com/me/x].each { |o| assert owned?(o), o }
    %w[https://evil.example/github.com/me/x https://github.com/me-evil/x git@github.com:me-evil/x
       https://github.com.evil.example/me/x git@evil.example:github.com/me/x not-a-url
       https://github.com/me/../evil/x git@github.com:me/../evil/x https://github.com/me/%2e%2e/evil/x
       https://github.com/me/./x https://github.com/me//x https://github.com/me/%2fx].each { |o| refute owned?(o), o }
    # `?`, `#` and `\` end the authority for curl / git: such a "userinfo" names another host
    refute owned?("https://evil.example?@github.com/me/x"), "?"
    refute owned?("https://evil.example#@github.com/me/x"), "#"
    refute owned?("https://evil.example\\@github.com/me/x"), "backslash"
  end

  # only https://, ssh:// and the scp form user@host: — any other scheme is never owned
  def test_only_https_ssh_and_scp_remotes_are_owned
    %w[https://github.com/me/x ssh://git@github.com/me/x git@github.com:me/x].each { |o| assert owned?(o), o }
    %w[file://github.com/me/x git://github.com/me/x http://github.com/me/x ext::github.com/me/x github.com:me/x
       ftp://github.com/me/x].each { |o| refute owned?(o), o }
  end

  def test_owner_remotes_are_validated
    assert_equal OWNERS, Busyyaks::OwnerRemotes.validate!(OWNERS)
    [nil, [], [""], ["  "], "github.com/me/", [1]].each do |v|
      assert_raises(Busyyaks::OwnerRemotes::Invalid, v.inspect) { Busyyaks::OwnerRemotes.validate!(v) }
    end
  end

  def run_dir(path, checkout: File.join(@tmp, "checkout"), uid: Process.uid)
    R.run_dir!(path, projects_root: @root, checkout: checkout, uid: uid)
  end

  def test_run_dir_is_created_private_outside_projects_and_checkout
    FileUtils.mkdir_p(File.join(@tmp, "checkout/data"))
    dir = run_dir(File.join(@tmp, "state/run"))
    assert_equal File.realpath(File.join(@tmp, "state/run")), dir
    assert_equal 0o700, File.stat(dir).mode & 0o777
    assert_equal dir, run_dir(dir), "an existing private dir is accepted"
  end

  # never repaired: an open dir may already hold what another user put there
  def test_an_open_or_uncreatable_run_dir_is_refused
    open = File.join(@tmp, "open")
    FileUtils.mkdir_p(open)
    File.chmod(0o750, open)
    e = assert_raises(R::Invalid) { run_dir(open) }
    assert_match(/mode 750: open to group/, e.message)
    assert_equal 0o750, File.stat(open).mode & 0o777, "left as it was"
    File.write(File.join(@tmp, "file"), "")
    e = assert_raises(R::Invalid) { run_dir(File.join(@tmp, "file/run")) }
    assert_match(/cannot be created/, e.message)
  end

  # ./data symlinked out of the checkout is still ./data: every container mounts it
  def test_a_run_dir_in_a_symlinked_data_dir_is_refused
    elsewhere = File.join(@tmp, "elsewhere")
    FileUtils.mkdir_p([elsewhere, File.join(@tmp, "checkout")])
    File.symlink(elsewhere, File.join(@tmp, "checkout/data"))
    e = assert_raises(R::Invalid) { run_dir(File.join(elsewhere, "run")) }
    assert_match(/overlaps \.\/data/, e.message)
  end

  # a parent another user can write: they could swap a path component between the launcher's bind and compose's mount
  def test_a_run_dir_under_an_open_parent_is_refused
    FileUtils.mkdir_p(File.join(@tmp, "checkout"))
    open = File.join(@tmp, "open")
    FileUtils.mkdir_p(open)
    File.chmod(0o777, open)
    e = assert_raises(R::Invalid) { run_dir(File.join(open, "a/run")) }
    assert_match(/its parent #{open} is writable by group \/ other/, e.message)
    refute File.exist?(File.join(open, "a")), "nothing created"
    # sticky too (/tmp): another user can create the dir while it is absent (after a reboot) and the containers mount it
    File.chmod(0o1777, open)
    e = assert_raises(R::Invalid) { run_dir(File.join(open, "b/run")) }
    assert_match(/writable by group \/ other \(mode 1777\)/, e.message)
  end

  # compose mounts the path as written, the launcher binds the real one: no symlink anywhere in it
  def test_a_run_dir_through_a_symlink_is_refused
    FileUtils.mkdir_p([File.join(@tmp, "checkout"), File.join(@tmp, "state")])
    File.symlink(File.join(@tmp, "state"), File.join(@tmp, "link"))
    e = assert_raises(R::Invalid) { run_dir(File.join(@tmp, "link/run")) }
    assert_match(/goes through a symlink \(it is #{Regexp.escape(File.join(@tmp, "state/run"))}\)/, e.message)
  end

  # the run dir's parent is the operator's own
  def test_a_run_dir_whose_parent_another_uid_owns_is_refused
    return unless Process.uid.zero? # chown needs root (the suite runs as root in Docker)

    FileUtils.mkdir_p([File.join(@tmp, "checkout"), File.join(@tmp, "theirs")])
    File.chown(12_345, nil, File.join(@tmp, "theirs"))
    File.chmod(0o755, File.join(@tmp, "theirs"))
    e = assert_raises(R::Invalid) { run_dir(File.join(@tmp, "theirs/run")) }
    assert_match(/owned by uid 12345/, e.message)
  end

  # the one case only the parent-owner check refuses: a root-owned 0755 parent (parents! accepts root) of a run dir
  # that is the operator's own (uid 12345, 0700)
  def test_a_root_owned_parent_is_refused_for_another_operator
    return unless Process.uid.zero? # chown needs root (the suite runs as root in Docker)

    parent = File.join(@tmp, "rootdir")
    FileUtils.mkdir_p([File.join(@tmp, "checkout"), File.join(parent, "run")])
    File.chmod(0o755, parent)
    File.chown(12_345, nil, File.join(parent, "run"))
    File.chmod(0o700, File.join(parent, "run"))
    File.chown(12_345, nil, @tmp)
    e = assert_raises(R::Invalid) { run_dir(File.join(parent, "run"), uid: 12_345) }
    assert_match(/its parent #{Regexp.escape(parent)} is owned by uid 0, not 12345/, e.message)
  ensure
    File.chown(0, nil, @tmp) if Process.uid.zero?
  end

  def test_run_dir_refusals
    FileUtils.mkdir_p(File.join(@tmp, "checkout/data"))
    {
      "run" => /absolute/,
      File.join(@root, "busyyaks/run") => /overlaps PROJECTS_ROOT/,
      File.join(@tmp, "checkout/data/run") => /overlaps the busyyaks checkout/,
      File.join(@tmp, "checkout") => /overlaps the busyyaks checkout/,
      @tmp => /overlaps PROJECTS_ROOT/,
      "/" => /overlaps/,
    }.each do |path, why|
      e = assert_raises(R::Invalid, path) { run_dir(path) }
      assert_match(why, e.message, path)
    end
    # a symlink from outside into PROJECTS_ROOT resolves into it
    File.symlink(@root, File.join(@tmp, "sneaky"))
    assert_raises(R::Invalid) { run_dir(File.join(@tmp, "sneaky/run")) }
    e = assert_raises(R::Invalid) { run_dir(File.join(@tmp, "other"), uid: Process.uid + 1) }
    assert_match(/owned by uid/, e.message)
  end

  # the launcher runs git only to make a repo: init (a new repo, no config of its own yet) and the clone (LaunchTrust's);
  # every read of an existing repo is a GitRead child (libgit2), never the git CLI
  def test_launcher_git_calls_are_safe
    src = File.read(File.expand_path("../../bin/launcher", __dir__))
    calls = src.scan(/(?:capture3|spawn)\((?:\{[^}]*\}, )?"git", ([^)]*)/).flatten
    assert_equal ["\"init\""], calls.map { |c| c[/\A"\w+"/] }
    # the clone: LaunchTrust's argv in LaunchTrust's environment (launch_trust_test)
    assert_includes src, "Process.spawn(Busyyaks::LaunchTrust.clone_env(home, template), " \
                         "*Busyyaks::LaunchTrust.clone_argv(url, dir),"
    refute_includes src, "Open3.capture3(env, *git,"
  end
end
