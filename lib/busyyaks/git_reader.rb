# frozen_string_literal: true

require "json"
require "set"
require "rugged"

module Busyyaks
  # The child side of GitRead (bin/git-read): ONE read of ONE repo through libgit2 (rugged), in a process the parent
  # kills on its limits. libgit2 runs no program a repo's config names — no filter driver (only its built-in crlf /
  # ident), no textconv / diff.external, no fsmonitor, no pager, no hook (card #260: checked in libgit2's source and
  # by the fixtures in test/unit/git_read_test.rb). What it still does with a crafted repo — follow `commondir` /
  # alternates / `core.worktree` / a `gitdir:` file out of the projects mount, block on a FIFO, parse an include
  # fan-out — is refused here before the repo is opened, and checked again after:
  #   - the repo dir, its .git (dir or `gitdir:` file), the common dir and every alternate (recursively) resolve inside
  #     root; the git dir's files libgit2 reads at open are regular files (never a FIFO / device);
  #   - a repo config with an include / includeIf section is refused (the include target is any file, any FIFO);
  #   - after open: repo.path and repo.workdir inside root, the work tree IS the repo dir (no core.worktree), no
  #     sparse checkout (libgit2 would count every skipped file as deleted).
  # Inputs that reach libgit2's revision grammar never come from a request: refs are looked up as reference NAMES
  # (Rugged::Reference.valid_name?), commits as 40-hex ids (repo.lookup), never rev_parse.
  # Residual risk (documented in docs/DEPLOY.md): a writer on the host can swap a symlink between the checks and
  # libgit2's open; what it can reach then is what this child can read (an empty env, no secrets, limits on).
  class GitReader
    class Refused < StandardError; end

    GIT_FILES = %w[HEAD config config.worktree commondir gitdir packed-refs index info/attributes info/exclude
                   objects/info/alternates].freeze
    COMMON_FILES = %w[config packed-refs info/attributes info/exclude objects/info/alternates].freeze
    INCLUDE = /^\s*\[\s*include(?:if)?\b/i
    MAX_CONFIG = 1024 * 1024
    MAX_SMALL = 64 * 1024
    MAX_ALTERNATE_DEPTH = 5
    MAX_REFS = 64
    MAX_FILES = 64
    SHA = /\A\h{40}\z/

    # JSON request → JSON answer: {"ok": true, ...} or {"ok": false, "error": why}.
    def self.serve(input)
      req = JSON.parse(input.to_s)
      raise Refused, "the request is not an object" unless req.is_a?(Hash)

      reader = new(root: req["root"], path: req["path"], max_blob: Integer(req["max_blob"]), memory: req["memory"])
      JSON.generate({ ok: true }.merge(reader.run(req)))
    rescue Refused, Rugged::Error, JSON::ParserError, ArgumentError, TypeError, SystemCallError, IOError, NoMemoryError => e
      JSON.generate(ok: false, error: "#{e.class.name.split('::').last}: #{e.message}"[0, 2000])
    end

    def initialize(root:, path:, max_blob:, memory: nil)
      @root = real!(root.to_s, "root")
      @path = inside!(path.to_s, "repo dir")
      @max_blob = max_blob
      # libgit2's pack windows must fit in the child's address-space limit (RLIMIT_AS): its 64-bit default maps up to
      # 8 GiB; here at most a quarter of the limit, in 32 MiB windows
      return unless memory

      Rugged::Settings["mwindow_size"] = 32 * 1024 * 1024
      Rugged::Settings["mwindow_mapped_limit"] = Integer(memory) / 4
    end

    def run(req)
      case req["op"]
      when "scan" then scan(since: int(req, "since"), max_commits: int(req, "max_commits"),
                            daily_since: int(req, "daily_since"), max_daily: int(req, "max_daily"),
                            keys: list(req, "config_keys", 32))
      when "head" then head
      when "churn" then churn(list(req, "shas", 500))
      when "files_at" then files_at(list(req, "refs", MAX_REFS), list(req, "files", MAX_FILES))
      else raise Refused, "unknown op #{req['op'].inspect}"
      end
    end

    # ── containment ───────────────────────────────────────────────────────────────────────────────

    def repo
      @repo ||= open!
    end

    def open!
      gitdir = git_dir!
      GIT_FILES.each { |f| regular!(File.join(gitdir, f), f) }
      common = gitdir
      cd = File.join(gitdir, "commondir")
      if File.exist?(cd)
        common = inside!(File.expand_path(small(cd).strip, gitdir), "commondir")
        COMMON_FILES.each { |f| regular!(File.join(common, f), "commondir #{f}") }
      end
      [File.join(common, "config"), File.join(gitdir, "config.worktree")].uniq.each { |c| no_include!(c) }
      alternates!(File.join(common, "objects"), 0)

      r = Rugged::Repository.new(@path)
      inside!(r.path, "the opened git dir")
      raise Refused, "a bare repo has no work tree to read" unless r.workdir
      if File.realpath(r.workdir) != @path || r.config["core.worktree"]
        raise Refused, "core.worktree is set (the work tree is not the repo dir): not read"
      end
      raise Refused,
"sparse checkout is not supported (every skipped file would count as changed)" if bool(r.config["core.sparseCheckout"])

      r
    end

    def git_dir!
      dot = File.join(@path, ".git")
      raise Refused, "#{@path} has no .git" unless File.symlink?(dot) || File.exist?(dot)

      return inside!(dot, ".git") if File.directory?(dot)
      raise Refused, ".git is neither a directory nor a regular file" unless File.file?(dot)

      line = small(dot)[/\Agitdir: *(.+?)\s*\z/, 1] or raise Refused, ".git is a file without a gitdir: line"
      inside!(File.expand_path(line, @path), ".git's gitdir")
    end

    def alternates!(objects, depth)
      file = File.join(objects, "info", "alternates")
      return unless File.symlink?(file) || File.exist?(file)
      raise Refused, "alternates nested deeper than #{MAX_ALTERNATE_DEPTH}" if depth >= MAX_ALTERNATE_DEPTH

      regular!(file, "alternates")
      small(file).each_line.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }.each do |l|
        alternates!(inside!(File.expand_path(l, objects), "alternate object dir"), depth + 1)
      end
    end

    def no_include!(config)
      return unless File.exist?(config)
      raise Refused, "#{File.basename(config)} is larger than #{MAX_CONFIG} bytes" if File.size(config) > MAX_CONFIG
      raise Refused,
