# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../scripts/ci/libgit2-audit"

# scripts/ci/libgit2-audit.rb against a stubbed GitHub (no live API): a token on every request, a kept ETag
# asked again (304 = the kept page), only the pages up to the pinned release, a rate limit that says when it resets.
class Libgit2AuditTest < Minitest::Test
  A = Libgit2Audit
  TOKEN = "ghs_#{'r' * 36}".freeze

  def setup
    @dir = Dir.mktmpdir("libgit2-audit")
    @dockerfile = File.join(@dir, "Dockerfile")
    File.write(@dockerfile, "FROM x\nARG LIBGIT2_VERSION=1.9.1\n")
    @cache = File.join(@dir, "cache")
    @calls = []
  end

  def teardown = FileUtils.rm_rf(@dir)

  def rel(tag, body = "fixes", **opts) = { "tag_name" => tag, "body" => body }.merge(opts.transform_keys(&:to_s))

  # answers: page number → [status, releases (or nil), etag, reset]
  def get(answers)
    lambda do |url, token, etag|
      @calls << { page: url[/[?&]page=(\d+)/, 1].to_i, token: token, etag: etag }
      status, releases, new_etag, reset = answers.fetch(@calls.last[:page])
      [status, releases ? JSON.generate(releases) : "", new_etag, reset]
    end
  end

  def audit(answers) = A.run(dockerfile: @dockerfile, cache: @cache, token: TOKEN, get: get(answers))

  def test_no_token_no_request
    [nil, ""].each do |token|
      err = assert_raises(A::Failed) { A.run(dockerfile: @dockerfile, cache: @cache, token: token, get: get({})) }
      assert_match "CI_GITHUB_READ_TOKEN is not set — a read-only GitHub token; no anonymous request", err.message
    end
    assert_empty @calls
  end

  def test_one_page_when_the_pinned_release_is_on_it_and_the_token_on_the_request
    out = audit(1 => [200, [rel("v1.9.2", "bug fixes"), rel("v1.9.1"), rel("v1.8.4", "security")], '"e1"'])

    assert_equal "1.9.1 — no newer 1.9.x security release (newer, not security: v1.9.2)", out
    assert_equal [{ page: 1, token: TOKEN, etag: nil }], @calls
  end

  def test_an_unchanged_page_is_asked_with_its_etag_and_read_from_the_cache
    audit(1 => [200, [rel("v1.9.1")], '"e1"'])
    @calls.clear
    out = audit(1 => [304, nil, '"e1"'])

    assert_equal [{ page: 1, token: TOKEN, etag: '"e1"' }], @calls
    assert_match "no newer 1.9.x security release (none newer)", out
  end

  def test_a_304_with_no_kept_page_fails
    err = assert_raises(A::Failed) { audit(1 => [304, nil, nil]) }
    assert_match "304", err.message
  end

  def test_later_pages_only_until_the_pinned_release
    out = audit(1 => [200, [rel("v1.10.0"), rel("v1.9.3", "fixes CVE-2026-1")], '"a"'],
                2 => [200, [rel("v1.9.2"), rel("v1.9.1")], '"b"'])
    flunk "expected a failure: #{out}"
  rescue A::Failed => e
    assert_equal [1, 2], @calls.map { _1[:page] }
    assert_equal "the image builds libgit2 1.9.1; security release(s) v1.9.3 exist — bump Dockerfile ARG " \
                 "LIBGIT2_VERSION + LIBGIT2_SHA256", e.message
  end

  def test_a_pinned_version_that_is_no_release_fails_after_the_last_page
    err = assert_raises(A::Failed) { audit((1..3).to_h { [_1, [200, [rel("v2.0.#{_1}")], nil]] }) }
    assert_equal "v1.9.1 is not a libgit2 release (not in the newest 300)", err.message
    assert_equal [1, 2, 3], @calls.map { _1[:page] }
  end

  def test_a_rate_limit_says_when_it_resets_and_fails
    reset = Time.utc(2026, 11, 16, 0, 10).to_i
    [403, 429].each do |code|
      err = assert_raises(A::Failed) { audit(1 => [code, nil, nil, reset]) }
      assert_equal "GitHub rate limited the release list (HTTP #{code}), resets 00:10 UTC — the audit is unknown", err.message
    end
    err = assert_raises(A::Failed) { audit(1 => [403, nil, nil, nil]) }
    assert_match "resets unknown (no X-RateLimit-Reset)", err.message
  end

  def test_a_refused_token_or_another_answer_fails
    assert_match "refused CI_GITHUB_READ_TOKEN (HTTP 401)", assert_raises(A::Failed) { audit(1 => [401, nil, nil]) }.message
    assert_match "GitHub answered 500", assert_raises(A::Failed) { audit(1 => [500, nil, nil]) }.message
    assert_match "is not a release list", assert_raises(A::Failed) {
      A.run(dockerfile: @dockerfile, cache: @cache, token: TOKEN, get: ->(*) { [200, "{}", nil, nil] })
    }.message
  end

  # a corrupt cache entry fails, naming the file
  def test_a_corrupt_cache_entry_fails_naming_its_path
    audit(1 => [200, [rel("v1.9.1")], '"e1"'])
    file = Dir[File.join(@cache, "*.json")].first
    { "{not json" => "is not JSON", '{"releases": []}' => "is not a kept page (etag + releases)" }.each do |body, why|
      File.write(file, body)
      err = assert_raises(A::Failed) { audit(1 => [304, nil, '"e1"']) }
      assert err.message.start_with?("the cache entry #{file} #{why}"), err.message
      assert_match "delete it", err.message
    end
  end
end
