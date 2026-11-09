# frozen_string_literal: true

# CI `audit` stage: the libgit2 the image builds (Dockerfile ARG LIBGIT2_VERSION — the only code that reads a scanned
# repo) against libgit2's own releases. ruby-advisory-db does not track libgit2, so this is that check: a NEWER release
# on the same major.minor whose notes say it is a security release fails the build — fixed by bumping the ARG (and its
# checksum), never by an allowlist. A release list GitHub does not give (network, rate limit) fails too: unknown is not
# clean. Usage: ruby scripts/ci/libgit2-audit.rb <Dockerfile>
require "json"
require "net/http"
require "uri"

dockerfile = ARGV.fetch(0)
pinned = File.read(dockerfile)[/^ARG LIBGIT2_VERSION=(\d+\.\d+\.\d+)$/,
1] or abort "libgit2-audit: no ARG LIBGIT2_VERSION in #{dockerfile}"
major, minor, patch = pinned.split(".").map(&:to_i)

releases = (1..3).flat_map do |page|
  uri = URI("https://api.github.com/repos/libgit2/libgit2/releases?per_page=100&page=#{page}")
  res = Net::HTTP.get_response(uri, { "Accept" => "application/vnd.github+json", "User-Agent" => "busyyaks-ci" })
  unless res.is_a?(Net::HTTPSuccess)
    abort "libgit2-audit: GitHub answered #{res.code} for #{uri} — the release list is unknown, so is the audit"
  end

  JSON.parse(res.body)
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
