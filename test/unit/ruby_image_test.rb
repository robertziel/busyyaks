# frozen_string_literal: true

require "test_helper"

# Every image busyyaks builds runs ONE exact Ruby: a floating tag (ruby:3.4-slim) reuses whatever a cached image
# holds — this host's was 3.4.12, open to the 2026-11-18 Regexp / String advisory fixed in 3.4.13. The tag names a
# patch release, every Dockerfile names the same one, and the test process runs it (the test image is the app's).
class RubyImageTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  # every Dockerfile of this repo; not vendor/ (the kanban engine's own CI image, pinned in the engine repo and
  # re-vendored, never edited here) nor node_modules / build output (not this repo's code)
  DOCKERFILES = Dir.glob("**/Dockerfile*", base: ROOT)
                   .reject { _1.start_with?("vendor/", "node_modules/", "frontend/node_modules/", "public/app/") }.sort.freeze
  # the prose that names the image; `ruby:` there is either the pin or the CI host stage's floor (HOST_RUBY_IMAGE)
  # (CLAUDE.md names it too, but is mirror-only: .publish-ignore)
  DOCS = %w[README.md docs/LINT.md].freeze
  # the oldest 3.4 release with the 2026-11-18 advisory's fixes (GHSA-34m4-m9fh-gqp5 and the six beside it)
  FIXED = "3.4.13"

  def ruby_froms(path)
    File.read(File.join(ROOT, path)).scan(/^FROM ruby:(\S+)/).flatten
  end

  def test_every_dockerfile_pins_an_exact_patched_ruby
    DOCKERFILES.each do |path|
      tags = ruby_froms(path)
      refute_empty tags, "#{path}: no FROM ruby: line"
      tags.each do |tag|
        version = tag[/\A(\d+\.\d+\.\d+)-slim\z/, 1]
        assert version, "#{path}: ruby:#{tag} is not an exact patch release (x.y.z-slim)"
        assert_operator Gem::Version.new(version), :>=, Gem::Version.new(FIXED), "#{path}: ruby:#{tag} predates #{FIXED}"
      end
    end
  end

  def test_every_dockerfile_names_the_same_ruby
    tags = DOCKERFILES.flat_map { ruby_froms(_1) }.uniq
    assert_equal 1, tags.size, "Dockerfiles disagree on the Ruby image: #{tags.join(' ')}"
  end

  def test_the_known_dockerfiles_are_found
    assert_equal %w[Dockerfile scripts/harness-lab/Dockerfile scripts/hooks/Dockerfile scripts/lint/Dockerfile], DOCKERFILES
  end

  def test_the_docs_name_the_pinned_image
    pin = ruby_froms("Dockerfile").first
    host = File.read(File.join(ROOT, "scripts/ci/test.sh"))[/^HOST_RUBY_IMAGE=ruby:(\S+)/, 1]
    DOCS.each do |path|
      named = File.read(File.join(ROOT, path)).scan(/`ruby:([^`\s]+)`/).flatten.uniq
      assert_empty named - [pin, host], "#{path} names a Ruby image other than ruby:#{pin} / ruby:#{host}"
    end
    DOCS.each { assert_includes File.read(File.join(ROOT, _1)), "`ruby:#{pin}`", _1 }
  end

  def test_the_suite_runs_the_pinned_ruby
    tag = ruby_froms("Dockerfile").first
    assert_equal tag.delete_suffix("-slim"), RUBY_VERSION
  end
end
