# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "busyyaks/git_read"

# Every read of a scanned repo is a GitRead child (bin/git-read, libgit2): it runs no program a repo's config names,
# refuses a repo that points out of the projects root or blocks on a FIFO, and is killed on its limits — each case a
# loud error on that repo, never a hang, never a number made up, never the git CLI instead (card #260's fixtures).
class GitReadTest < Minitest::Test
  GR = Busyyaks::GitRead
  ENV_GIT = { "GIT_AUTHOR_NAME" => "Ann", "GIT_AUTHOR_EMAIL" => "ann@x.io", "GIT_COMMITTER_NAME" => "Ann",
              "GIT_COMMITTER_EMAIL" => "ann@x.io", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", }.freeze
  SCAN = { since: 0, max_commits: 500, daily_since: 0, max_daily: 50_000,
           config_keys: %w[branch.%{branch}.pushRemote remote.pushDefault guard.mode], }.freeze

  def setup
    @root = File.realpath(Dir.mktmpdir("gitread"))
    @sentinels = File.join(@root, "SENTINELS")
    Dir.mkdir(@sentinels)
  end

  def teardown = FileUtils.rm_rf(@root)

  # fixtures are built with the git CLI BEFORE any hostile config is written; nothing here runs git on them after
  def git(dir, *args, env: {})
    out, err, st = Open3.capture3(ENV_GIT.merge(env), "git", "-C", dir, *args)
    raise "git #{args.join(' ')}: #{err}" unless st.success?

    out.strip
  end

  def repo(name = "r", root: @root)
    d = File.join(root, name)
    FileUtils.mkdir_p(d)
    git(d, "init", "-q", "-b", "main")
    d
  end

  def commit(dir, file, body, msg = "c #{file}", env: {})
    FileUtils.mkdir_p(File.dirname(File.join(dir, file)))
    File.write(File.join(dir, file), body)
    git(dir, "add", "--", file)
    git(dir, "commit", "-q", "-m", msg, env: env)
    git(dir, "rev-parse", "HEAD")
  end

  def read(op, dir, root: @root, host_root: GR.host_root, mount: GR.mount, limits: GR.limits, **args)
    GR.call(op, path: dir, root: root, host_root: host_root, mount: mount, limits: limits, **args)
  end

  # the child's library run in this (test) process: the same request, the same answer
  def in_process(op, dir, root: @root, host_root: GR.host_root, mount: GR.mount, **args)
    require "busyyaks/git_reader"
    req = args.merge(op: op, path: dir, root: root, host_root: host_root, mount: mount,
                     max_blob: GR.limits[:max_blob], memory: GR.limits[:memory])
    JSON.parse(Busyyaks::GitReader.serve(JSON.generate(req)))
  end

  # refused by the child, loudly and at once — and by the library itself with the same reason
  def refused(op, dir, pattern, **args)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    e = assert_raises(GR::Failed) { read(op, dir, **args) }
    assert_match pattern, e.message
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
    inproc = in_process(op, dir, **args.except(:limits))
    assert_equal [false, e.message.delete_prefix("#{dir}: ")], [inproc["ok"], inproc["error"]]
    took
  end

  def touch(name) = "touch #{File.join(@sentinels, name)}"
  def sentinels = Dir.children(@sentinels).sort

  # ── the build ─────────────────────────────────────────────────────────────────────────────────

  # the image's own libgit2 (Dockerfile stage libgit2), with no network transport: version and features pinned
  def test_libgit2_is_the_images_pinned_build_without_transports
    require "rugged"
    pinned = File.read(File.expand_path("../../Dockerfile", __dir__))[/^ARG LIBGIT2_VERSION=(\S+)$/, 1]
    assert_equal pinned, Rugged.libgit2_version.join(".")
    assert_equal pinned, File.read("/opt/libgit2/VERSION").strip
    assert_equal [:threads], Rugged.features
    assert(GR.load_path.any? { |p| p.include?("rugged-") }, "the child loads the bundle's rugged")
  end

  # ── nothing a repo names is run ───────────────────────────────────────────────────────────────

  def test_a_repo_that_names_programs_everywhere_runs_none_of_them
    d = repo
    s1 = commit(d, "a.txt", "one\n")
    File.write(File.join(d, ".gitattributes"), "* filter=a=b diff=d\n*.txt filter=plain\n")
    git(d, "add", ".gitattributes")
    s2 = commit(d, "a.txt", "one\ntwo\n")
    # a submodule whose own config names a filter too
    sub = repo("subsrc")
    commit(sub, "s.txt", "s\n")
    git(d, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sub")
    git(d, "commit", "-q", "-m", "sub")
    s3 = git(d, "rev-parse", "HEAD")
    subgit = File.join(d, ".git", "modules", "sub")
    File.write(File.join(subgit, "info", "attributes"), "* filter=x\n")
    git(subgit, "config", "filter.x.clean", touch("sub-clean"))
    File.write(File.join(d, "sub", "s.txt"), "changed\n")
    # every program-naming key git has, in the repo's own config, written last
    File.write(File.join(d, ".git", "info", "attributes"), "* filter=a=b diff=d\n")
    { "filter.a=b.clean" => "clean", "filter.a=b.smudge" => "smudge", "filter.a=b.process" => "process",
      "filter.plain.clean" => "plain", "core.fsmonitor" => "fsmonitor", "diff.d.textconv" => "textconv",
      "diff.d.command" => "diffcmd", "diff.external" => "external", "core.pager" => "pager",
      "core.askPass" => "askpass", "gpg.program" => "gpg", "core.sshCommand" => "ssh", }.each { |k, v| git(d, "config", k,
touch(v)) }
    git(d, "config", "filter.a=b.required", "true")
    %w[pre-commit post-checkout post-index-change reference-transaction fsmonitor-watchman].each do |h|
      File.write(File.join(d, ".git", "hooks", h), "#!/bin/sh\n#{touch("hook-#{h}")}\n")
      File.chmod(0o755, File.join(d, ".git", "hooks", h))
    end
    File.write(File.join(d, "a.txt"), "one\ntwo\nthree\n") # a dirty file the filters would have to clean
    File.write(File.join(d, "new.txt"), "n\n")

    scan = read("scan", d, **SCAN)
    assert_equal 2, scan["dirty"], "a.txt and new.txt; the submodule is never looked into"
    assert_equal "main", scan["branch"]
    assert_equal 3, scan["commits"].size
    read("head", d)
    churn = read("churn", d, shas: [s1, s2, s3])["files"]
    assert_equal [["a.txt", 1, 0], [".gitattributes", 2, 0], ["a.txt", 1, 0]], churn.first(3).map { |f| f.first(3) }
    assert_equal({ "a.txt" => "main" }, read("files_at", d, refs: %w[main HEAD], files: ["a.txt"])["found"])
    assert_empty sentinels, "libgit2 ran a program the repo named"
  end

  # ── refused before libgit2 opens it ───────────────────────────────────────────────────────────

  def test_an_include_is_refused_fifo_or_fan_out
    d = repo
    commit(d, "a", "a\n")
    File.mkfifo(File.join(d, ".git", "fifo"))
    File.open(File.join(d, ".git", "config"), "a") { |f| f.puts("[include]\n\tpath = fifo") }
    assert_operator refused("head", d, /includes another file/), :<, 5, "refused at once, not on the timeout"

    e = repo("fan")
    commit(e, "a", "a\n")
    8.times do |i|
      File.write(File.join(e, ".git", "inc#{i}"), Array.new(12) { "[include]\n\tpath = inc#{i + 1}\n" }.join)
    end
    File.open(File.join(e, ".git", "config"), "a") { |f| f.puts("  [ IncludeIf \"gitdir:/\" ]\n\tpath = inc0") }
    assert_operator refused("scan", e, /includes another file/, **SCAN), :<, 5
  end

  def test_a_fifo_where_libgit2_reads_a_file_is_refused
    %w[config packed-refs HEAD index info/exclude].each do |f|
      d = repo("fifo-#{f.tr('/', '-')}")
      commit(d, "a", "a\n")
      path = File.join(d, ".git", f)
      FileUtils.rm_f(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.mkfifo(path)
      assert_operator refused("scan", d, /#{Regexp.escape(f)} is not a regular file/, **SCAN), :<, 5, f
    end
  end

  def test_commondir_alternates_gitdir_and_worktree_outside_the_root_are_refused
    outside = File.realpath(Dir.mktmpdir("outside"))
    other = repo("other", root: outside)
    commit(other, "secret", "s\n")
    git(other, "remote", "add", "origin", "https://example.com/other.git")

    # a plain repo's commondir → another repo's config, refs and objects
    d = repo("commondir")
    commit(d, "a", "a\n")
    File.write(File.join(d, ".git", "commondir"), "#{other}/.git\n")
    refused("scan", d, /commondir resolves outside/, **SCAN)

    # alternates outside, and nested deeper than libgit2's own limit inside
    a = repo("alt")
    commit(a, "a", "a\n")
    File.write(File.join(a, ".git", "objects", "info", "alternates"), "#{other}/.git/objects\n")
    refused("head", a, /alternate object dir resolves outside/)
    chain = (0..6).map do |i|
      dir = File.join(@root, "objs#{i}")
      FileUtils.mkdir_p(File.join(dir, "info"))
      dir
    end
    chain.each_cons(2) { |x, y| File.write(File.join(x, "info", "alternates"), "#{y}\n") }
    File.write(File.join(a, ".git", "objects", "info", "alternates"), "#{chain.first}\n")
    refused("head", a, /alternates nested deeper than 5/)

    # a .git file whose gitdir: is outside
    g = File.join(@root, "gitfile")
    Dir.mkdir(g)
    File.write(File.join(g, ".git"), "gitdir: #{other}/.git\n")
    refused("head", g, /gitdir resolves outside/)

    # core.worktree: the work tree elsewhere (here inside the root, still refused: the repo dir is what was listed)
    w = repo("worktree")
    commit(w, "a", "a\n")
    git(w, "config", "core.worktree", @sentinels)
    refused("scan", w, /core\.worktree is set/, **SCAN)

    # a symlinked config out of the root
    l = repo("link")
    commit(l, "a", "a\n")
    FileUtils.ln_sf(File.join(other, ".git", "config"), File.join(l, ".git", "config"))
    refused("scan", l, /config resolves outside/, **SCAN)
  ensure
    FileUtils.rm_rf(outside) if outside
  end

  # more commits in the daily series' range than max_daily: no series (an error), never a cut one
  def test_a_daily_series_over_its_cap_is_an_error_not_a_cut_series
    d = repo
    3.times { |i| commit(d, "f#{i}", "x\n") }
    scan = read("scan", d, **SCAN.merge(max_daily: 2))
    assert_equal scan, in_process("scan", d, **SCAN.merge(max_daily: 2))
    assert_nil scan["daily"]
    assert_match(/more than 2 commits since/, scan["daily_error"])
    assert_equal 3, scan["commits"].size, "the window's commits are still read"
  end

  def test_a_linked_worktree_inside_the_root_is_read
    d = repo
    commit(d, "a", "a\n")
    wt = File.join(@root, "wt")
    git(d, "worktree", "add", "-q", "-b", "feature", wt)
    commit(wt, "b", "b\n")
    scan = read("scan", wt, **SCAN)
    assert_equal scan, in_process("scan", wt, **SCAN)
    assert_equal ["feature", 0], [scan["branch"], scan["dirty"]]
    assert_equal %w[feature main], scan["branches"]
  end

  # `git worktree add` on the host writes HOST paths (PROJECTS_ROOT/...) into the worktree's .git file and the git
  # dir's back-pointer; inside the container the same files are under the mount (card #268: 130 repos refused)
  def test_a_linked_worktree_whose_files_name_host_paths_is_read_under_the_mount
    d = repo
    commit(d, "a", "a\n")
    wt = File.join(@root, "wt")
    git(d, "worktree", "add", "-q", "-b", "feature", wt)
    commit(wt, "b", "b\n")
    host = "/host-side/projects"
    admin = File.join(d, ".git", "worktrees", "wt")
    File.write(File.join(wt, ".git"), "gitdir: #{host}/r/.git/worktrees/wt\n")
    File.write(File.join(admin, "gitdir"), "#{host}/wt/.git\n")
    scan = read("scan", wt, host_root: host, mount: @root, **SCAN)
    assert_equal scan, in_process("scan", wt, host_root: host, mount: @root, **SCAN)
    assert_equal ["feature", 0, []], [scan["branch"], scan["dirty"], scan["dirty_paths"]]
    assert_equal %w[feature main], scan["branches"]
    assert_equal "feature", read("head", wt, host_root: host, mount: @root)["branch"]

    # a host path the mount does not hold is not found, loudly
    refused("head", wt, /gitdir cannot be resolved/)
  end

  # a nested `roots` entry (root = mount/group): host paths name the mount's host side, so they are read under the
  # mount, not under root (card #268: root /projects/group named /projects/group/group/...: refused after the first fix)
  # commondir and alternates are read by libgit2 itself, at the path as written: a host path there is refused, never
  # checked under the mount and then opened at the host path (review of the first fix)
  def test_commondir_and_alternates_naming_a_host_path_are_refused
    d = repo
    commit(d, "a", "a\n")
    wt = File.join(@root, "wt")
    git(d, "worktree", "add", "-q", "-b", "feature", wt)
    host = "/host-side/projects"
    File.write(File.join(d, ".git", "worktrees", "wt", "commondir"), "#{host}/r/.git\n")
    refused("head", wt, /commondir names a host path/, host_root: host, mount: @root)

    a = repo("alt")
    commit(a, "b", "b\n")
    File.write(File.join(a, ".git", "objects", "info", "alternates"), "#{host}/r/.git/objects\n")
    refused("head", a, /alternate object dir names a host path/, host_root: host, mount: @root)

    # the same files written relative (git's own commondir) or inside the root as an absolute path are read
    File.write(File.join(d, ".git", "worktrees", "wt", "commondir"), "../..\n")
    File.write(File.join(a, ".git", "objects", "info", "alternates"), "#{d}/.git/objects\n")
    assert_equal "feature", read("head", wt, host_root: host, mount: @root)["branch"]
    assert read("head", a, host_root: host, mount: @root)
  end

  def test_a_linked_worktree_under_a_nested_root_is_read_under_the_mount
    group = File.join(@root, "group")
    Dir.mkdir(group)
    d = repo(root: group)
    commit(d, "a", "a\n")
    wt = File.join(group, "wt")
    git(d, "worktree", "add", "-q", "-b", "feature", wt)
    host = "/host-side/projects"
    File.write(File.join(wt, ".git"), "gitdir: #{host}/group/r/.git/worktrees/wt\n")
    File.write(File.join(d, ".git", "worktrees", "wt", "gitdir"), "#{host}/group/wt/.git\n")
    assert_equal "feature", read("head", wt, root: group, host_root: host, mount: @root)["branch"]
    assert_equal read("scan", wt, root: group, host_root: host, mount: @root, **SCAN),
                 in_process("scan", wt, root: group, host_root: host, mount: @root, **SCAN)

    # the mount's host side mapped onto root instead (the bug) names group/group/r: not found, loudly
    refused("head", wt, /gitdir cannot be resolved/, root: group, host_root: host, mount: group)
  end

  # a .git file that borrows another checkout's worktree git dir (its index, its HEAD) is refused
  def test_a_worktree_git_dir_of_another_checkout_is_refused
    d = repo
    commit(d, "a", "a\n")
    wt = File.join(@root, "wt")
    git(d, "worktree", "add", "-q", "-b", "feature", wt)
    other = File.join(@root, "borrower")
    Dir.mkdir(other)
    File.write(File.join(other, ".git"), "gitdir: #{d}/.git/worktrees/wt\n")
    refused("head", other, /the worktree's git dir belongs to #{Regexp.escape(wt)}\/\.git, not #{Regexp.escape(other)}/)

    # ... and so is one that borrows another checkout's plain .git dir (no worktree, no back-pointer)
    File.write(File.join(other, ".git"), "gitdir: #{d}/.git\n")
    refused("head", other, /the git dir is #{Regexp.escape(d)}'s own \.git, not #{Regexp.escape(other)}'s/)

    # a separate git dir (`git init --separate-git-dir`) is this checkout's: read
    sep = File.join(@root, "sep")
    Dir.mkdir(sep)
    git(sep, "init", "-q", "-b", "main", "--separate-git-dir", File.join(@root, "sep.git"))
    commit(sep, "a", "a\n")
    assert_equal "main", read("head", sep)["branch"]
  end

  # the mount and its host side are part of every request: never assumed
  def test_a_request_without_an_absolute_host_root_is_refused
    require "busyyaks/git_reader"
    d = repo
    req = { op: "head", path: d, root: @root, max_blob: 1 }
    assert_match(/KeyError.*host_root/, JSON.parse(Busyyaks::GitReader.serve(JSON.generate(req)))["error"])
    out = JSON.parse(Busyyaks::GitReader.serve(JSON.generate(req.merge(host_root: "projects"))))
    assert_match(/KeyError.*mount/, out["error"])
    out = JSON.parse(Busyyaks::GitReader.serve(JSON.generate(req.merge(host_root: "projects", mount: "/projects"))))
    assert_equal "Refused: host_root must be an absolute path (got \"projects\")", out["error"]
    out = JSON.parse(Busyyaks::GitReader.serve(JSON.generate(req.merge(host_root: "/h", mount: "projects"))))
    assert_equal "Refused: mount must be an absolute path (got \"projects\")", out["error"]
  end

  def test_sparse_checkout_and_a_bare_repo_are_refused
    d = repo
    commit(d, "a", "a\n")
    git(d, "config", "core.sparseCheckout", "true")
    refused("scan", d, /sparse checkout is not supported/, **SCAN)
    b = File.join(@root, "bare")
    Dir.mkdir(b)
    git(b, "init", "-q", "--bare", ".")
    refused("head", b, /has no \.git/)
  end

  # ── limits ────────────────────────────────────────────────────────────────────────────────────

  # a blob over GIT_READ_MAX_BLOB_BYTES is never loaded: binary, 0 lines, said so. With the cap lifted, the same diff
  # (75 M lines) runs out of the address-space limit, or — with more room — is killed on the clock: loud every time,
  # never a number
  def test_a_huge_file_counts_as_binary_and_never_loads
    d = repo
    big = commit(d, "big.txt", "x\n" * 75_000_000) # 150 MB, 75 M lines
    assert_equal [["big.txt", 0, 0, true, true]], read("churn", d, shas: [big])["files"]
    assert_equal [["big.txt", 0, 0, true, true]], in_process("churn", d, shas: [big])["files"]
    File.write(File.join(d, "big.txt"), "y\n" * 75_000_000)
    assert_equal 1, read("scan", d, **SCAN)["dirty"]
    uncapped = GR.limits.merge(max_blob: 1 << 30)
    e = assert_raises(GR::Failed) { read("churn", d, shas: [big], limits: uncapped) }
    assert_match(/NoMemoryError|out of memory/, e.message)
    e = assert_raises(GR::Failed) do
      read("churn", d, shas: [big], limits: uncapped.merge(memory: 512 << 20, timeout: 2, cpu: 60))
    end
    assert_match(/timed out after 2 s \(killed\)/, e.message)
  end

  # a read that blocks (core.excludesFile = a FIFO: read on status) is killed on the clock; the next read works
  def test_a_read_that_hangs_is_killed_on_the_timeout
    d = repo
    commit(d, "a", "a\n")
    File.write(File.join(d, "untracked"), "u\n")
    fifo = File.join(d, "excludes")
    File.mkfifo(fifo)
    git(d, "config", "core.excludesFile", fifo)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    e = assert_raises(GR::Failed) { read("scan", d, limits: GR.limits.merge(timeout: 2), **SCAN) }
    assert_match(/timed out after 2 s \(killed\)/, e.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 5
    assert_equal "main", read("head", d)["branch"]
  end

  # what the child is given, seen from inside it (a stand-in child run exactly as bin/git-read is): an empty env
  # (no secret of the parent's), cwd /, no fd past stdio, and the limits as rlimits
  def test_the_child_starts_with_an_empty_environment_and_its_limits
    probe = File.join(@root, "probe.rb")
    File.write(probe, <<~RUBY)
      require "json"
      fds = Dir.children("/proc/self/fd").map(&:to_i).reject { |f| f <= 2 }
               .filter_map { |f| File.readlink("/proc/self/fd/\#{f}") rescue nil }
      $stdout.write(JSON.generate(ok: true, env: ENV.to_h, cwd: Dir.pwd, fds: fds,
                                  as: Process.getrlimit(:AS).first, cpu: Process.getrlimit(:CPU).first))
    RUBY
    ENV["GIT_READ_TEST_SECRET"] = "s3cret"
    lim = GR.limits.merge(memory: 300 << 20, cpu: 7)
    out = GR.call("head", path: @root, root: @root, limits: lim, bin: probe)
    assert_equal GR::CHILD_ENV, out["env"].except("RUBYLIB", "RUBYOPT")
    assert_equal "/", out["cwd"]
    assert_equal [300 << 20, 7], [out["as"], out["cpu"]]
    # past stdio only the VM's own (its eventfd / epoll, this dir listing): no pipe, socket or file of the parent
    assert_empty out["fds"].reject { |t| t.match?(%r{\Aanon_inode:|\A/proc/}) }, out["fds"].inspect
  ensure
    ENV.delete("GIT_READ_TEST_SECRET")
  end

  # the CPU limit, a flood of output and an answer that is not the protocol: each a Failed with the reason
  def test_cpu_limit_flood_and_garbage_are_failures
    child = ->(name, code) { File.join(@root, name).tap { |f| File.write(f, code) } }
    # the spinning child ends on its CPU-second whatever the host's load; the wall clock is only a hang guard here, far
    # above it, so a CPU-starved CI host (card #268: load 55 on 20 CPUs, the 20 s clock won) cannot kill it first
    spin = GR.limits.merge(cpu: 1, timeout: 300)
    e = assert_raises(GR::Failed) { GR.call("head", path: @root, root: @root, limits: spin, bin: child.("spin.rb", "loop { }")) }
    assert_match(/git-read stopped: CPU limit 1 s/, e.message)
    flood = child.("flood.rb", "loop { $stdout.write('x' * 65_536) }")
    lim = GR.limits.merge(cpu: 1, timeout: 20)
    e = assert_raises(GR::Failed) { GR.call("head", path: @root, root: @root, limits: lim, bin: flood) }
    assert_match(/answered more than #{GR::MAX_OUTPUT} bytes/, e.message)
    e = assert_raises(GR::Failed) { GR.call("head", path: @root, root: @root, bin: child.("junk.rb", "print 'hello'; exit 3")) }
    assert_match(/exited 3 without an answer/, e.message)
    e = assert_raises(GR::Failed) { GR.call("head", path: @root, root: @root, bin: child.("no.rb", %(print '{"ok":false,"error":"nope"}'))) }
    assert_equal "#{@root}: nope", e.message
  end

  def test_limits_are_required_whole_numbers
    env = GR::LIMIT_KEYS.to_h { |k| [k, "300000000"] }
    assert_equal({ timeout: 300_000_000, cpu: 300_000_000, memory: 300_000_000, max_blob: 300_000_000 }, GR.limits(env))
    GR::LIMIT_KEYS.each do |k|
      assert_raises(GR::Invalid, k) { GR.limits(env.except(k)) }
      assert_raises(GR::Invalid, k) { GR.limits(env.merge(k => "10s")) }
      assert_raises(GR::Invalid, k) { GR.limits(env.merge(k => "0")) }
    end
    e = assert_raises(GR::Invalid) { GR.limits(env.merge("GIT_READ_MEMORY_BYTES" => "1000")) }
    assert_match(/at least #{GR::MIN_MEMORY_BYTES}/, e.message)
  end

  # ── what a request may name ───────────────────────────────────────────────────────────────────

  def test_refs_are_names_and_commits_are_ids_never_revision_expressions
    d = repo
    s = commit(d, "a", "a\n")
    commit(d, "b", "b\n")
    [":/a", "HEAD@{1}", "main~1", "main^{/c}", "main^", "a..b", "x.lock"].each do |r|
      refused("files_at", d, /not a valid branch name/, refs: [r], files: ["a"])
    end
    %w[../a /etc/passwd a//b ./a].each { |f| refused("files_at", d, /not a relative path/, refs: ["main"], files: [f]) }
    ["HEAD", s[0, 12], "main", "#{s}^"].each { |x| refused("churn", d, /not a 40-hex commit id/, shas: [x]) }
    refused("churn", d, /OdbError|not found|odb/i, shas: ["0" * 40])
    tree = git(d, "rev-parse", "HEAD^{tree}")
    refused("churn", d, /is not a commit/, shas: [tree])
    refused("scan", d, /at most 32 strings/, **SCAN.merge(config_keys: Array.new(33, "x")))
    assert_equal({ "ok" => false, "error" => "Refused: unknown op \"nope\"" }, in_process("nope", d))
    assert_match(/ParserError/, JSON.parse(Busyyaks::GitReader.serve("not json"))["error"])
    assert_equal "Refused: the request is not an object", JSON.parse(Busyyaks::GitReader.serve("[1]"))["error"]
  end

  def test_a_path_outside_the_root_and_a_missing_repo_are_refused
    d = repo
    commit(d, "a", "a\n")
    e = assert_raises(GR::Failed) { read("head", d, root: File.join(@root, "elsewhere")) }
    assert_match(/root cannot be resolved/, e.message)
    sibling = File.realpath(Dir.mktmpdir("sib"))
    refused("head", sibling, /repo dir resolves outside/)
    refused("head", File.join(@root, "nope"), /repo dir cannot be resolved/)
  ensure
    FileUtils.rm_rf(sibling) if sibling
  end
end
