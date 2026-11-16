# frozen_string_literal: true

# CI `audit` stage: the libgit2 the image builds (Dockerfile ARG LIBGIT2_VERSION — the only code that reads a scanned
# repo) against libgit2's own releases. ruby-advisory-db does not track libgit2, so this is that check: a NEWER release
# on the same major.minor whose notes say it is a security release fails the build — fixed by bumping the ARG (and its
# checksum), never by an allowlist. A release list GitHub does not give (network, rate limit) fails too: unknown is not
# clean.
#
# GitHub API: authenticated only — CI_GITHUB_READ_TOKEN (env, required; a read-only token: Jenkins binds a
# credential, GitHub Actions its own GITHUB_TOKEN, an agent's local run its own) — an anonymous request shares one IP's
# 60/h with every build on the host. Each page is asked conditionally (If-None-Match with the ETag kept in the cache dir):
# an unchanged page answers 304, which costs no rate limit. Pages are read only until the pinned release is on one (the
# list is newest first, so every newer release of its minor is before it): one page, normally. A 403/429 says
# "rate limited, resets HH:MM UTC" and fails.
# Usage: ruby scripts/ci/libgit2-audit.rb <Dockerfile> <cache dir>
require "json"
require "net/http"
require "uri"
require "digest"
require "fileutils"

module Libgit2Audit
  Failed = Class.new(StandardError)
  PAGES = 3 # 300 releases: the pinned one is far newer than that
  URL = "https://api.github.com/repos/libgit2/libgit2/releases?per_page=100&page=%d"

  module_function

  # GET with the token and the page's kept ETag → [status, body, etag, reset epoch]
  def http_get(url, token, etag)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/vnd.github+json"
    req["User-Agent"] = "busyyaks-ci"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["Authorization"] = "Bearer #{token}"
    req["If-None-Match"] = etag if etag
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) { _1.request(req) }
    [res.code.to_i, res.body.to_s, res["ETag"], res["X-RateLimit-Reset"]&.to_i]
  end

  # a kept page: {"etag" => String, "releases" => Array}; anything else is a corrupt cache entry, named, never trusted
  def kept_page(file)
    kept = JSON.parse(File.read(file))
    return kept if kept.is_a?(Hash) && kept["etag"].is_a?(String) && kept["releases"].is_a?(Array)

    raise Failed, "the cache entry #{file} is not a kept page (etag + releases) — delete it"
  rescue JSON::ParserError => e
    raise Failed, "the cache entry #{file} is not JSON (#{e.message.lines.first.strip}) — delete it"
  end

  # one page of releases: the cached copy on 304, the new one (and its ETag) on 200
  def page(n, token:, cache:, get:)
    url = format(URL, n)
    file = File.join(cache, "#{Digest::SHA256.hexdigest(url)[0, 16]}.json")
    kept = File.exist?(file) ? kept_page(file) : nil
    status, body, etag, reset = get.call(url, token, kept&.fetch("etag"))
    case status
    when 304
      raise Failed, "GitHub answered 304 for #{url} with no kept page" unless kept

      kept.fetch("releases")
    when 200
      releases = JSON.parse(body)
      raise Failed, "GitHub's answer for #{url} is not a release list" unless releases.is_a?(Array)

      FileUtils.mkdir_p(cache)
      if etag
        File.write("#{file}.tmp", JSON.generate("etag" => etag, "releases" => releases))
        File.rename("#{file}.tmp", file)
      end
      releases
    when 403, 429
      at = reset ? Time.at(reset).utc.strftime("%H:%M UTC") : "unknown (no X-RateLimit-Reset)"
      raise Failed, "GitHub rate limited the release list (HTTP #{status}), resets #{at} — the audit is unknown"
    when 401 then raise Failed, "GitHub refused CI_GITHUB_READ_TOKEN (HTTP 401) — check the token"
    else raise Failed, "GitHub answered #{status} for #{url} — the release list is unknown, so is the audit"
    end
  end

  def run(dockerfile:, cache:, token:, get: method(:http_get))
    raise Failed, "CI_GITHUB_READ_TOKEN is not set — a read-only GitHub token; no anonymous request" if token.to_s.empty?

    pinned = File.read(dockerfile)[/^ARG LIBGIT2_VERSION=(\d+\.\d+\.\d+)$/, 1] or
      raise Failed, "no ARG LIBGIT2_VERSION in #{dockerfile}"
    major, minor, patch = pinned.split(".").map(&:to_i)
    releases = []
    found = (1..PAGES).any? do |n|
      releases.concat(page(n, token: token, cache: cache, get: get))
      releases.any? { _1["tag_name"] == "v#{pinned}" }
    end
    raise Failed, "v#{pinned} is not a libgit2 release (not in the newest #{PAGES * 100})" unless found

    newer = releases.filter_map do |r|
      m = r["tag_name"].to_s.match(/\Av(\d+)\.(\d+)\.(\d+)\z/) or next
      next if r["prerelease"] || r["draft"]
      next unless m[1].to_i == major && m[2].to_i == minor && m[3].to_i > patch

      [r["tag_name"], r["body"].to_s.match?(/security|CVE-\d/i)]
    end
    security = newer.select(&:last).map(&:first)
    unless security.empty?
      raise Failed, "the image builds libgit2 #{pinned}; security release(s) #{security.sort.join(', ')} exist — " \
                    "bump Dockerfile ARG LIBGIT2_VERSION + LIBGIT2_SHA256"
    end
    "#{pinned} — no newer #{major}.#{minor}.x security release " \
      "(#{newer.empty? ? 'none newer' : "newer, not security: #{newer.map(&:first).join(', ')}"})"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts "libgit2-audit: #{Libgit2Audit.run(dockerfile: ARGV.fetch(0), cache: ARGV.fetch(1),
                                            token: ENV.fetch('CI_GITHUB_READ_TOKEN', nil))}"
  rescue Libgit2Audit::Failed => e
    abort "libgit2-audit: #{e.message}"
  end
end
