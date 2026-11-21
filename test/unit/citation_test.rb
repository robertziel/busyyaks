# frozen_string_literal: true

require "test_helper"
require "yaml"
require "date"

# CITATION.cff names the newest release in CHANGELOG.md: its version and its date. A release bumps both.
class CitationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def citation = YAML.safe_load_file(File.join(ROOT, "CITATION.cff"), permitted_classes: [Date])

  def newest_release
    line = File.foreach(File.join(ROOT, "CHANGELOG.md")).find { |l| l.match?(/\A## \[\d/) }
    refute_nil line, "CHANGELOG.md has no released version"
    m = line.match(/\A## \[(?<version>[^\]]+)\] - (?<date>\d{4}-\d{2}-\d{2})\s*\z/)
    refute_nil m, "unparsable release line: #{line.inspect}"
    m
  end

  def test_version_and_date_are_the_newest_release
    release = newest_release
    assert_equal release[:version], citation["version"]
    assert_equal Date.iso8601(release[:date]), citation["date-released"]
  end

  def test_names_the_public_repo_and_license
    assert_equal "1.2.0", citation["cff-version"]
    assert_equal "https://github.com/robertziel/busyyaks", citation["repository-code"]
    assert_equal "Apache-2.0", citation["license"]
    refute(citation["authors"].any? { |a| a.key?("email") }, "no email in CITATION.cff")
  end
end
