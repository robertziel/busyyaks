# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "busyyaks/kanban"

# The web's and the notifier's views of a checkout, with no git in their process: GitPort (the card links) answers
# from the scanner's stored read and asks a GitRead child only for files, once per scan; SessionGit (the idle watch)
# reads the listed project a session works in, the launcher naming only the dir.
class GitPortTest < Minitest::Test
  include DBReset

  ENV_GIT = { "GIT_AUTHOR_NAME" => "a", "GIT_AUTHOR_EMAIL" => "a@x.io", "GIT_COMMITTER_NAME" => "a",
              "GIT_COMMITTER_EMAIL" => "a@x.io", "GIT_CONFIG_GLOBAL" => "/dev/null", }.freeze

  def setup
    super
    @root = File.realpath(Dir.mktmpdir("port"))
    @dir = File.join(@root, "r")
    Dir.mkdir(@dir)
    git("init", "-q", "-b", "main")
    File.write(File.join(@dir, "a.md"), "a\n")
    git("add", ".")
    git("commit", "-q", "-m", "a")
    @mount = ENV.fetch("PROJECTS_MOUNT")
    ENV["PROJECTS_MOUNT"] = @root
  end

  def teardown
    ENV["PROJECTS_MOUNT"] = @mount
    FileUtils.rm_rf(@root)
    super
  end

  def git(*a) = system(ENV_GIT, "git", "-C", @dir, *a, exception: true)

  def project(**over)
    { slug: "r", path: @dir, branches: JSON.generate(%w[main]), default_ref: "main", scanned_at: 1 }.merge(over)
  end

  def test_branches_and_default_ref_are_the_scanners_read
    port = Busyyaks::GitPort.new(root: @root)
    assert_equal Set["main"], port.branches(project)
    assert_equal "main", port.default_ref(project)
    e = assert_raises(Busyyaks::GitPort::Unavailable) { port.branches(project(branches: nil)) }
    assert_equal "r has not been read by the scanner yet", e.message
    assert_raises(Busyyaks::GitPort::Unavailable) { port.default_ref(project(default_ref: nil)) }
  end

  # files_at: one child per question, the answer kept until the repo is scanned again; a failed read is Unavailable
  def test_files_are_asked_once_per_scan
    port = Busyyaks::GitPort.new(root: @root)
    assert_equal({ "a.md" => "HEAD" }, port.files_at(project, %w[HEAD], %w[a.md b.md]))
    git("config", "core.worktree", @root) # the next real read is refused
    assert_equal({ "a.md" => "HEAD" }, port.files_at(project, %w[HEAD], %w[a.md b.md]), "the same scan: kept")
    e = assert_raises(Busyyaks::GitPort::Unavailable) { port.files_at(project(scanned_at: 2), %w[HEAD], %w[a.md]) }
    assert_match(/core\.worktree is set/, e.message)
  end

  FakeLauncher = Struct.new(:answer) do
    def git(session:, socket:) = answer.call(session, socket)
  end

  def test_session_git_reads_the_listed_project_the_session_works_in
    store.upsert_project(slug: "r", path: @dir, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    sub = File.join(@dir, "lib")
    Dir.mkdir(sub)
    launcher = FakeLauncher.new(->(s, _) { { "ok" => true, "path" => s == "deep" ? "r/lib" : s } })
    head = Busyyaks::SessionGit.git(session: "deep", socket: "default", launcher: launcher)
    assert_equal "main", head["branch"]
    assert_kind_of Integer, head["last_commit_at"]
    un = Busyyaks::SessionGit::Unavailable
    assert_match(/no listed project/, assert_raises(un) {
 Busyyaks::SessionGit.git(session: "elsewhere", socket: "x", launcher: launcher) }.message)
    assert_match(/named no dir/, assert_raises(un) {
 Busyyaks::SessionGit.git(session: "../r", socket: "x", launcher: launcher) }.message)
    git("config", "core.sparseCheckout", "true")
    assert_match(/sparse checkout/, assert_raises(un) {
 Busyyaks::SessionGit.git(session: "r", socket: "x", launcher: launcher) }.message)
  end
end