"the repo config includes another file (include / includeIf): not read" if File.read(config).match?(INCLUDE)
    end

    # a git file that exists must resolve inside root and be a regular file (a FIFO would block libgit2's read)
    def regular!(file, what)
      return unless File.symlink?(file) || File.exist?(file)

      real = inside!(file, what)
      raise Refused, "#{what} is not a regular file" unless File.file?(real)
    end

    def small(file)
      raise Refused, "#{file} is not a regular file" unless File.file?(file)
      raise Refused, "#{file} is larger than #{MAX_SMALL} bytes" if File.size(file) > MAX_SMALL

      File.read(file)
    end

    def inside!(path, what)
      real = real!(path, what)
      return real if real == @root || real.start_with?("#{@root}/")

      raise Refused, "#{what} resolves outside #{@root}"
    end

    def real!(path, what)
      File.realpath(path)
    rescue SystemCallError => e
      raise Refused, "#{what} cannot be resolved: #{e.message}"
    end

    # ── reads ─────────────────────────────────────────────────────────────────────────────────────

    # Everything the scanner stores for a repo, in one read.
    def scan(since:, max_commits:, daily_since:, max_daily:, keys:)
      walk = walk(since, max_commits, daily_since, max_daily)
      b = branch
      # a key naming %{branch} is read for the checked-out branch (none when HEAD is detached)
      names = keys.filter_map { |k| if k.include?("%{branch}")
                                      b.empty? ? nil : k.sub("%{branch}", b)
else
  k
end }
      { remotes: repo.remotes.each_name.to_h { |n| [n, repo.remotes[n]&.url] },
        branch: b, config: names.to_h { |k| [k, repo.config[k]] }, **dirty, unpushed: unpushed,
        branches: branches, default_ref: default_ref, **walk, }
    end

    def head = { branch: branch, last_commit_at: repo.head_unborn? ? nil : repo.head.target.time.to_i }

    # the checked-out branch's name; "" when HEAD is detached (git branch --show-current)
    def branch
      ref = repo.references["HEAD"]
      ref&.type == :symbolic ? ref.target_id.to_s.delete_prefix("refs/heads/") : ""
    end

    def default_ref
      b = branch
      b.empty? || repo.head_unborn? ? "HEAD" : b
    end

    # local + remote-tracking branch names, the remote's name dropped; no HEAD
    def branches
      local = repo.branches.each_name(:local).to_a
      remote = repo.branches.each_name(:remote).map { |r| r.sub(%r{\A[^/]+/}, "") }
      (local + remote).reject { |b| b.empty? || b == "HEAD" || b.end_with?("/HEAD") }.uniq.sort
    end

    STATUS_CODE = { added: "A", deleted: "D", modified: "M", typechange: "T", renamed: "R", copied: "C" }.freeze

    # `git status --porcelain --no-renames --ignore-submodules=all` lines ("XY path", sorted by path): staged (X) +
    # unstaged (Y) + untracked ("??", an untracked dir once), never ignored files or submodules
    # {dirty: the count, dirty_paths: the porcelain lines}; an index libgit2 cannot read → 0 and nil (unknown, never [])
    def dirty
      lines = status_lines
      { dirty: lines.size, dirty_paths: lines }
    rescue Rugged::Error
      { dirty: 0, dirty_paths: nil }
    end

    def status_lines
      opts = { ignore_submodules: true, max_size: @max_blob }
      index = repo.index
      st = Hash.new { |h, k| h[k] = [" ", " "] }
      if repo.head_unborn?
        index.each { |e| st[e[:path]][0] = "A" }
      else
        repo.head.target.tree.diff(index, opts).deltas.each { |d| st[d.new_file[:path]][0] = code(d.status) }
      end
      index.diff(opts.merge(include_untracked: true, recurse_untracked_dirs: false)).deltas.each do |d|
        if d.status == :untracked
          st[d.new_file[:path]] = %w[? ?]
        else
          st[d.new_file[:path]][1] = code(d.status)
        end
      end
      st.sort.map { |path, (x, y)| "#{x}#{y} #{path}" }
    end

    def code(status) = STATUS_CODE.fetch(status, "?")

    # commits on the checked-out branch its upstream lacks (`rev-list --count @{u}..HEAD`); nil = no upstream / branch
    def unpushed
      b = branch
      return nil if b.empty? || repo.head_unborn?

      up = repo.branches[b]&.upstream or return nil
      repo.ahead_behind(repo.head.target_id, up.target_id).first
    end

    # Every ref's commit history (`git log --all`), newest first: the last commit's time, the commits since `since`
    # (at most max_commits) and, back to daily_since, {day => {email => n}} by committer date. More than max_daily
    # commits in that range → daily nil + daily_error (never a cut series).
    def walk(since, max_commits, daily_since, max_daily)
      w = Rugged::Walker.new(repo)
      w.sorting(Rugged::SORT_DATE)
      tips.each { |oid| w.push(oid) }
      commits = []
      daily = Hash.new { |h, k| h[k] = Hash.new(0) }
      n = 0
      last = nil
      daily_error = nil
      w.each do |c|
        t = c.time.to_i
        last ||= t
        break if t < daily_since

        if t >= since && commits.size < max_commits
          a = c.author
          commits << { sha: c.oid, author: a[:name], email: a[:email].to_s.downcase, committed_at: t, subject: c.summary }
        end
        if (n += 1) > max_daily
          daily_error = "more than #{max_daily} commits since #{Time.at(daily_since).utc.strftime('%F')}"
          break
        end
        daily[c.committer[:time].strftime("%F")][c.author[:email].to_s.downcase] += 1
      end
      { last_commit_at: last, commits: commits, daily: daily_error ? nil : daily, daily_error: daily_error }
    end

    # the commit every ref (and a detached HEAD) points at
    def tips
      oids = Set.new
      oids << repo.head.target_id unless repo.head_unborn?
      repo.refs.each { |r| (oid = commit_id(r)) && oids << oid }
      oids
    end

    # the commit a ref points at (through a symbolic ref and annotated tags), nil when it is no commit
    def commit_id(ref)
      # rugged's peel is nil for a direct ref to a non-tag object: then its own target is the object
      oid = ref.peel || (ref.type == :direct ? ref.target_id : nil)
      oid && repo.read_header(oid)[:type] == :commit ? oid : nil
    end

    # Lines changed by these commits (`git show --numstat --no-renames`): [[path, added, deleted, binary, oversized]].
    # A commit is diffed against its first parent (a merge too, as git show --numstat prints it), a root commit against
    # nothing. A blob larger than max_blob is never loaded: binary, 0 lines, oversized = true.
    def churn(shas)
      shas.each { |s| raise Refused, "#{s.inspect} is not a 40-hex commit id" unless s.is_a?(String) && s.match?(SHA) }
      commits = []
      files = shas.flat_map do |sha|
        c = repo.lookup(sha)
        raise Refused, "#{sha} is not a commit" unless c.is_a?(Rugged::Commit)

        diff = Rugged::Tree.diff(repo, c.parents.first&.tree, c.tree, max_size: @max_blob)
        commits << { sha: sha, paths: diff.deltas.map { |d| d.new_file[:path] } }
        diff.patches.map do |p|
          f = p.delta.new_file
          big = f[:size].to_i > @max_blob || p.delta.old_file[:size].to_i > @max_blob
          add, del = p.delta.binary? ? [0, 0] : p.stat
          [f[:path], add, del, p.delta.binary?, big]
        end
      end
      { files: files, commits: commits }
    end

    # {file => the first of refs whose tree has it}. A ref is a branch NAME (local, else any remote's) or "HEAD"
    # (`cat-file -e <ref>:<file>`, but never through the revision grammar); a file is a plain relative path.
    def files_at(refs, files)
      trees = refs.filter_map { |r| (t = tree_of(r)) && [r, t] }
      found = files.each_with_object({}) do |f, out|
        raise Refused, "#{f.inspect} is not a relative path in the repo" unless plain_path?(f)

        hit = trees.find { |_, t| entry?(t, f) }
        out[f] = hit.first if hit
      end
      { found: found }
    end

    def tree_of(ref)
      raise Refused, "#{ref.inspect} is not a ref name" unless ref.is_a?(String)
      return repo.head_unborn? ? nil : repo.head.target.tree if ref == "HEAD"
      raise Refused, "#{ref.inspect} is not a valid branch name" unless Rugged::Reference.valid_name?("refs/heads/#{ref}")

      r = repo.references["refs/heads/#{ref}"] || repo.references.each("refs/remotes/*/#{ref}").first
      oid = r && commit_id(r)
      oid && repo.lookup(oid).tree
    end

    def entry?(tree, file)
      tree.path(file)
      true
    rescue Rugged::TreeError
      false
    end

    def plain_path?(file)
      file.is_a?(String) && !file.empty? && file.bytesize <= 4096 && !file.start_with?("/") && !file.include?("\0") &&
        file.split("/").none? { |s| s.empty? || s == "." || s == ".." }
    end

    private

    def int(req, key) = Integer(req.fetch(key))

    def list(req, key, max)
      v = req.fetch(key)
      raise Refused, "#{key} must be a list of at most #{max} strings" unless v.is_a?(Array) && v.size <= max && v.all?(String)

      v
    end

    def bool(v) = %w[true yes on 1].include?(v.to_s.downcase)
  end
end
