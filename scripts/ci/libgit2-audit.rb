# frozen_string_literal: true

# CI `audit` stage: the libgit2 the image builds (Dockerfile ARG LIBGIT2_VERSION — the only code that reads a scanned
# repo) against libgit2's own releases. ruby-advisory-db does not track libgit2, so this is that check: a NEWER release
# on the same major.minor whose notes say it is a security release fails the build — fixed by bumping the ARG (and its
# checksum), never by an allowlist. A release list GitHub does not give (network, rate limit) fails too: unknown is not
# clean. Usage: CI_GITHUB_READ_TOKEN=<token> ruby scripts/ci/libgit2-audit.rb <Dockerfile>
# Authenticated only: GitHub's anonymous limit is 60 requests/h per IP, shared by every build and agent on
# a CI host, so anonymous audits went red with 403 whenever builds overlapped. No token → refused, never anonymous.
require "json"
require "net/http"
require "uri"

dockerfile = ARGV.fetch(0)
pinned = File.read(dockerfile)[/^ARG LIBGIT2_VERSION=(\d+\.\d+\.\d+)$/,
1] or abort "libgit2-audit: no ARG LIBGIT2_VERSION in #{dockerfile}"
major, minor, patch = pinned.split(".").map(&:to_i)

token = ENV.fetch("CI_GITHUB_READ_TOKEN", "")
if token.strip.empty?
  abort "libgit2-audit: CI_GITHUB_READ_TOKEN is not set — the audit never asks GitHub anonymously " \
        "(60 requests/h per IP); give it a token that can read public repositories"
end
headers = { "Accept" => "application/vnd.github+json", "User-Agent" => "busyyaks-ci",
            "Authorization" => "Bearer #{token.strip}", }

releases = []
(1..3).each do |page|
  uri = URI("https://api.github.com/repos/libgit2/libgit2/releases?per_page=100&page=#{page}")
  res = Net::HTTP.get_response(uri, headers)
  unless res.is_a?(Net::HTTPSuccess)
    left = res["x-ratelimit-remaining"]
    reset = res["x-ratelimit-reset"]&.then { |t| Time.at(t.to_i).utc.strftime("%H:%M UTC") }
    why = left == "0" ? " (rate limited, resets #{reset})" : ""
    abort "libgit2-audit: GitHub answered #{res.code}#{why} for #{uri} — the release list is unknown, so is the audit"
  end

  batch = JSON.parse(res.body)
  releases.concat(batch)
  break if batch.size < 100
end
abort "libgit2-audit: v#{pinned} is not a libgit2 release" unless releases.any? { |r| r["tag_name"] == "v#{pinned}" }

newer = releases.filter_map do |r|
  m = r["tag_name"].to_s.match(/\Av(\d+)\.(\d+)\.(\d+)\z/) or next
  next if r["prerelease"] || r["draft"]
  next unless m[1].to_i == major && m[2].to_i == minor && m[3].to_i > patch

  [r["tag_name"], r["body"].to_s.match?(/security|CVE-\d/i)]
end
security = newer.select(&:last).map(&:first)
unless security.empty?
  abort "libgit2-audit: the image builds libgit2 #{pinned}; security release(s) #{security.sort.join(', ')} " \
        "exist — bump Dockerfile ARG LIBGIT2_VERSION + LIBGIT2_SHA256"
end
puts "libgit2-audit: #{pinned} — no newer #{major}.#{minor}.x security release " \
     "(#{newer.empty? ? 'none newer' : "newer, not security: #{newer.map(&:first).join(', ')}"})"
