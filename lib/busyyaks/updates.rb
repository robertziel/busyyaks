# frozen_string_literal: true

require "json"
require "fileutils"
require "rubygems"
require "yaml"

module Busyyaks
  # Updating this checkout (card 536): what is newer on its git remote, and moving the checkout onto it. Pure Ruby
  # stdlib — bin/yaks (`yaks update`) and bin/launcher (Settings → Updates) both load it; the services only validate
  # the config (Config). Every git call goes through a `git` callable (args → [stdout, stderr, ok]) the caller hands in,
  # so the host program decides how it spawns and the tests answer from a real throwaway repo.
  #
  # config/busyyaks.yml `updates` (required, no default):
  #   remote:        the git remote of this checkout the updates come from (e.g. origin)
  #   branch:        the branch `yaks update --main` follows on that remote
  #   tags:          the release tags' glob, one `*` (e.g. "v*"): the part the `*` matches must be a version
  #   channel:       tags | branch — which of the two the dashboard's "update available" counts
  #   check_minutes: 1..10080 — how old the launcher's last check may be before the dashboard asks again
  #
  # An update is only ever a FAST-FORWARD of a CLEAN tracked tree: a checkout with local commits the target lacks, or
  # with tracked changes, is refused naming them — never reset, never stashed.
  module Updates
    class Invalid < StandardError; end
    class Refused < StandardError; end

    KEYS = %w[branch channel check_minutes remote tags].freeze
    CHANNELS = %w[tags branch].freeze
    MODES = %w[tags branch].freeze
    NAME = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}
    GLOB = /\A[A-Za-z0-9._-]*\*[A-Za-z0-9._-]*\z/
    SHA = /\A\h{40}\z/
    # the longest one git call of a check or an update may take (a fetch over a slow link included): past it the call
    # is killed and the check / update fails naming it — never a lock held, nor a record left "running", forever
    GIT_TIMEOUT_S = 120
    # Hardening of every update git call (the git CLI runs on busyyaks's OWN checkout only, never on another repo).
    # Command-scope config (GIT_CONFIG_COUNT: = `-c`, and the argv stays the subcommand's)
    # beats the repo's own for the programs git would run from config: no fsmonitor, no hooks, no ext:: transport, ssh
    # as is, no credential helper / askpass / proxy program, no submodule recursion. The system and global config are
    # not read (a private remote goes over ssh, as the clone rule says). What `-c` cannot reset (multi-valued or
    # per-name keys) is refused by preflight!. git never asks on a terminal nobody watches: it fails at once instead.
    GIT_CONFIG = {
      "core.fsmonitor" => "false", "core.hooksPath" => "/dev/null", "protocol.ext.allow" => "never",
      "core.sshCommand" => "ssh", "credential.helper" => "", "core.askPass" => "", "core.pager" => "cat",
      "fetch.recurseSubmodules" => "false", "submodule.recurse" => "false",
      "merge.verifySignatures" => "false", "gpg.program" => "false", "gpg.ssh.program" => "false",
      "gpg.x509.program" => "false",
    }.freeze
    GIT_ENV = {
      "GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_ASKPASS" => nil, "SSH_ASKPASS" => nil, "GIT_SSH" => nil, "GIT_SSH_COMMAND" => nil, "GIT_EDITOR" => "false",
      "GIT_CONFIG_COUNT" => GIT_CONFIG.size.to_s,
      **GIT_CONFIG.each_with_index.each_with_object({}) do |((k, v), i), h|
        h["GIT_CONFIG_KEY_#{i}"] = k
        h["GIT_CONFIG_VALUE_#{i}"] = v
      end,
    }.freeze
    # repo-config keys that make git run a program, follow another file or rewrite where it fetches from, and that a
    # command-scope value cannot switch off → the check refuses, naming the key (git config --local, includes not read)
    REFUSED_CONFIG = [
      /\Afilter\./i, /\Aurl\./i, /\Ainclude\./i, /\Aincludeif\./i, /\Acredential\..+\.helper\z/i,
      /\Aremote\..+\.(uploadpack|receivepack|vcs|proxy)\z/i, /\Ahttp\.(.+\.)?proxy\z/i, /\Acore\.gitproxy\z/i,
      /\Acore\.worktree\z/i, /\Agpg\./i,
    ].freeze

    Settings = Data.define(:remote, :branch, :tags, :channel, :check_minutes) do
      def check_seconds = check_minutes * 60
      def tag_prefix = tags.split("*", 2).first
      def tag_suffix = tags.split("*", 2).last.to_s

      # the version in a tag name that matches the glob, or nil (not a version)
      def version_of(tag)
        return nil unless tag.start_with?(tag_prefix) && tag.end_with?(tag_suffix)

        raw = tag[tag_prefix.size...(tag.size - tag_suffix.size)]
        Gem::Version.correct?(raw) && raw.match?(/\A\d/) ? Gem::Version.new(raw) : nil
      end
    end

    module_function

    def parse!(value)
      unless value.is_a?(Hash) && value.keys.sort == KEYS
        raise Invalid, "updates must be a mapping with exactly #{KEYS.sort.join(', ')} (config/busyyaks.example.yml)"
      end

      %w[remote branch].each do |k|
        v = value[k]
        unless v.is_a?(String) && v.match?(NAME) && !v.include?("..") && !v.end_with?("/", ".lock")
          raise Invalid, "updates.#{k} must be a git #{k} name (got #{v.inspect})"
        end
      end
      unless value["tags"].is_a?(String) && value["tags"].match?(GLOB)
        raise Invalid, "updates.tags must be a tag glob with exactly one * (e.g. \"v*\"; got #{value['tags'].inspect})"
      end
      unless CHANNELS.include?(value["channel"])
        raise Invalid, "updates.channel must be one of #{CHANNELS.join(', ')} (got #{value['channel'].inspect})"
      end
      min = value["check_minutes"]
      unless min.is_a?(Integer) && min.between?(1, 10_080)
        raise Invalid, "updates.check_minutes must be an integer 1..10080 (got #{min.inspect})"
      end

      Settings.new(remote: value["remote"], branch: value["branch"], tags: value["tags"], channel: value["channel"],
                   check_minutes: min)
    end

    # config/busyyaks.yml of a checkout → Settings (Invalid naming the file)
    def load!(home)
      file = File.join(home, "config", "busyyaks.yml")
      doc = YAML.safe_load_file(file)
      raise Invalid, "#{file}: no updates key (config/busyyaks.example.yml)" unless doc.is_a?(Hash) && doc.key?("updates")

      parse!(doc["updates"])
    rescue Errno::ENOENT
      raise Invalid, "no config/busyyaks.yml at #{file}"
    rescue Psych::Exception, SystemCallError => e
      raise Invalid, "#{file}: #{e.message}"
    end

    # git through the caller's runner: stdout stripped, a failure → Refused with git's own words (any URL's userinfo
    # dropped: a token in an https remote is never stored nor shown)
    def git!(git, *args)
      out, err, ok = git.call(args)
      return out.to_s.strip if ok

      said = (err.to_s.strip.empty? ? out : err).to_s.lines.map(&:strip).reject(&:empty?).last(3).join(" · ")
      raise Refused, without_userinfo("git #{args.first(2).join(' ')}: #{said.empty? ? 'failed, saying nothing' : said}")
    end

    # every `scheme://user[:secret]@` in the text → `scheme://`; an scp-like `git@host:path` has no secret and stays
    def without_userinfo(text) = text.gsub(%r{(\b[A-Za-z][A-Za-z0-9+.-]*://)[^@/\s]*@}, '\1')

    def ok?(git, *args) = git.call(args)[2]

    # Fetches the remote's branch and release tags (a local tag that differs from the remote's is refused by git —
    # never clobbered), then compares. → the check, a plain JSON-able Hash:
    #   head:   {sha, branch (nil = detached), describe}
    #   dirty:  tracked paths with changes (an update refuses while any)
    #   tag:    {name, sha, version, state, behind} | {state: "none"}   — the newest version tag
    #   branch: {name, sha, state, behind}                               — <remote>/<branch>
    #   ignored_tags: tags matching the glob whose middle is not a version (listed, never read as one)
    #   channel, available (the channel's target is a fast-forward away), remote, checked_at
    # state: current (HEAD is it) · available (a fast-forward) · ahead (HEAD already contains it) · diverged
    def check(settings, git:, now:)
      preflight!(git)
      url = without_userinfo(git!(git, "ls-remote", "--get-url", settings.remote))
      git!(git, "fetch", "--no-tags", settings.remote,
           "+refs/heads/#{settings.branch}:refs/remotes/#{settings.remote}/#{settings.branch}",
           "refs/tags/#{settings.tags}:refs/tags/#{settings.tags}")
      head = git!(git, "rev-parse", "HEAD")
      branch_name = git.call(%w[symbolic-ref --short -q HEAD]).then { |out, _, ok| ok ? out.strip : nil }
      describe = git.call(["describe", "--tags", "--match", settings.tags, "--always", "HEAD"]).first.to_s.strip
      versions, ignored = tags(settings, git)
      newest = versions.max_by { |t| t[:version] }
      tag = if newest
              { name: newest[:name], sha: newest[:sha], version: newest[:version].to_s,
                **relation(git, head, newest[:sha]), }
            else
              { state: "none" }
            end
      tip = git!(git, "rev-parse", "refs/remotes/#{settings.remote}/#{settings.branch}^{commit}")
      target = { name: settings.branch, sha: tip, **relation(git, head, tip) }
      chosen = settings.channel == "tags" ? tag : target
      { remote: settings.remote, url: url, channel: settings.channel, checked_at: now.iso8601,
        head: { sha: head, branch: branch_name, describe: describe }, dirty: dirty(git),
        tag: tag, branch: target, ignored_tags: ignored, available: chosen[:state] == "available", }
    end

    # the checkout's own .git/config, read (`git config` runs nothing) → Refused naming every key REFUSED_CONFIG
    # matches; the operator removes it (`git config --unset …`) and checks again — never skipped
    def preflight!(git)
      out = git!(git, "config", "--local", "--no-includes", "--null", "--list")
      keys = out.split("\0").map { |e| e.split("\n", 2).first }
      bad = keys.select { |k| REFUSED_CONFIG.any? { |re| re.match?(k) } }.uniq
      return if bad.empty?

      raise Refused, "the checkout's .git/config sets #{bad.join(', ')}: a program or a fetch rewrite an update " \
                     "would follow — remove it (git config --unset) and check again"
    end

    # the REMOTE's tags matching the glob (`git ls-remote`: a release deleted there is never offered, and no local tag
    # is pruned) → [[{name, sha (the commit: an annotated tag's peeled ^{}), version}], [names that are not a version]]
    def tags(settings, git)
      out = git!(git, "ls-remote", "--tags", settings.remote, "refs/tags/#{settings.tags}")
      shas = {}
      out.lines.each do |l|
        sha, ref = l.chomp.split("\t", 2)
        next unless ref&.start_with?("refs/tags/")

        name = ref.delete_prefix("refs/tags/")
        peeled = name.end_with?("^{}")
        name = name.delete_suffix("^{}")
        shas[name] = sha if peeled || !shas.key?(name)
      end
      versions = shas.filter_map do |name, sha|
        v = settings.version_of(name)
        v && { name: name, sha: sha, version: v }
      end
      [versions, shas.keys - versions.map { |t| t[:name] }]
    end

    def relation(git, head, sha)
      return { state: "current", behind: 0 } if head == sha

      if ok?(git, "merge-base", "--is-ancestor", head, sha)
        { state: "available", behind: Integer(git!(git, "rev-list", "--count", "#{head}..#{sha}")) }
      elsif ok?(git, "merge-base", "--is-ancestor", sha, head)
        { state: "ahead", behind: 0 }
      else
        { state: "diverged", behind: Integer(git!(git, "rev-list", "--count", "#{head}..#{sha}")) }
      end
    end

    # porcelain v1: "XY path" — read from git's own output (git! strips, which would eat a leading " M")
    def dirty(git)
      out, err, ok = git.call(%w[status --porcelain --untracked-files=no])
      raise Refused, "git status: #{err.to_s.strip}" unless ok

      out.lines.map { |l| l.chomp[3..] }
    end

    # The check's target for a mode (tags → the newest version tag, branch → <remote>/<branch>) once it is allowed:
    # a clean tree, the checkout on the followed branch or detached, a fast-forward, and (expect) the sha the
    # operator was shown. → {mode, name, sha, from, behind}
    def target!(check, settings, mode:, expect: nil)
      raise Refused, "mode must be one of #{MODES.join(', ')}" unless MODES.include?(mode)

      t = check.fetch(mode == "tags" ? :tag : :branch)
      what = mode == "tags" ? "the newest #{settings.tags} tag" : "#{settings.remote}/#{settings.branch}"
      raise Refused, "no #{settings.tags} tag that is a version on #{settings.remote}" if t[:state] == "none"
      raise Refused, "already on #{what} (#{t[:name]} #{t[:sha][0, 7]})" if t[:state] == "current"
      raise Refused, "the checkout already contains #{what} (#{t[:name]}): nothing to update" if t[:state] == "ahead"
      if t[:state] == "diverged"
        raise Refused, "HEAD has commits #{what} (#{t[:name]}) lacks: not a fast-forward, nothing changed"
      end
      if (paths = check[:dirty]).any?
        raise Refused, "tracked files changed: #{paths.first(5).join(', ')}#{' …' if paths.size > 5} — commit or " \
                       "discard them first"
      end
      on = check.dig(:head, :branch)
      if on && on != settings.branch
        raise Refused, "the checkout is on #{on}; updates follow #{settings.branch} (config/busyyaks.yml updates.branch)"
      end
      if expect && expect != t[:sha]
        raise Refused, "#{what} moved since it was shown (#{expect[0, 7]} → #{t[:sha][0, 7]}): check again"
      end

      { mode: mode, name: t[:name], sha: t[:sha], from: check.dig(:head, :sha), behind: t[:behind], branch: on }
    end

    # Moves the checkout onto the target: on the branch a fast-forward merge (the branch moves), detached a checkout of
    # the commit. Both refuse to touch a changed file.
    def move!(target, git:)
      if target[:branch]
        git!(git, "merge", "--ff-only", "--quiet", target[:sha])
      else
        git!(git, "checkout", "--quiet", "--detach", target[:sha])
      end
    end

    # Back to where move! started (a failed build): the branch reset to it keeping the work tree's files, or detached
    def back!(target, git:)
      if target[:branch]
        git!(git, "reset", "--keep", "--quiet", target[:from])
      else
        git!(git, "checkout", "--quiet", "--detach", target[:from])
      end
    end

    # --- the records, in the launcher's state dir (.env LAUNCHER_STATE_DIR: no container mounts it)
    CHECK_FILE = "update-check.json"
    RECORD_FILE = "update.json"
    LOCK_FILE = "update.lock"

    def write_json!(dir, name, value)
      path = File.join(dir, name)
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.pretty_generate(value), perm: 0o600)
      File.rename(tmp, path)
    end

    def read_json(dir, name)
      JSON.parse(File.read(File.join(dir, name)))
    rescue Errno::ENOENT
      nil
    rescue JSON::ParserError => e
      { "state" => "unreadable", "error" => "#{name}: #{e.message}" }
    end

    # The one running update (an exclusive flock held for its life) → the open lock file, or nil when another holds it
    def lock(dir)
      f = File.open(File.join(dir, LOCK_FILE), File::RDWR | File::CREAT, 0o600)
      return f if f.flock(File::LOCK_EX | File::LOCK_NB)

      f.close
      nil
    end

    def running?(dir)
      f = lock(dir)
      return true unless f

      f.close
      false
    end
  end
end
