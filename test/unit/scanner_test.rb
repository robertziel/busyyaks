# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "minitest/mock"
require "busyyaks/config"
require "busyyaks/scanner"

class ScannerTest < Minitest::Test
  include DBReset

  def git(dir, *args, email: "me@x.io")
    env = { "GIT_AUTHOR_NAME" => "n", "GIT_AUTHOR_EMAIL" => email, "GIT_COMMITTER_NAME" => "n", "GIT_COMMITTER_EMAIL" => email }
    system(env, "git", "-C", dir, *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
  end

  # roots: [[path, prefix], …]; everything else is the same for every test
  def scan_config(roots, owner_remotes: ["example.com/x/"])
    Busyyaks::Config.new("roots" => roots.map { |path, prefix| { "path" => path, "prefix" => prefix } }, "search_depth" => 2,
                         "owner_remotes" => owner_remotes, "author_emails" => ["me@x.io"], "window_days" => 7,
                         "reap_protect" => [], "auth" => { "provider" => "none" },
                         "agents" => { "collector" => "none" }, "launch" => { "trusted_paths" => [] })
  end

  def test_scans_own_and_upstream_repos
    Dir.mktmpdir do |root|
      own = File.join(root, "mine")
      up = File.join(root, "theirs")
      [own, up].each { |d| Dir.mkdir(d); git(d, "init", "-q", "-b", "main") }
      git(own, "commit", "-q", "--allow-empty", "-m", "first own")
      git(own, "remote", "add", "origin", "https://user:s3cret@github.com/me/mine.git")
      git(up, "commit", "-q", "--allow-empty", "-m", "upstream work", email: "other@y.io")
      git(up, "remote", "add", "origin", "https://github.com/other/theirs.git")
      File.write(File.join(own, "wip.txt"), "x")
      Dir.mkdir(File.join(root, "not-a-repo"))

      config = scan_config([[root, ""]], owner_remotes: ["github.com/me/"])
      assert_equal 2, Busyyaks::Scanner.new(config, store).run

      mine = store.project("mine")
      assert_equal true, mine[:own]
      assert_equal "https://github.com/me/mine.git", mine[:remote], "userinfo must be stripped"
      assert_equal 1, mine[:dirty]
      assert_equal ["?? wip.txt"], JSON.parse(mine[:dirty_paths]), "the daily report reads these, never git on the host"
      assert_equal 1, mine[:mine_window]
      assert_nil mine[:unpushed], "no upstream = unknown, not 0"

      theirs = store.project("theirs")
      assert_equal false, theirs[:own]
      assert_equal 0, theirs[:mine_window]
      assert_equal ["upstream work"], store.commits(slug: "theirs").map { |c| c[:subject] }
      assert_nil store.last_scan[:error]
    end
  end

  # git status failing (a corrupt index) → dirty_paths unknown (nil), never "[]" = clean
  def test_failed_status_leaves_dirty_paths_unknown
    Dir.mktmpdir do |root|
      repo = File.join(root, "broken")
      Dir.mkdir(repo)
      git(repo, "init", "-q", "-b", "main")
      git(repo, "commit", "-q", "--allow-empty", "-m", "first")
      File.write(File.join(repo, ".git", "index"), "not an index")
      refute system("git", "-C", repo, "status", "--porcelain", out: File::NULL, err: File::NULL), "status must fail"

      Busyyaks::Scanner.new(scan_config([[root, ""]]), store).run

      assert_nil store.project("broken")[:dirty_paths]
    end
  end

  # `own` uses the launcher's owner rule (OwnerRemotes): a segment boundary, never a substring
  def test_own_is_the_shared_owner_rule
    Dir.mktmpdir do |root|
      { "a" => "https://github.com/me/a.git", "b" => "https://github.com/me-evil/b.git",
        "c" => "https://evil.example/github.com/me/c.git", "d" => "https://github.com/me/../evil/d.git", }.each do |n, url|
        d = File.join(root, n)
        Dir.mkdir(d); git(d, "init", "-q", "-b", "main"); git(d, "remote", "add", "origin", url)
      end
      Busyyaks::Scanner.new(scan_config([[root, ""]], owner_remotes: ["github.com/me/"]), store).run
      assert_equal({ "a" => true, "b" => false, "c" => false, "d" => false },
                   %w[a b c d].to_h { |n| [n, store.project(n)[:own]] })
    end
  end

  # a scan in progress has no result — last_scan is the last finished one, never the running one
  def test_last_scan_skips_a_scan_in_progress
    done = store.scan_started(100)
    store.scan_finished(done, 110, 3, nil)
    store.scan_started(200)
    assert_equal 110, store.last_scan[:finished_at]
  end

  # the private local-repo enrolment (the guard.* git config) → local / public repos; a broken one is said
  def test_local_enrolment_from_guard_config
    Dir.mktmpdir do |root|
      d = File.join(root, "widgets")
      Dir.mkdir(d)
      git(d, "init", "-q", "-b", "local")
      git(d, "commit", "-q", "--allow-empty", "-m", "c")
      git(d, "remote", "add", "origin", "https://u:tok@github.com/me/widgets_local.git")
      git(d, "remote", "add", "upstream", "https://github.com/me/widgets.git")
      config = scan_config([[root, ""]], owner_remotes: ["github.com/me/"])
      cols = %i[local_mode local_repo public_repo public_head local_error]
      scan = lambda do
        Busyyaks::Scanner.new(config, store).run
        store.project("widgets").values_at(*cols)
      end
      assert_equal [nil] * 5, scan.call, "not enrolled"
      { "guard.mode" => "upstream", "guard.mirrorRemote" => "origin", "guard.upstreamRemote" => "upstream",
        "guard.publicRemote" => "fork", }.each { |k, v| git(d, "config", k, v) }
      assert_equal ["upstream", "https://github.com/me/widgets_local.git", "https://github.com/me/widgets.git", nil,
                    'guard.publicRemote names remote "fork", which has no URL',],
                   scan.call, "the known repos stay; only the fork is said missing"
      git(d, "remote", "add", "fork", "git@github.com:me/widgets_fork.git")
      assert_equal ["upstream", "https://github.com/me/widgets_local.git", "https://github.com/me/widgets.git",
                    "git@github.com:me/widgets_fork.git", nil,],
                   scan.call
      git(d, "config", "guard.mode", "weird")
      assert_equal 'guard.mode is "weird", not own or upstream', scan.call.last
    end
  end

  # the repo the branch's work is pushed to (its PRs live there), not origin
  def test_pr_remote_is_the_branch_push_remote_in_git_order
    Dir.mktmpdir do |root|
      d = File.join(root, "widgets")
      Dir.mkdir(d)
      git(d, "init", "-q", "-b", "main")
      git(d, "commit", "-q", "--allow-empty", "-m", "c")
      git(d, "remote", "add", "origin", "https://github.com/acme/widgets.git")
      git(d, "remote", "add", "local", "git@github.com:me/widgets_local.git")
      git(d, "remote", "add", "fork", "https://github.com/me/widgets_fork.git")
      config = scan_config([[root, ""]], owner_remotes: ["github.com/me/"])
      scan = lambda do
        Busyyaks::Scanner.new(config, store).run
        store.project("widgets").values_at(:remote, :pr_remote)
      end
      assert_equal ["https://github.com/acme/widgets.git"] * 2, scan.call, "no push remote, no upstream → origin"
      git(d, "config", "branch.main.remote", "local")
      assert_equal "git@github.com:me/widgets_local.git", scan.call[1], "the upstream's remote"
      git(d, "config", "remote.pushDefault", "fork")
      assert_equal "https://github.com/me/widgets_fork.git", scan.call[1], "remote.pushDefault beats the upstream"
      git(d, "config", "branch.main.pushRemote", "local")
      assert_equal ["https://github.com/acme/widgets.git", "git@github.com:me/widgets_local.git"], scan.call,
                   "pushRemote first; remote stays origin"
    end
  end

  def test_nested_root_is_namespaced_and_does_not_collide
    Dir.mktmpdir do |root|
      group = File.join(root, "group")
      [File.join(root, "same"), File.join(group, "same")].each do |d|
        FileUtils.mkdir_p(d); git(d, "init", "-q", "-b", "main"); git(d, "commit", "-q", "--allow-empty", "-m", "c #{d}")
      end
      config = scan_config([[root, ""], [group, "group/"]])
      assert_equal 2, Busyyaks::Scanner.new(config, store).run
      assert_equal %w[group/same same], store.projects.map { |p| p[:slug] }.sort
      assert_equal 1, store.commits(slug: "group/same").size
      assert store.project("same")[:own], "no remote = own"
    end
  end

  def test_trees_are_searched_search_depth_subdirs_down
    Dir.mktmpdir do |root|
      %w[top grp/a grp/b/c grp/b/d/too_deep top/inner deep/x/y/z .hidden/r].each do |rel|
        d = File.join(root, rel)
        FileUtils.mkdir_p(d); git(d, "init", "-q", "-b", "main"); git(d, "commit", "-q", "--allow-empty", "-m", rel)
      end
      FileUtils.mkdir_p(File.join(root, "plain", "sub"))
      config = scan_config([[root, ""]])
      assert_equal 3, Busyyaks::Scanner.new(config, store).run
      assert_equal %w[grp/a grp/b/c top], store.projects.map { |p| p[:slug] }.sort
    end
  end

  def test_group_that_is_a_root_is_scanned_once_under_its_prefix
    Dir.mktmpdir do |root|
      d = File.join(root, "grp", "a")
      FileUtils.mkdir_p(d); git(d, "init", "-q", "-b", "main"); git(d, "commit", "-q", "--allow-empty", "-m", "a")
      config = scan_config([[root, ""], [File.join(root, "grp"), "g/"]])
      assert_equal 1, Busyyaks::Scanner.new(config, store).run
      assert_equal %w[g/a], store.projects.map { |p| p[:slug] }
    end
  end

  def test_repo_without_commits_has_no_last_commit
    Dir.mktmpdir do |root|
      d = File.join(root, "empty")
      Dir.mkdir(d); git(d, "init", "-q", "-b", "main")
      config = scan_config([[root, ""]])
      Busyyaks::Scanner.new(config, store).run
      assert_nil store.project("empty")[:last_commit_at]
    end
  end

  # a repo the GitRead child refuses (here core.worktree) is an error on THAT repo: the others are scanned, the scan's
  # error names it, its last good row stays with the reason, and the next good read clears it
  def test_an_unreadable_repo_fails_alone_and_keeps_its_last_read
    Dir.mktmpdir do |root|
      good, bad = %w[good bad].map do |n|
        File.join(root, n).tap { |d|
 Dir.mkdir(d); git(d, "init", "-q", "-b", "main"); git(d, "commit", "-q", "--allow-empty", "-m", n) }
      end
      git(bad, "branch", "feature")
      config = scan_config([[root, ""]])
      assert_equal 2, Busyyaks::Scanner.new(config, store).run
      assert_nil store.last_scan[:error]
      row = store.project("bad")
      assert_equal [%w[feature main], "main", nil], [JSON.parse(row[:branches]), row[:default_ref], row[:git_error]]

      git(bad, "config", "core.worktree", good)
      git(good, "commit", "-q", "--allow-empty", "-m", "more")
      assert_equal 2, Busyyaks::Scanner.new(config, store).run
      assert_match(/\A1 of 2 repos not read — bad: .*core\.worktree is set/, store.last_scan[:error])
      after = store.project("bad")
      assert_match(/core\.worktree is set/, after[:git_error])
      assert_equal row.slice(:branches, :default_ref, :last_commit_at, :commits_window),
after.slice(:branches, :default_ref, :last_commit_at, :commits_window)
      assert_equal 2, store.project("good")[:commits_window], "the readable repo was scanned"
      assert after[:present]

      git(bad, "config", "--unset", "core.worktree")
      Busyyaks::Scanner.new(config, store).run
      assert_nil store.project("bad")[:git_error]
      assert_nil store.last_scan[:error]
    end
  end

  # a planted repo whose .git/config (or packed-refs, or an include target) is a FIFO never stalls the scan: that repo
  # is an error well inside the read timeout and the next repo is scanned (card #258 critic6, card #260 comment 7364)
  def test_a_fifo_repo_errors_inside_the_timeout_and_the_scan_goes_on
    Dir.mktmpdir do |root|
      dirs = %w[a-cfg b-refs c-inc d-good].map do |n|
        File.join(root, n).tap { |d|
 Dir.mkdir(d); git(d, "init", "-q", "-b", "main"); git(d, "commit", "-q", "--allow-empty", "-m", n) }
      end
      cfg, refs, inc, = dirs
      File.delete(File.join(cfg, ".git", "config"))
      File.mkfifo(File.join(cfg, ".git", "config"))
      File.mkfifo(File.join(refs, ".git", "packed-refs"))
      File.mkfifo(File.join(inc, ".git", "fifo"))
      File.open(File.join(inc, ".git", "config"), "a") { |f| f.puts("[include]\n\tpath = fifo") }
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal 4, Busyyaks::Scanner.new(scan_config([[root, ""]]), store).run
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, Busyyaks::GitRead.limits[:timeout]
      error = store.last_scan[:error]
      assert_match(/\A3 of 4 repos not read/, error)
      assert_match(/a-cfg: .*config is not a regular file/, error)
      assert_match(/b-refs: .*packed-refs is not a regular file/, error)
      assert_match(/c-inc: .*includes another file/, error)
      assert_equal 1, store.project("d-good")[:commits_window]
    end
  end

  def test_missing_root_records_failure
    config = scan_config([["/definitely/missing", ""]])
    assert_raises(Errno::ENOENT) { Busyyaks::Scanner.new(config, store).run }
    assert_match(/root not mounted/, store.last_scan[:error])
  end

  # a repo's own config names programs git would run on status (core.fsmonitor, filter.<x>) — the scan never runs them
  def test_a_repos_fsmonitor_never_runs
    Dir.mktmpdir do |root|
      d = File.join(root, "trap")
      Dir.mkdir(d); git(d, "init", "-q", "-b", "main")
      git(d, "commit", "-q", "--allow-empty", "-m", "c")
      marker = File.join(root, "ran")
      hook = File.join(root, "fsmonitor.sh")
      File.write(hook, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod(0o755, hook)
      git(d, "config", "core.fsmonitor", hook)
      # a clean filter in the repo's config, wired in by a tracked-file attribute and by info/attributes: status
      # hashes the stat-dirty file, which is where it would run
      git(d, "config", "filter.x.clean", "sh -c 'touch #{marker}; cat'")
      git(d, "config", "filter.x.process", "sh -c 'touch #{marker}'")
      File.write(File.join(d, "f"), "x")
      git(d, "add", "f")
      git(d, "-c", "filter.x.clean=cat", "commit", "-q", "-m", "f")
      File.write(File.join(d, ".git/info/attributes"), "f filter=x\n")
      File.write(File.join(d, ".gitattributes"), "* filter=x\n")
      File.write(File.join(d, "f"), "y")
      File.utime(Time.at(1), Time.at(1), File.join(d, "f"))
      FileUtils.rm_f(marker)
      Busyyaks::Scanner.new(scan_config([[root, ""]]), store).run
      assert_equal 2, store.project("trap")[:dirty], "f modified + .gitattributes untracked"
      refute File.exist?(marker), "a repo-config program (fsmonitor / filter) ran during the scan"
    end
  end
end
