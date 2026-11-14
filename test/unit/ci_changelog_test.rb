# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# scripts/ci/changelog, the pull-request gate: run in a throwaway git repo whose `base` branch holds a CHANGELOG.md and
# whose HEAD is the pull request on top of it.
class CiChangelogTest < Minitest::Test
  SCRIPT = File.expand_path("../../scripts/ci/changelog", __dir__)
  BASE = <<~MD
    # Changelog

    ## [Unreleased]

    ### Added

    - An earlier change.

    ## [1.0.0] - 2026-01-01

    ### Added

    - A released change
      that wraps (released sections are not this gate's business).
  MD

  def setup
    @dir = File.realpath(Dir.mktmpdir("ci-changelog"))
    git("init", "-q", "-b", "base")
    commit("CHANGELOG.md" => BASE)
    git("checkout", "-q", "-b", "pr")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def env
    { "GIT_AUTHOR_NAME" => "ci", "GIT_AUTHOR_EMAIL" => "ci@example.invalid", "GIT_COMMITTER_NAME" => "ci",
      "GIT_COMMITTER_EMAIL" => "ci@example.invalid", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_DIR" => nil,
      "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, }
  end

  def git(*args)
    out, status = Open3.capture2e(env, "git", *args, chdir: @dir)
    assert_predicate status, :success?, out
  end

  def commit(files)
    files.each { |rel, body| File.write(File.join(@dir, rel), body) }
    git("add", "-A")
    git("commit", "-q", "-m", "change")
  end

  def gate(base = "base") = Open3.capture3(env, SCRIPT, *base, chdir: @dir)

  def unreleased_with(line) = BASE.sub("- An earlier change.\n", "- An earlier change.\n#{line}")

  def test_a_line_added_under_unreleased_passes
    commit("CHANGELOG.md" => unreleased_with("- The new change.\n"))
    out, err, status = gate

    assert_predicate status, :success?, err
    assert_includes out, "line 8 added under Unreleased: - The new change."
  end

  def test_no_changelog_change_is_refused
    commit("other.txt" => "code\n")
    _out, err, status = gate

    assert_equal 1, status.exitstatus
    assert_includes err, "adds no line under '## [Unreleased]'"
  end

  def test_a_line_added_to_a_released_section_only_is_refused
    commit("CHANGELOG.md" => BASE.sub("- A released change\n", "- Sneaked into 1.0.0.\n- A released change\n"))
    _out, err, status = gate

    assert_equal 1, status.exitstatus
    assert_includes err, "adds no line under '## [Unreleased]'"
  end

  def test_a_wrapped_unreleased_entry_is_refused
    commit("CHANGELOG.md" => unreleased_with("- A long change\n  that wraps.\n"))
    _out, err, status = gate

    assert_equal 1, status.exitstatus
    assert_includes err, "every Unreleased entry is one line"
    assert_includes err, "9:   that wraps."
  end

  def test_a_removed_line_only_is_refused
    commit("CHANGELOG.md" => BASE.sub("- An earlier change.\n", ""))
    _out, err, status = gate

    assert_equal 1, status.exitstatus
    assert_includes err, "adds no line"
  end

  def test_no_unreleased_section_is_refused
    commit("CHANGELOG.md" => BASE.sub("## [Unreleased]", "## Next"))
    _out, err, status = gate

    assert_equal 1, status.exitstatus
    assert_includes err, "no '## [Unreleased]' section"
  end

  def test_a_base_not_in_the_checkout_is_refused_never_skipped
    _out, err, status = gate("origin/nowhere")

    assert_equal 2, status.exitstatus
    assert_includes err, "base origin/nowhere is not in this checkout"
  end

  def test_no_base_is_refused
    _out, err, status = gate([])

    assert_equal 2, status.exitstatus
    assert_includes err, "usage: scripts/ci/changelog <base ref>"
  end

  def test_only_the_pull_requests_own_commits_count
    # the base moves on after the PR was cut: its new Unreleased line is not the PR's
    git("checkout", "-q", "base")
    commit("CHANGELOG.md" => unreleased_with("- Landed on base meanwhile.\n"))
    git("checkout", "-q", "pr")
    commit("other.txt" => "code\n")
    _out, err, status = gate

    assert_equal 1, status.exitstatus
    assert_includes err, "adds no line"
  end

  def test_a_footer_link_reference_under_a_last_unreleased_section_passes
    only_unreleased = "# Changelog\n\n## [Unreleased]\n\n- One.\n\n[Unreleased]: https://example.invalid/commits/main\n"
    git("checkout", "-q", "base")
    commit("CHANGELOG.md" => only_unreleased)
    git("checkout", "-q", "-B", "pr")
    commit("CHANGELOG.md" => only_unreleased.sub("- One.\n", "- One.\n- Two.\n"))
    out, err, status = gate

    assert_predicate status, :success?, err
    assert_includes out, "line 6 added under Unreleased: - Two."
  end

  def test_an_edit_above_unreleased_and_a_bullet_inside_it_are_two_hunks_read_right
    commit("CHANGELOG.md" => unreleased_with("- The new change.\n").sub("# Changelog\n", "# Changelog\n\nIntro.\n"))
    out, err, status = gate

    assert_predicate status, :success?, err
    assert_includes out, "line 10 added under Unreleased: - The new change."
  end
end
