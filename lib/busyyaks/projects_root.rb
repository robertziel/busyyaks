# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "tempfile"
require_relative "launcher_rules"
require_relative "launch_trust"
require_relative "env_file"

module Busyyaks
  # The projects dir (.env PROJECTS_ROOT) chosen from the hello screen (card 532). PROJECTS_ROOT is the bind-mount
  # source of every container, so only the host changes it: bin/launcher answers `browse` (a dir picker), `projects_root`
  # with `plan` (every check below, read now, + a plan id) and `apply` (the same plan, its id unchanged → .env rewritten,
  # compose recreated, the launcher restarted). Pure stdlib: bin/launcher requires it.
  #
  # A new root is refused unless: an absolute dir, written as its real path; not `/`; not the current one; not inside
  # or around a dir the stack keeps apart from it (LAUNCHER_RUN_DIR, LAUNCHER_STATE_DIR, the collector's dir — the
  # launcher and the collector refuse to start otherwise; the checkout may sit inside it, as it may now); every
  # config/busyyaks.yml `roots` entry is a dir under it (the scanner reads them); every `launch.trusted_paths` entry is
  # a repo under it (the launcher refuses to start otherwise — the plan lists each one's new host dir: the same
  # container path then trusts THAT repo); `docker` is on the launcher's PATH.
  module ProjectsRoot
    class Invalid < StandardError; end

    # the services that mount PROJECTS_ROOT and are recreated by an apply (= CLI::SERVICES, test/unit/projects_root_test.rb)
    SERVICES = %w[web mcp scanner github notifier].freeze
    MAX_ENTRIES = 1000
    STATE_FILE = "projects-root.json"

    module_function

    # One dir's subdirs for the picker: names only (never a file), dot dirs skipped (the scanner skips them too), sorted,
    # at most MAX_ENTRIES; `git` = the subdir holds a .git. → {path, parent, entries, truncated, repos}
    # Collecting stops at MAX_ENTRIES + 1 dirs (the one more only says `truncated`): a huge dir is never read whole.
    def browse(path)
      dir = real_dir!(path)
      names = []
      Dir.each_child(dir) do |n|
        next if n.start_with?(".") || !File.directory?(File.join(dir, n))

        names << n
        break if names.size > MAX_ENTRIES
      end
      entries = names.sort.first(MAX_ENTRIES).map { |n| { name: n, git: File.exist?(File.join(dir, n, ".git")) } }
      { path: dir, parent: dir == "/" ? nil : File.dirname(dir), entries: entries, truncated: names.size > MAX_ENTRIES,
        repos: entries.count { |e| e[:git] }, }
    rescue SystemCallError => e
      raise Invalid, "#{path}: #{e.message}"
    end

    # → the plan (a Hash, JSON-safe) with its id; Invalid naming the first check that fails.
    #   current: the PROJECTS_ROOT the stack runs on · container_root: PROJECTS_MOUNT · roots: config `roots` paths ·
    #   trusted: launch.trusted_paths · apart: {what => dir} the new root may not overlap (inside or around) ·
    #   not_inside: {what => dir} the new root may not lie in (it may hold them: the checkout's ./data sits in the
    #   projects dir on a box that scans busyyaks itself) · created: the repos the launcher's create made and trusts
    #   (host paths: those under the current root are listed as losing that trust) · docker: the docker program found on
    #   PATH (nil = none)
    def plan(path, current:, container_root:, roots:, trusted:, apart:, docker:, not_inside: {}, created: [])
      raise Invalid, "give an absolute path (got #{path.inspect})" unless path.to_s.start_with?("/")

      root = real_dir!(path)
      raise Invalid, "#{path} goes through a symlink or ends in /: write its real path #{root}" unless path == root
      raise Invalid, "/ is the whole disk: choose the directory that holds your git repos" if root == "/"
      raise Invalid, "#{root} is already the projects dir" if root == current

      apart.each do |what, dir|
        o = LauncherRules.resolve(dir)
        next unless LauncherRules.inside?(root, o) || LauncherRules.inside?(o, root)

        raise Invalid, "#{root} overlaps #{what} (#{o}), which must stay outside the projects dir"
      end
      not_inside.each do |what, dir|
        o = LauncherRules.resolve(dir)
        raise Invalid, "#{root} lies in #{what} (#{o}): choose a dir outside it" if LauncherRules.inside?(root, o)
      end
      root_dirs = roots.map do |r|
        host = host_path(r, container_root, root)
        raise Invalid, "config/busyyaks.yml roots #{r} would be #{host}: not a directory" unless File.directory?(host)

        { path: r, host: host }
      end
      trusted_dirs = trusted_map(trusted, container_root, current, root)
      raise Invalid, "docker is not on the launcher's PATH: it recreates the containers" unless docker

      # git-init'ed repos keep their trust by host path (LaunchTrust::Created): under a new root they are other dirs
      untrusted = created.select { |c| LauncherRules.inside?(c, current) && c != current }.sort
      body = { from: current, to: root, repos: browse(root)[:repos], roots: root_dirs, trusted: trusted_dirs,
               loses_trust: untrusted, services: SERVICES, }
      body.merge(plan_id: Digest::SHA256.hexdigest(JSON.generate(body)))
    end

    # each trusted path: its host dir now → under the new root (must be a repo there: LaunchTrust.host_paths!)
    def trusted_map(trusted, container_root, current, root)
      after = begin
        LaunchTrust.host_paths!(trusted, container_root: container_root, projects_root: root)
      rescue LaunchTrust::Invalid => e
        raise Invalid, "#{e.message} under #{root}: the launcher would not start — edit launch.trusted_paths first"
      end
      trusted.each_with_index.map { |p, i| { path: p, from: host_path(p, container_root, current), to: after[i] } }
    end

    def host_path(container_path, container_root, root)
      container_path == container_root ? root : File.join(root, container_path.delete_prefix("#{container_root}/"))
    end

    def real_dir!(path)
      raise Invalid, "give an absolute path (got #{path.inspect})" unless path.to_s.start_with?("/")

      real = File.realpath(path)
      raise Invalid, "#{path} is not a directory" unless File.directory?(real)
      raise Invalid, "#{path} is not readable" unless File.readable?(real) && File.executable?(real)

      real
    rescue SystemCallError => e
      raise Invalid, "#{path}: #{e.message}"
    end

    # The .env text with its one PROJECTS_ROOT line set to root; every other line kept byte for byte. The result must
    # parse (EnvFile) and read root back.
    def rewrite_env(text, root, path: ".env")
      lines = text.lines
      at = lines.each_index.select { |i| lines[i].start_with?("PROJECTS_ROOT=") }
      raise Invalid, "#{path}: #{at.size} PROJECTS_ROOT lines (one expected)" unless at.size == 1
      raise Invalid, "#{root.inspect} cannot be written to .env (a quote, $, # or whitespace)" if root.match?(/[\s"'$#\\]/)

      lines[at.first] = "PROJECTS_ROOT=#{root}#{lines[at.first].end_with?("\n") ? "\n" : ''}"
      out = lines.join
      raise Invalid, "#{path}: rewrite did not take" unless EnvFile.parse(out, path: path)["PROJECTS_ROOT"] == root

      out
    end

    # .env rewritten atomically (same dir, same mode); the old file kept as backup (0600) in backup_dir — the launcher's
    # state dir (0700, no container mounts it): never beside .env in the checkout, where git does not ignore it and every
    # secret in it would be one `git add -A` away. → the backup's path.
    def write_env!(env_path, root, stamp:, backup_dir:)
      text = File.read(env_path)
      out = rewrite_env(text, root, path: env_path)
      backup = File.join(backup_dir, "env.bak-projects-root-#{stamp}")
      File.open(backup, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(text) }
      begin
        replace!(env_path, out)
      rescue StandardError
        File.delete(backup) # .env was never replaced (the rename is the last step): no orphan copy of its secrets
        raise
      end
      backup
    end

    def restore_env!(env_path, backup) = replace!(env_path, File.read(backup))

    def replace!(env_path, text)
      mode = File.stat(env_path).mode & 0o777
      f = Tempfile.create([".env", ".tmp"], File.dirname(env_path))
      begin
        f.write(text)
        f.close
        File.chmod(mode, f.path)
        File.rename(f.path, env_path)
      ensure
        f.close unless f.closed?
        FileUtils.rm_f(f.path)
      end
    end

    # The compose command an apply runs, from the checkout (compose reads its .env there)
    def compose_argv(checkout) =
      ["docker", "compose", "--project-directory", checkout, "up", "-d", "--wait", "--no-build", *SERVICES]

    # the last apply, as recorded in the launcher's state dir: nil = never applied
    def state(dir)
      file = File.join(dir, STATE_FILE)
      File.exist?(file) ? JSON.parse(File.read(file)) : nil
    end

    # A record left at "applying" with no apply running (its last write failed, or the launcher stopped mid-way) is
    # answered with what this launcher knows: it runs on `to` → done (only a compose that succeeded restarts it there),
    # else interrupted. Said in `note`, the stored record untouched.
    def settled(last, current:, running:)
      return last unless last && last["state"] == "applying" && !running

      done = current == last["to"]
      # done: this launcher started on the new .env. Interrupted: the record's `env` is stale (a rollback may have put
      # the old .env back after it was written) — unknown, never claimed
      last.merge("state" => done ? "done" : "interrupted", "env" => done ? "new" : "unknown",
                 "note" => "the record was not finished: the launcher #{done ? 'runs on' : 'does not run on'} #{last['to']}")
    end

    def record!(dir, data)
      f = Tempfile.create(["projects-root", ".json.tmp"], dir)
      begin
        f.write(JSON.generate(data))
        f.close
        File.chmod(0o600, f.path)
        File.rename(f.path, File.join(dir, STATE_FILE))
      ensure
        f.close unless f.closed?
        FileUtils.rm_f(f.path)
      end
    end
  end
end
