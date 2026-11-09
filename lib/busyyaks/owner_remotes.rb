# frozen_string_literal: true

module Busyyaks
  # config/busyyaks.yml owner_remotes: which origins are the operator's. One rule for every reader — Config (validation)
  # and the scanner (a project's `own` flag, display only). Folder trust never reads it (LaunchTrust: trusted_paths
  # + launcher-made repos). Pure Ruby, no gems.
  module OwnerRemotes
    class Invalid < StandardError; end

    # RFC 3986 userinfo characters only: `?`, `#` or `\` end the authority for curl / git, so a "userinfo" holding one
    # (https://evil.example?@github.com/…) names another host than the one this would read
    USERINFO = "[A-Za-z0-9._~%!$&'()*+,;=:-]*"
    HOST = "[A-Za-z0-9._~-]+"

    module_function

    # a non-empty list of non-empty (not blank) strings, each one that can match: a host and at least one path segment
    # ("github.com/you/", "github.com:you/"), no empty / . / .. segment, no % — an old substring-style entry
    # ("your-user/", ".") would otherwise silently own nothing
    def validate!(value)
      ok = value.is_a?(Array) && !value.empty? && value.all? { |s| s.is_a?(String) && !s.strip.empty? }
      raise Invalid, "owner_remotes must be a non-empty list of non-empty strings (got #{value.inspect})" unless ok

      bad = value.filter_map { |e| (why = unmatchable(e)) && "#{e.inspect} #{why}" }
      if bad.any?
        raise Invalid, "owner_remotes: #{bad.join('; ')} — write host/owner prefixes (\"github.com/you/\", " \
                       "\"github.com:you/\")"
      end

      value
    end

    def matchable?(entry) = unmatchable(entry).nil?

    # nil = the entry can match a remote, else why it never can
    def unmatchable(entry)
      return "holds ? or [ (a URL query or a pattern, never part of a remote's host/owner)" if entry.match?(/[?\[]/)

      key = owner_key(entry).delete_suffix("/")
      segs = key.split("/", -1)
      return "names no host + owner (it needs host/owner)" if segs.size < 2
      return "holds % (an encoded character)" if key.include?("%")
      if segs.any? { |x| x.empty? || x == "." || x == ".." }
        return "has an empty, . or .. segment (e.g. a leading // or a path)"
      end

      nil
    end

    # A remote URL → "host/path" (host lower-cased, userinfo / port / scheme dropped). Only https://[u@]h[:port]/p,
    # ssh://[u@]h[:port]/p and the scp form user@h:p — any other scheme (file://, git://, ext::, http://) is never
    # owned. nil also for a path with an empty, `.` or `..` segment or any `%` (an encoded one): a fetch normalises
    # those (github.com/me/../evil/x fetches evil/x).
    def remote_key(url)
      u = url.to_s.strip
      m = u.match(%r{\A(?:https|ssh)://(?:#{USERINFO}@)?(#{HOST})(?::\d*)?/(.+)\z}io) ||
          u.match(%r{\A[A-Za-z0-9._-]+@(#{HOST}):(?!//)(.+)\z}o)
      return nil unless m
      return nil if m[2].include?("%") || m[2].split("/", -1).each_with_index.any? { |s, i| bad_segment?(s, i, m[2]) }

      "#{m[1].downcase}/#{m[2]}"
    end

    # empty (a//b, a leading /), `.` or `..`; a trailing / is allowed
    def bad_segment?(seg, index, path)
      return false if seg.empty? && index == path.count("/") && index.positive? # the trailing /

      seg.empty? || seg == "." || seg == ".."
    end

    # an owner_remotes entry ("github.com/me/", "github.com:me/", or a full URL) → the same "host/path" prefix
    def owner_key(entry)
      e = entry.to_s.strip
      remote_key(e) || e.sub(%r{\A([^/:]+)[:/]}) { "#{Regexp.last_match(1).downcase}/" }
    end

    # Its host/path starts with an entry on a segment boundary: "github.com/me/" owns github.com/me/x, never
    # github.com/me-evil/x, evil.example/github.com/me/x or github.com/me/../evil/x.
    def owned?(origin, owner_remotes)
      key = remote_key(origin) or return false
      owner_remotes.any? do |entry|
        pre = owner_key(entry).delete_suffix("/")
        key == pre || key.start_with?("#{pre}/")
      end
    end
  end
end
