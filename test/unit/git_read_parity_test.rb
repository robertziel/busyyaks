# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "set"
require "json"
require "busyyaks/git_read"

# The GitRead child (libgit2) answers what the git CLI answered before it on the same benign repos — the scanner's
# figures, the card links' branches / default ref / files, the daily facts' churn — so the move off the CLI changes
# no number on the dashboard. The CLI runs here only on fixtures this test built, with no hostile config.
class GitReadParityTest < Minitest::Test
  GR = Busyyaks::GitRead
  CLI_ENV = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1" }.freeze

  def setup = @root = File.realpath(Dir.mktmpdir("parity"))
  def teardown = FileUtils.rm_rf(@root)

  def git(dir, *args, who: "ann@x.io", at: nil)
    env = CLI_ENV.merge("GIT_AUTHOR_NAME" => who[/\A[^@]+/], "GIT_AUTHOR_EMAIL" => who,
                        "GIT_COMMITTER_NAME" => who[/\A[^@]+/], "GIT_COMMITTER_EMAIL" => who)
    if at
      env["GIT_AUTHOR_DATE"] = at
      env["GIT_COMMITTER_DATE"] = at
    end
    out, err, st = Open3.capture3(env, "git", "-C", dir, *args)
    [out.strip, st.success? ? nil : err]
  end

  def git!(dir, *args, **kw)
    out, err = git(dir, *args, **kw)
    raise "git #{args.join(' ')}: #{err}" if err

    out
  end

  def commit(dir, file, body, who: "ann@x.io", at: nil)
    FileUtils.mkdir_p(File.dirname(File.join(dir, file)))
    File.write(File.join(dir, file), body)
    git!(dir, "add", "-A")
    git!(dir, "commit", "-q", "-m", "change #{file}\n\nthe body", who: who, at: at)
    git!(dir, "rev-parse", "HEAD")
  end

  NOW = Time.now.to_i
  SINCE = NOW - (30 * 86_400)        # the scanner's window
  DAILY_SINCE = NOW - (371 * 86_400) # its daily series
  SCAN = { since: SINCE, max_commits: 500, daily_since: DAILY_SINCE, max_daily: 50_000,
           config_keys: %w[branch.%{branch}.pushRemote remote.pushDefault branch.%{branch}.remote guard.mode
                           guard.mirrorRemote], }.freeze

  # the child's answer — and the same from its library run in this (test) process
  def read(op, dir, **args)
    require "busyyaks/git_reader"
    out = GR.call(op, path: dir, root: @root, **args)
    req = args.merge(op: op, path: dir, root: @root, host_root: GR.host_root, mount: GR.mount,
                     max_blob: GR.limits[:max_blob], memory: GR.limits[:memory])
    assert_equal out, JSON.parse(Busyyaks::GitReader.serve(JSON.generate(req)))
    out
  end

  # what the scanner and the card links asked the CLI (before card #260), on the same repo
  def cli(dir)
    branch, = git(dir, "branch", "--show-current")
    porcelain, = git(dir, "status", "--porcelain", "--no-renames", "--ignore-submodules=all")
    unpushed, err = git(dir, "rev-list", "--count", "@{u}..HEAD")
    last, = git(dir, "log", "-1", "--all", "--format=%ct")
    log, = git(dir, "log", "--all", "--since=@#{SINCE}", "-n", "500", "--format=%H\x1f%an\x1f%ae\x1f%ct\x1f%s")
    daily, = git(dir, "log", "--all", "--since=@#{DAILY_SINCE}", "--format=%ae\x1f%cs")
    heads, = git(dir, "for-each-ref", "--format=%(refname:short)", "refs/heads")
    remotes, = git(dir, "for-each-ref", "--format=%(refname:short)", "refs/remotes")
    ref, ref_err = git(dir, "rev-parse", "--abbrev-ref", "HEAD")
    { "branch" => branch, "dirty" => porcelain.lines.size, "unpushed" => err ? nil : unpushed.to_i,
      "last_commit_at" => last.empty? ? nil : last.to_i,
      "commits" => log.lines.map do |l|
        sha, an, ae, ct, s = l.chomp.split("\x1f", 5)
        { "sha" => sha, "author" => an, "email" => ae.downcase, "committed_at" => ct.to_i, "subject" => s }
      end.sort_by { |c| c["sha"] }, # same-second commits come in either order: stored as rows, order is no figure
      "daily" => daily.lines.each_with_object(Hash.new { |h, k| h[k] = Hash.new(0) }) do |l, acc|
        e, day = l.chomp.split("\x1f", 2)
        acc[day][e.downcase] += 1
      end,
      "branches" => (heads.lines.map(&:strip) + (remotes.lines.map(&:strip) - heads.lines.map(&:strip))
                       .map { |r| r.sub(%r{\A[^/]+/}, "") })
                      .reject { |b| b.empty? || b == "HEAD" || b.end_with?("/HEAD") }.uniq.sort,
      "default_ref" => ref_err ? "HEAD" : ref, }
  end

  def assert_parity(dir, msg)
    got = read("scan", dir, **SCAN)
    want = cli(dir)
    got["commits"] = got["commits"].sort_by { |c| c["sha"] }
    want.each { |k, v| v.nil? ? assert_nil(got[k], "#{msg}: #{k}") : assert_equal(v, got[k], "#{msg}: #{k}") }
  end

  def test_scan_matches_the_cli_across_repo_states
    remote = File.join(@root, "remote.git")
    git!(@root, "init", "-q", "--bare", "-b", "main", remote)
    d = File.join(@root, "work")
    git!(@root, "clone", "-q", remote, d)
    git!(d, "checkout", "-q", "-b", "main")
    commit(d, "a.txt", "1\n", at: Time.at(NOW - (90 * 86_400)).utc.strftime("%FT23:30:00+05:00")) # daily only
    commit(d, "lib/b.rb", "b\n", who: "Bob@Y.io", at: Time.at(NOW - (5 * 86_400)).utc.strftime("%FT01:00:00-08:00"))
    git!(d, "push", "-q", "-u", "origin", "main")
    3.times { |i| commit(d, "c#{i}", "c\n") } # ahead 3
    git!(d, "branch", "feature/x")
    git!(d, "tag", "-a", "v1", "-m", "v1")
    git!(d, "config", "branch.main.pushRemote", "mirror")
    git!(d, "config", "guard.mode", "own")
    git!(d, "remote", "add", "mirror", "https://example.com/m.git")
    # dirt: tracked change, staged new file, staged delete, untracked dir with files, ignored file
    File.write(File.join(d, "a.txt"), "2\n")
    File.write(File.join(d, "staged.txt"), "s\n")
    git!(d, "add", "staged.txt")
    git!(d, "rm", "-q", "c0")
    FileUtils.mkdir_p(File.join(d, "newdir/deep"))
    File.write(File.join(d, "newdir/deep/x"), "x")
    File.write(File.join(d, ".gitignore"), "*.log\n")
    File.write(File.join(d, "noise.log"), "x")
    assert_parity(d, "dirty, ahead of upstream")
    got = read("scan", d, **SCAN)
    assert_equal({ "branch.main.pushRemote" => "mirror", "remote.pushDefault" => nil, "branch.main.remote" => "origin",
                   "guard.mode" => "own", "guard.mirrorRemote" => nil, }, got["config"])
    assert_equal({ "origin" => remote, "mirror" => "https://example.com/m.git" }, got["remotes"])

    # `git push -u <url>` stores the URL as the branch's remote (card #268): no remote-tracking upstream, git's @{u}
    # fails → unpushed unknown (nil); the same for a remote that was removed
    git!(d, "config", "branch.main.remote", "https://example.com/r.git")
    assert_parity(d, "upstream remote is a URL")
    assert_nil read("scan", d, **SCAN)["unpushed"]
    git!(d, "config", "branch.main.remote", "gone")
    assert_parity(d, "upstream remote removed")
    git!(d, "config", "branch.main.remote", "origin")

    git!(d, "stash", "-q", "-u") # refs/stash is a ref too: --all reads it
    assert_parity(d, "stashed")
    git!(d, "checkout", "-q", "--detach", "HEAD~1")
    assert_parity(d, "detached")
    git!(d, "checkout", "-q", "--orphan", "fresh")
    assert_parity(d, "unborn branch")

    empty = File.join(@root, "empty")
    git!(@root, "init", "-q", "-b", "trunk", empty)
    assert_parity(empty, "no commit at all")
  end

  def test_churn_and_files_match_the_cli
    d = File.join(@root, "c")
    git!(@root, "init", "-q", "-b", "main", d)
    s1 = commit(d, "app/a.rb", "1\n2\n3\n")
    File.write(File.join(d, "bin.dat"), "\x00\x01\x02" * 10)
    s2 = commit(d, "app/a.rb", "1\n")
    git!(d, "mv", "app/a.rb", "app/moved.rb")
    s3 = commit(d, "README.md", "r\n")
    git!(d, "checkout", "-q", "-b", "side", s1)
    s4 = commit(d, "side.txt", "s\n")
    git!(d, "checkout", "-q", "main")
    git!(d, "merge", "-q", "--no-edit", "side")
    merge = git!(d, "rev-parse", "HEAD")
    shas = [s1, s2, s3, s4, merge]
    out = git!(d, "show", "--no-walk=unsorted", "--numstat", "--format=", "--no-renames", *shas)
    want = out.lines.map { |l| l.chomp.split("\t", 3) }.map { |a, dl, f| [f, a.to_i, dl.to_i] }.sort
    got = read("churn", d, shas: shas)["files"].map { |f, a, dl| [f, a, dl] }.sort
    assert_equal want, got
    assert_includes(read("churn", d, shas: [s2])["files"], ["bin.dat", 0, 0, true, false])

    refs = %w[side main HEAD]
    files = %w[side.txt app/moved.rb app/a.rb README.md app nope.txt]
    want = files.each_with_object({}) do |f, h|
      r = refs.find { |x| git(d, "cat-file", "-e", "#{x}:#{f}").last.nil? }
      h[f] = r if r
    end
    assert_equal want, read("files_at", d, refs: refs, files: files)["found"]
    # a remote-tracking branch answers by its name without the remote
    git!(d, "update-ref", "refs/remotes/origin/only-remote", s4)
    assert_equal({ "side.txt" => "only-remote" }, read("files_at", d, refs: ["only-remote"], files: ["side.txt"])["found"])
  end
end
