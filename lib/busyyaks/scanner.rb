# frozen_string_literal: true

require "json"
require_relative "icons"
require_relative "git_read"
require_relative "owner_remotes"

module Busyyaks
  # Reads the git state of every repo under the configured roots — each repo in its own killable child (GitRead:
  # libgit2, limits from GIT_READ_*), never the git CLI. A repo that cannot be read (a limit, a refusal: its config
  # points out of the root, a FIFO, an include …) keeps its last good row with that error in git_error, and the
  # scan's error lists it; the other repos are scanned as always.
  class Scanner
    MAX_COMMITS = 500
    DIRTY_PATHS_MAX = 20
    # commits in the 371-day series past which a repo's daily series is an error, never a cut one
    MAX_DAILY_COMMITS = 50_000
    DAILY_DAYS = 371
    # what the child reads of each repo's config: the push remote chain and the private-mirror guard
    CONFIG_KEYS = %w[branch.%{branch}.pushRemote remote.pushDefault branch.%{branch}.remote guard.mode
                     guard.mirrorRemote guard.upstreamRemote guard.publicRemote].freeze

    def initialize(config, store, clock: -> { Time.now.to_i })
      @config = config
      @store = store
      @clock = clock
    end

    def run
      started = @clock.call
      scan_id = @store.scan_started(started)
      repos = repo_paths
      failed = []
      seen = repos.map do |path, slug, root|
        why = scan_repo(path, slug, root, started)
        failed << "#{slug}: #{why}" if why
        slug
      end
      @store.mark_absent(except: seen)
      error = failed.empty? ? nil : "#{failed.size} of #{repos.size} repos not read — #{failed.join('; ')}"[0, 4000]
      @store.scan_finished(scan_id, @clock.call, repos.size, error)
      repos.size
    rescue StandardError => e
      @store.scan_finished(scan_id, @clock.call, nil, "#{e.class}: #{e.message}") if scan_id
      raise
    end

    # A project is a directory with .git. Each child of a root is a tree: a repo itself, or searched
    # search_depth subdirs further down for repos (a repo is never descended into); nothing found
    # within that depth = the tree is given up. Slugs are "<prefix><path below the root>".
    # A directory that is itself a configured root is left to that root (its own prefix). Dot dirs skipped.
    def repo_paths
      roots = @config.roots.map { |r| File.expand_path(r[:path]) }
      @config.roots.flat_map do |root|
        dir = root[:path]
        raise Errno::ENOENT, "root not mounted: #{dir}" unless File.directory?(dir)

        subdirs(dir).flat_map { |c| find_repos(dir, c, @config.search_depth, roots) }
                    .map { |rel| [File.join(dir, rel), "#{root[:prefix]}#{rel}", dir] }
      end
    end

    def find_repos(base, rel, depth, roots)
      path = File.join(base, rel)
      return [rel] if repo?(path)
      return [] if depth.zero? || roots.include?(File.expand_path(path))

      subdirs(path).flat_map { |c| find_repos(base, File.join(rel, c), depth - 1, roots) }
    end

    def subdirs(dir)
      Dir.children(dir).sort.reject { |c| c.start_with?(".") }.select { |c| File.directory?(File.join(dir, c)) }
    rescue Errno::EACCES
      []
    end

    def repo?(path) = File.exist?(File.join(path, ".git"))

    # → nil, or why the repo (or its daily series) was not read
    def scan_repo(path, slug, root, now)
      since = now - (@config.window_days * 86_400)
      r = GitRead.call("scan", path: path, root: root, since: since, max_commits: MAX_COMMITS,
                               daily_since: now - (DAILY_DAYS * 86_400), max_daily: MAX_DAILY_COMMITS, config_keys: CONFIG_KEYS)
      commits = r["commits"].map do |c|
        c.transform_keys(&:to_sym).merge(mine: @config.author_emails.include?(c["email"]))
      end
      remote = sanitize_remote(r["remotes"]["origin"])
      icon_path, icon_mtime = Icons.find(path)
      @store.upsert_project(
        slug: slug, path: path, remote: remote, pr_remote: pr_remote(r), branch: r["branch"], **enrolment(r),
        own: own?(remote, commits),
        last_commit_at: r["last_commit_at"], # no commits = unknown, not 1970
        commits_window: commits.size, mine_window: commits.count { |c| c[:mine] },
        # dirty_paths nil = the index could not be read (unknown), never "[]" (clean)
        dirty: r["dirty"], dirty_paths: r["dirty_paths"] && JSON.generate(r["dirty_paths"].first(DIRTY_PATHS_MAX)),
        unpushed: r["unpushed"], # no upstream = unknown (nil), not 0
        branches: JSON.generate(r["branches"]), default_ref: r["default_ref"], git_error: r["daily_error"],
        scanned_at: now, icon_path: icon_path, icon_mtime: icon_mtime
      )
      @store.replace_commits(slug, commits, since)
      @store.replace_daily(slug, daily(r["daily"])) if r["daily"]
      r["daily_error"] && "daily series: #{r['daily_error']}"
    rescue GitRead::Failed => e
      @store.project_git_failed(slug, e.message)
      e.message.delete_prefix("#{path}: ")
    end

    # {day => {email => n}} → {day => [commits, mine]}
    def daily(days)
      days.transform_values do |by|
        [by.values.sum, by.sum { |email, n| @config.author_emails.include?(email) ? n : 0 }]
      end
    end

    def own?(remote, _commits)
      return true if remote.nil?

      OwnerRemotes.owned?(remote, @config.owner_remotes)
    end

    # An https remote can carry a token in its userinfo; never store it.
    def sanitize_remote(url)
      return nil if url.nil? || url.empty?

      url.sub(%r{\A(\w+://)[^@/]*@}, '\1')
    end

    # The remote the checked-out branch is pushed to — where its PRs live (a repo may push its work to a
    # private remote while origin is the public release repo): branch.<b>.pushRemote → remote.pushDefault →
    # branch.<b>.remote (its upstream's) → origin, the last only for a branch that names none (or no branch).
    def pr_remote(read)
      b = read["branch"].to_s
      cfg = read["config"]
      name = unless b.empty?
               [cfg["branch.#{b}.pushRemote"], cfg["remote.pushDefault"], cfg["branch.#{b}.remote"]]
                 .find { |r| !r.to_s.empty? && r != "." }
             end
      sanitize_remote(read["remotes"][name || "origin"])
    end

    # the repo's private local-repo guard config (`guard.*` in git config) → which repo is the local one, which the
    # public one, and where pub/card-<id> is pushed. Not enrolled (no guard.mode) → every column nil. A guard key
    # naming no remote, or a remote with no URL, leaves that column nil and is said in local_error (e.g. upstream
    # mode before the fork is added) — never a guessed repo.
    LOCAL_KEYS = { local_repo: "guard.mirrorRemote", public_repo: "guard.upstreamRemote",
                    public_head: "guard.publicRemote", }.freeze

    def enrolment(read)
      none = { local_mode: nil, local_repo: nil, public_repo: nil, public_head: nil, local_error: nil }
      mode = read["config"]["guard.mode"]
      return none if mode.to_s.empty?
      unless %w[own upstream].include?(mode)
        return none.merge(local_error: "guard.mode is #{mode.inspect}, not own or upstream")
      end

      errors = []
      urls = LOCAL_KEYS.to_h do |col, key|
        name = read["config"][key]
        url = name.to_s.empty? ? nil : sanitize_remote(read["remotes"][name])
        errors << (name.to_s.empty? ? "#{key} is not set" : "#{key} names remote #{name.inspect}, which has no URL") unless url
        [col, url]
      end
      none.merge(local_mode: mode, **urls, local_error: errors.empty? ? nil : errors.join("; "))
    end
  end
end
