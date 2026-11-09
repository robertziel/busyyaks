# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "minitest/mock"

# daily_facts' churn: computed from the repo (a GitRead child, libgit2), so the report model never adds lines up.
class McpChurnTest < Minitest::Test
  def server = Busyyaks::McpServer.new(token: "x" * 32, report_token: "r" * 32, scan_interval: 60, store: Object.new,
                                       config: nil)

  def git(dir, *a) = Open3.capture2("git", "-C", dir, *a).first.strip

  def test_sums_exactly_the_given_commits
    Dir.mktmpdir do |d|
      git(d, "init", "-q")
      git(d, "config", "user.email", "t@example.com")
      git(d, "config", "user.name", "t")
      FileUtils.mkdir_p("#{d}/app")
      File.write("#{d}/app/a.rb", "1\n2\n3\n")
      File.write("#{d}/README.md", "x\n")
      git(d, "add", ".")
      git(d, "commit", "-qm", "one")
      s1 = git(d, "rev-parse", "HEAD")
      File.write("#{d}/app/a.rb", "1\n")
      git(d, "commit", "-qam", "two")
      s2 = git(d, "rev-parse", "HEAD")
      root = File.dirname(File.realpath(d))
      c = server.send(:churn, d, [s1, s2], root: root)
      assert_equal({ files: 2, add: 4, del: 2, top: ["app/", "README.md"], binary: 0 }, c.except(:commits))
      assert_equal [{ sha: s1[0, 9], paths: ["README.md", "app/a.rb"], more: 0 },
                    { sha: s2[0, 9], paths: ["app/a.rb"], more: 0 },],
                   c[:commits], "9-char shas, the same as daily_facts subjects"
      assert_equal 1, server.send(:churn, d, [s2], root: root)[:files]
    end
  end

  # the paths a commit touched, for the daily report's flags (db/migrate/…, a removed route): the first
  # CHURN_PATHS_MAX, then a count — read over MCP, so the report never runs git on the host
  def test_per_commit_paths_are_capped_with_a_count
    Dir.mktmpdir do |d|
      git(d, "init", "-q")
      git(d, "config", "user.email", "t@example.com")
      git(d, "config", "user.name", "t")
      n = Busyyaks::McpServer::CHURN_PATHS_MAX + 3
      n.times { |i| File.write(format("#{d}/f%02d", i), "x\n") }
      git(d, "add", ".")
      git(d, "commit", "-qm", "many")
      c = server.send(:churn, d, [git(d, "rev-parse", "HEAD")], root: File.dirname(File.realpath(d)))[:commits].first
      assert_equal [Busyyaks::McpServer::CHURN_PATHS_MAX, 3], [c[:paths].size, c[:more]]
    end
  end

  # a repo's own config cannot make churn run a program: textconv / external diff drivers are never used
  def test_repo_configured_diff_programs_never_run
    Dir.mktmpdir do |d|
      git(d, "init", "-q")
      git(d, "config", "user.email", "t@example.com")
      git(d, "config", "user.name", "t")
      git(d, "config", "diff.evil.textconv", "touch #{d}/ran-textconv; cat")
      git(d, "config", "diff.external", "touch #{d}/ran-external")
      File.write("#{d}/.gitattributes", "* diff=evil\n")
      File.write("#{d}/a.txt", "1\n")
      git(d, "add", ".")
      git(d, "commit", "-qm", "one")
      c = server.send(:churn, d, [git(d, "rev-parse", "HEAD")], root: File.dirname(File.realpath(d)))
      assert_equal 2, c[:files]
      refute_path_exists "#{d}/ran-textconv"
      refute_path_exists "#{d}/ran-external"
    end
  end

  def test_git_failure_is_an_error_never_a_number
    c = server.send(:churn, "/nonexistent-repo", ["d" * 40], root: "/")
    assert_match(/nonexistent-repo/, c[:error])
    refute c.key?(:add)
    # a commit id is 40 hex digits, looked up as an object — never a revision expression
    Dir.mktmpdir do |d|
      git(d, "init", "-q")
      %w[HEAD HEAD~1 :/fix deadbeef].each do |rev|
        assert_match(/not a 40-hex commit id/, server.send(:churn, d, [rev], root: File.dirname(File.realpath(d)))[:error], rev)
      end
    end
  end
end
