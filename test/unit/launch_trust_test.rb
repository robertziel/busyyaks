# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "socket"
require_relative "../../lib/busyyaks/launch_trust"

# Whose folder-trust prompt bin/launcher answers: only a path the operator declared or a repo the launcher itself made —
# never one whose own files (its origin, its config) claim to be the operator's.
class LaunchTrustTest < Minitest::Test
  T = Busyyaks::LaunchTrust

  def setup
    # on a real disk (the checkout's tmp/, bind-mounted from the host in the test service), not the tmpfs /tmp
    base = File.expand_path("../../tmp", __dir__)
    FileUtils.mkdir_p(base)
    @tmp = File.realpath(Dir.mktmpdir("launch-trust", base))
    @root = File.join(@tmp, "projects")
    @state = File.join(@tmp, "state")
    %w[app other planted].each { |r| git!("init", "-q", File.join(@root, "g", r)) }
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def git!(*args)
    _o, e, st = Open3.capture3("git", *args)
    assert st.success?, e
  end

  def created = T::Created.new(T.state_dir!(@state, mounted: { "PROJECTS_ROOT" => @root }, uid: Process.uid))
  def trusted = T.host_paths!(["/projects/g/app"], container_root: "/projects", projects_root: @root)
  def repo(name) = File.join(@root, "g", name)

  def test_a_trusted_path_is_trusted_exactly
    assert_nil T.refusal(repo("app"), trusted: trusted, created: created)
    nested = File.join(repo("app"), "vendor/pkg")
    git!("init", "-q", nested)
    refute_nil T.refusal(nested, trusted: trusted, created: created), "a listed dir trusts itself, never what lies under it"
  end

  def test_a_repo_the_launcher_created_is_trusted
    c = created
    refute_nil T.refusal(repo("other"), trusted: [], created: c)
    c.record(repo("other"))
    assert_nil T.refusal(repo("other"), trusted: [], created: T::Created.new(@state)), "the record outlives the launcher"
    assert_equal 0o600, File.stat(File.join(@state, "created.json")).mode & 0o777
    nonce = File.join(repo("other"), ".git/busyyaks-created")
    assert_equal 0o600, File.stat(nonce).mode & 0o777
    assert_match(/\A[0-9a-f]{64}\z/, File.read(nonce))
    assert_equal [{ "path" => repo("other"), "nonce" => File.read(nonce) }], T::Created.new(@state).entries
  end

  # the attack this replaces: a planted repo whose own config names one of the operator's remotes
  def test_a_faked_owned_origin_is_not_trusted
    git!("-C", repo("planted"), "remote", "add", "origin", "https://github.com/you/app.git")
    reason = T.refusal(repo("planted"), trusted: trusted, created: created)
    assert_match(/not in config\/busyyaks.yml launch.trusted_paths and was not made by the launcher's git init/, reason)
  end

  def test_trusted_paths_are_validated
    assert_equal [], T.parse!({ "trusted_paths" => [] })
    [nil, [], {}, { "trusted_paths" => "x" }, { "trusted_paths" => ["rel"] }, { "trusted_paths" => ["/p/../x"] },
     { "trusted_paths" => [], "x" => 1 },].each do |v|
      assert_raises(T::Invalid, v.inspect) { T.parse!(v) }
    end
    assert_raises(T::Invalid) { T.under_mount!(["/elsewhere/x"], "/projects") }
    assert_raises(T::Invalid) { T.host_paths!(["/projects/g/missing"], container_root: "/projects", projects_root: @root) }
    File.symlink(@tmp, File.join(@root, "g/out"))
    e = assert_raises(T::Invalid) { T.host_paths!(["/projects/g/out"], container_root: "/projects", projects_root: @root) }
    assert_match(/outside PROJECTS_ROOT/, e.message)
  end

  def test_the_state_dir_is_private_and_outside_every_mount
    assert_equal @state, T.state_dir!(@state, mounted: { "PROJECTS_ROOT" => @root }, uid: Process.uid)
    assert_equal 0o700, File.stat(@state).mode & 0o777
    { File.join(@root, "s") => /overlaps PROJECTS_ROOT/, @tmp => /overlaps PROJECTS_ROOT/,
"rel" => /absolute/, }.each do |p, why|
      e = assert_raises(T::Invalid, p) { T.state_dir!(p, mounted: { "PROJECTS_ROOT" => @root }, uid: Process.uid) }
      assert_match(why, e.message)
    end
    open = File.join(@tmp, "open")
    FileUtils.mkdir_p(open)
    File.chmod(0o750, open)
    assert_raises(T::Invalid) { T.state_dir!(open, mounted: {}, uid: Process.uid) }
    assert_raises(T::Invalid) { T.state_dir!(File.join(@tmp, "x"), mounted: {}, uid: Process.uid + 1) }
  end

  def test_a_corrupt_record_is_refused
    c = created
    File.write(File.join(@state, "created.json"), "{}")
    assert_raises(T::Invalid) { c.include?(repo("app")) }
  end

  # the launcher's clone: https / ssh only, no hooks, no submodules — a file:// or ext:: URL clones nothing
  def test_the_clone_takes_only_https_and_ssh
    argv = T.clone_argv("https://github.com/you/x.git", "/d")
    assert_equal ["git", "-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "protocol.ssh.allow=always",
                  "-c", "core.hooksPath=/dev/null", "-c", "core.sshCommand=ssh -o BatchMode=yes", "clone",
                  "--no-recurse-submodules", "--progress", "--",
                  "https://github.com/you/x.git", "/d",], argv
    src = repo("app")
    ["file://#{src}", src, "ext::sh -c touch% #{@tmp}/pwned"].each do |url|
      _o, err, st = Open3.capture3(*T.clone_argv(url, File.join(@tmp, "dest-#{rand(1 << 30)}")))
      refute st.success?, url
      assert_match(/transport .* not allowed|not allowed/, err, url)
    end
    refute File.exist?(File.join(@tmp, "pwned"))
    launcher = File.read(File.expand_path("../../bin/launcher", __dir__))
    assert_includes launcher, "*Busyyaks::LaunchTrust.clone_argv(url, dir)"
  end

  # a trusted path is a repo root: a group dir of repos is refused at start
  def test_a_trusted_path_must_be_a_repo_root
    e = assert_raises(T::Invalid) { T.host_paths!(["/projects/g"], container_root: "/projects", projects_root: @root) }
    assert_match(/not a git repo root/, e.message)
  end

  # the record holds a nonce the launcher wrote into the repo's .git: a repo removed and made again at that path (on
  # a real disk, where an inode number may come back) has none, or another — not trusted, the entry dropped
  def test_a_re_created_repo_is_not_trusted
    c = created
    c.record(repo("other"))
    assert c.include?(repo("other"))
    FileUtils.rm_rf(repo("other"))
    git!("init", "-q", repo("other"))
    refute c.include?(repo("other")), "no nonce in the new .git"
    assert_empty c.paths, "the stale entry is dropped"
    c.record(repo("other"))
    File.write(File.join(repo("other"), ".git/busyyaks-created"), "0" * 64)
    refute c.include?(repo("other")), "another nonce"
    assert_empty c.paths
  end

  # record never stores a repo whose nonce it cannot write
  def test_record_raises_when_the_nonce_cannot_be_written
    c = created
    FileUtils.rm_rf(File.join(repo("other"), ".git"))
    File.write(File.join(repo("other"), ".git"), "gitdir: /nowhere\n") # a .git file, not a dir
    assert_raises(T::Invalid) { c.record(repo("other")) } # .git is a file: no fresh init, no nonce written
    assert_empty c.paths
  end

  # a corrupt record stops the start (Created.new), before any session
  def test_a_corrupt_record_refuses_the_start
    FileUtils.mkdir_p(@state, mode: 0o700)
    ["{not json", "{}", '[{"path":"/x"}]', '["/x"]', '[{"path":"/x","nonce":"short"}]',
     '[{"path":"/x","dev":1,"ino":2}]',].each do |body|
      File.write(File.join(@state, "created.json"), body)
      assert_raises(T::Invalid, body) { T::Created.new(@state) }
    end
  end

  # written through a uniquely named temp file: a leftover from a crash never blocks a record
  def test_a_stale_temp_file_does_not_block_a_record
    c = created
    File.write(File.join(@state, "created.json.#{Process.pid}.tmp"), "junk")
    File.write(File.join(@state, "created20260101-1-abc.json.tmp"), "junk")
    c.record(repo("other"))
    assert_equal [repo("other")], T::Created.new(@state).paths
    assert_equal 0o600, File.stat(File.join(@state, "created.json")).mode & 0o777
  end

  def test_the_clone_url_is_parsed_strictly
    assert_equal({ host: "github.com", owner: "you", repo: "app", url: "https://github.com/you/app.git" },
                 T.clone_url!("https://GitHub.com/you/app"))
    assert_equal "git@github.com:you/app.git", T.clone_url!("git@github.com:you/app.git")[:url]
    ["https://github.com/robertziel/../octocat/Hello-World", "https://github.com/you/%2e%2e", "https://github.com/you/app?x=1",
     "https://github.com/you/app#frag", "https://github.com/you/app/../x", "https://github.com/you/..",
     "https://u@github.com/you/app", "https://github.com:8443/you/app", "https://github.com/you/app/extra",
     "git@github.com:you/../app", "ssh://git@github.com/you/app", "file:///tmp/x", "",].each do |u|
      assert_raises(T::Invalid, u) { T.clone_url!(u) }
    end
  end

  # the clone ignores the operator's global / system gitconfig: an insteadOf + protocol.file.allow there would turn a
  # https URL into a local clone
  def test_the_clone_ignores_global_gitconfig
    bare = File.join(@tmp, "bare.git")
    git!("clone", "-q", "--bare", repo("app"), bare)
    home = File.join(@tmp, "home")
    FileUtils.mkdir_p(home)
    gitconfig = File.join(home, ".gitconfig")
    File.write(gitconfig, "[protocol \"file\"]\n\tallow = always\n[url \"file://#{bare}\"]\n\tinsteadOf = https://fixture.test/g/app\n")
    control = File.join(@tmp, "control")
    _o, err, st = Open3.capture3({ "HOME" => home, "GIT_CONFIG_GLOBAL" => gitconfig },
                                 *T.clone_argv("https://fixture.test/g/app", control))
    assert st.success?, "the fixture works without clone_env: #{err}"
    empty = Dir.mktmpdir("clone-home", @tmp)
    template = Dir.mktmpdir("clone-template", @tmp)
    _o, err, st = Open3.capture3(T.clone_env(empty, template),
                                 *T.clone_argv("https://fixture.test/g/app", File.join(@tmp, "dest")), unsetenv_others: true)
    refute st.success?
    refute_match(/transport 'file'/, err, "the insteadOf was never read: git tried the https host itself")
  end

  # nothing of the launcher's own environment reaches the clone: an inherited GIT_CONFIG_COUNT / GIT_CONFIG_PARAMETERS
  # (an insteadOf + protocol.file.allow), GIT_SSH_COMMAND or GIT_TEMPLATE_DIR (hooks) has no effect
  def test_the_clone_inherits_nothing
    bare = File.join(@tmp, "bare.git")
    git!("clone", "-q", "--bare", repo("app"), bare)
    hooks = File.join(@tmp, "evil-template/hooks")
    FileUtils.mkdir_p(hooks)
    File.write(File.join(hooks, "post-checkout"), "#!/bin/sh\n")
    parent = ENV.to_h.merge("GIT_CONFIG_COUNT" => "2", "GIT_CONFIG_KEY_0" => "url.file://#{bare}.insteadOf",
                            "GIT_CONFIG_VALUE_0" => "https://fixture.test/g/app", "GIT_CONFIG_KEY_1" => "protocol.file.allow",
                            "GIT_CONFIG_VALUE_1" => "always", "GIT_CONFIG_PARAMETERS" => "'protocol.ext.allow'='always'",
                            "GIT_SSH_COMMAND" => "false", "GIT_TEMPLATE_DIR" => File.dirname(hooks),
                            "SSH_AUTH_SOCK" => "/run/agent.sock", "LANG" => "C.UTF-8",)
    env = T.clone_env(File.join(@tmp, "h"), File.join(@tmp, "t"), parent: parent)
    assert_equal({ "PATH" => parent["PATH"], "HOME" => File.join(@tmp, "h"), "GIT_CONFIG_GLOBAL" => "/dev/null",
                   "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TEMPLATE_DIR" => File.join(@tmp, "t"), "GIT_LFS_SKIP_SMUDGE" => "1",
                   "GIT_TERMINAL_PROMPT" => "0", "SSH_AUTH_SOCK" => "/run/agent.sock", "LANG" => "C.UTF-8", }, env)
    # control: with the parent's environment the insteadOf turns the https URL into a local clone
    _o, err, st = Open3.capture3(parent, *T.clone_argv("https://fixture.test/g/app", File.join(@tmp, "c1")))
    assert st.success?, "control: #{err}"
    assert File.exist?(File.join(@tmp, "c1/.git/hooks/post-checkout")), "control: the template was used"
    # the launcher's way: nothing inherited
    FileUtils.mkdir_p([File.join(@tmp, "h"), File.join(@tmp, "t")])
    _o, err, st = Open3.capture3(env, *T.clone_argv("https://fixture.test/g/app", File.join(@tmp, "c2")),
                                 unsetenv_others: true)
    refute st.success?
    refute_match(/transport 'file'/, err)
    refute File.exist?(File.join(@tmp, "c2"))
    launcher = File.read(File.expand_path("../../bin/launcher", __dir__))
    assert_includes launcher, '%i[out err] => [log, "w"], in: File::NULL, unsetenv_others: true)'
  end

  # record takes only a fresh git init: nothing beside .git, no object, no ref
  def test_record_refuses_anything_but_a_fresh_init
    c = created
    File.write(File.join(repo("other"), "README"), "x")
    assert_raises(T::Invalid) { c.record(repo("other")) }
    FileUtils.rm_f(File.join(repo("other"), "README"))
    FileUtils.mkdir_p(File.join(repo("other"), ".git/objects/ab"))
    File.write(File.join(repo("other"), ".git/objects/ab/cdef"), "blob")
    e = assert_raises(T::Invalid) { c.record(repo("other")) }
    assert_match(/not a fresh git init \(1 objects, 0 refs\)/, e.message)
    FileUtils.rm_rf(File.join(repo("other"), ".git/objects/ab"))
    File.write(File.join(repo("other"), ".git/refs/heads/main"), "0" * 40)
    assert_raises(T::Invalid) { c.record(repo("other")) }
    assert_empty c.paths
    refute File.exist?(File.join(repo("other"), ".git/busyyaks-created")), "checked before the nonce is written"
  end

  # the nonce is never written through a symlink planted at its name
  def test_record_never_follows_a_symlinked_nonce
    c = created
    target = File.join(@tmp, "elsewhere")
    File.write(target, "keep")
    File.symlink(target, File.join(repo("other"), ".git/busyyaks-created"))
    assert_raises(Errno::ELOOP) { c.record(repo("other")) }
    assert_equal "keep", File.read(target)
    assert_empty c.paths
  end

  # a clone that needs credentials fails at once: no terminal prompt, ssh in batch mode, stdin /dev/null
  def test_a_clone_needing_credentials_fails_fast
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    t = Thread.new do
      loop do
        c = server.accept
        loop do
          l = c.gets
          break if l.nil? || l == "\r\n"
        end
        c.write("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"x\"\r\nContent-Length: 0\r\n\r\n")
        c.close
      end
    rescue IOError
      nil
    end
    argv = T.clone_argv("http://127.0.0.1:#{port}/you/app.git", File.join(@tmp, "dest"))
    argv.insert(1, "-c", "protocol.http.allow=always") # http only for this local server (the launcher's is https)
    env = T.clone_env(Dir.mktmpdir("h", @tmp), Dir.mktmpdir("t", @tmp))
    assert_equal "0", env["GIT_TERMINAL_PROMPT"]
    assert_includes argv.each_cons(2).to_a, ["-c", "core.sshCommand=ssh -o BatchMode=yes"]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _o, err, st = Open3.capture3(env, *argv, in: File::NULL, unsetenv_others: true)
    refute st.success?
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10, "it never waited on a prompt"
    assert_match(/terminal prompts disabled|could not read Username|Authentication failed/, err)
    launcher = File.read(File.expand_path("../../bin/launcher", __dir__))
    assert_includes launcher, '%i[out err] => [log, "w"], in: File::NULL, unsetenv_others: true)'
  ensure
    server&.close
    t&.kill
  end
end
