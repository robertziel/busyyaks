# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tempfile"
require "securerandom"

module Busyyaks
  # Which repos bin/launcher answers Claude Code's folder-trust prompt for. Never from anything the repo holds (its
  # origin, its config: whoever wrote the repo wrote those). Only:
  #   - a path the operator declared: config/busyyaks.yml `launch.trusted_paths` (container paths under PROJECTS_MOUNT,
  #     like `roots`), each one exact (a listed dir trusts itself, never what lies under it);
  #   - a repo the launcher's own `create` made with git init (never a clone: what a cloned URL serves is someone's
  #     content, whoever owns the URL), recorded at that moment in a file only the launcher writes: .env
  #     LAUNCHER_STATE_DIR/created.json. Not the database — every service writes that.
  # Anything else keeps the prompt on screen for the operator. Pure Ruby: the host launcher requires this file alone.
  module LaunchTrust
    class Invalid < StandardError; end

    module_function

    # config/busyyaks.yml `launch` (required): {trusted_paths: [absolute paths], start_seconds: N} — trusted_paths'
    # shape only ([] allowed); Config.load checks them against PROJECTS_MOUNT (under_mount!), bin/launcher against the
    # disk (host_paths!). `start_seconds` is LauncherRules.start_seconds!'s.
    def parse!(value)
      raise Invalid, "launch must be a mapping {trusted_paths: [...], start_seconds: N}" unless value.is_a?(Hash)

      extra = value.keys - %w[trusted_paths start_seconds]
      raise Invalid, "launch: unknown keys #{extra.join(', ')}" if extra.any?

      paths = value["trusted_paths"]
      unless paths.is_a?(Array) && paths.all? { |p| p.is_a?(String) && p.start_with?("/") && !p.split("/").include?("..") }
        raise Invalid, "launch.trusted_paths must be a list of absolute paths under PROJECTS_MOUNT ([] for none)"
      end

      paths
    end

    def under_mount!(paths, mount)
      outside = paths.reject { |p| p.start_with?("#{mount.chomp('/')}/") }
      raise Invalid, "launch.trusted_paths #{outside.join(', ')} not under PROJECTS_MOUNT #{mount}" if outside.any?

      paths
    end

    # The host side: each container path → its real host path, which must exist, be a dir and lie inside PROJECTS_ROOT.
    def host_paths!(paths, container_root:, projects_root:)
      root = File.realpath(projects_root)
      paths.map do |p|
        host = File.join(projects_root, p.delete_prefix("#{container_root}/"))
        real = begin
          File.realpath(host)
        rescue SystemCallError => e
          raise Invalid, "launch.trusted_paths #{p} (#{host}): #{e.message}"
        end
        unless real.start_with?("#{root}/")
          raise Invalid, "launch.trusted_paths #{p} resolves to #{real}, outside PROJECTS_ROOT #{root}"
        end
        raise Invalid, "launch.trusted_paths #{p} (#{real}) is not a directory" unless File.directory?(real)
        # a repo root (a .git dir, or the .git file of a worktree): never a group dir of repos
        unless File.exist?(File.join(real, ".git"))
          raise Invalid, "launch.trusted_paths #{p} (#{real}) is not a git repo root (no .git)"
        end

        real
      end
    end

    # .env LAUNCHER_STATE_DIR: absolute, created 0700, this uid's, never open to group / other, and not inside (or
    # around) any dir a container mounts — PROJECTS_ROOT, the checkout (./data), the launcher's socket dir.
    def state_dir!(path, mounted:, uid:)
      raise Invalid, "LAUNCHER_STATE_DIR must be an absolute path (got #{path.inspect})" unless path.to_s.start_with?("/")

      real = resolve(path)
      mounted.each do |what, dir|
        o = resolve(dir)
        next unless inside?(real, o) || inside?(o, real)

        raise Invalid, "LAUNCHER_STATE_DIR #{path} (#{real}) overlaps #{what} (#{o}), which a container mounts: put it outside"
      end
      begin
        FileUtils.mkdir_p(real, mode: 0o700)
      rescue SystemCallError => e
        raise Invalid, "LAUNCHER_STATE_DIR #{real} cannot be created: #{e.message}"
      end
      st = File.stat(real)
      raise Invalid, "LAUNCHER_STATE_DIR #{real} is not a directory" unless st.directory?
      raise Invalid, "LAUNCHER_STATE_DIR #{real} is owned by uid #{st.uid}, not #{uid}" unless st.uid == uid
      if st.mode.anybits?(0o077)
        raise Invalid, "LAUNCHER_STATE_DIR #{real} is mode #{format('%o', st.mode & 0o777)}: check it, then chmod 700"
      end

      real
    end

    # The repos the launcher made and trusts — `git init` creates only, never a clone: <state dir>/created.json (0600),
    # a JSON list of {path, nonce}. At the init a random nonce (32 bytes, hex) is written to the repo's own
    # .git/busyyaks-created (0600) and recorded here; a repo is trusted only while that file holds the recorded nonce.
    # A repo removed and made again at the path (no file, or another nonce) is not the one recorded: not trusted, and
    # its entry is dropped. Read (and validated) at launcher start.
    class Created
      NONCE_FILE = "busyyaks-created"
      NONCE = /\A[0-9a-f]{64}\z/

      def initialize(dir)
        @dir = dir
        @file = File.join(dir, "created.json")
        @lock = Mutex.new
        @lock.synchronize { read } # a corrupt file stops the start, before any session
      end

      def entries
        @lock.synchronize { read }
      end

      def paths = entries.map { |e| e["path"] }

      def include?(dir)
        real = File.realpath(dir)
        @lock.synchronize do
          list = read
          entry = list.find { |e| e["path"] == real } or return false
          return true if nonce_of(real) == entry["nonce"]

          write(list - [entry]) # made again, or tampered with: never the repo recorded
          false
        end
      end

      # after a successful git init: the nonce into its .git, then the record; any failure raises (nothing stored).
      # Only a fresh init: the dir holds nothing but .git, and that repo has no object and no ref — checked right
      # before the nonce is written (a clone, or anything else that reached the dir, is refused).
      def record(dir)
        real = File.realpath(dir)
        LaunchTrust.fresh_init!(real)
        nonce = SecureRandom.hex(32)
        path = File.join(real, ".git", NONCE_FILE)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o600) { |f| f.write(nonce) }
        raise Invalid, "#{path}: the nonce did not read back" unless nonce_of(real) == nonce

        @lock.synchronize { write(read.reject { |e| e["path"] == real } + [{ "path" => real, "nonce" => nonce }]) }
        real
      end

      private

      # nil when the file is absent; any other failure to read it raises
      def nonce_of(real)
        File.open(File.join(real, ".git", NONCE_FILE), File::RDONLY | File::NOFOLLOW) { |f| f.read(65) }
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      rescue SystemCallError => e
        raise Invalid, "#{real}/.git/#{NONCE_FILE} cannot be read: #{e.message}"
      end

      # a uniquely named temp file in the same dir (mkstemp, 0600), then renamed over the record
      def write(list)
        f = Tempfile.create(["created", ".json.tmp"], @dir)
        begin
          f.write(JSON.generate(list))
          f.close
          File.rename(f.path, @file)
        ensure
          f.close unless f.closed?
          FileUtils.rm_f(f.path)
        end
      end

      def read
        return [] unless File.exist?(@file)

        list = begin
          JSON.parse(File.read(@file))
        rescue JSON::ParserError => e
          raise Invalid, "#{@file} is not valid JSON (#{e.message.lines.first.strip}): fix or remove it"
        end
        ok = list.is_a?(Array) && list.all? do |e|
          e.is_a?(Hash) && e.keys.sort == %w[nonce path] && e["path"].is_a?(String) && e["nonce"].to_s.match?(NONCE)
        end
        raise Invalid, "#{@file} is not a list of {path, nonce}: fix or remove it" unless ok

        list
      end
    end

    # A dir that holds only a just-made `git init`: nothing beside .git, no object, no ref, no packed refs.
    def fresh_init!(real)
      extra = Dir.children(real) - [".git"]
      raise Invalid, "#{real} holds more than a fresh .git (#{extra.first(3).join(', ')}): not recorded" if extra.any?

      git = File.join(real, ".git")
      raise Invalid, "#{git} is not a directory: not recorded" unless File.directory?(git) && !File.symlink?(git)

      objects = Dir.glob(File.join(git, "objects/**/*"), File::FNM_DOTMATCH).reject { |f| File.directory?(f) }
      refs = Dir.glob(File.join(git, "refs/**/*"), File::FNM_DOTMATCH).reject { |f| File.directory?(f) }
      refs << File.join(git, "packed-refs") if File.exist?(File.join(git, "packed-refs"))
      return if objects.empty? && refs.empty?

      raise Invalid, "#{real} is not a fresh git init (#{objects.size} objects, #{refs.size} refs): not recorded"
    end

    # The clone URL `create` takes, parsed strictly: https://<host>/<owner>/<repo>[.git] or git@<host>:<owner>/<repo>[.git];
    # every part [A-Za-z0-9._-]+, never . or .., nothing else (no userinfo, port, query, fragment, %, more segments).
    # → {host, owner, repo, url} where url is rebuilt from the parts — the only URL git is given.
    SEGMENT = /\A[A-Za-z0-9._-]+\z/

    def clone_url!(url)
      u = url.to_s
      m = u.match(%r{\Ahttps://([A-Za-z0-9.-]+)/([^/]+)/([^/]+)\z}) || u.match(/\Agit@([A-Za-z0-9.-]+):([^\/]+)\/([^\/]+)\z/)
      raise Invalid, "url must be https://host/owner/repo or git@host:owner/repo (got #{u.inspect})" unless m

      host = m[1].downcase
      owner = m[2]
      repo = m[3].delete_suffix(".git")
      [host, owner, repo].each do |part|
        next if part.match?(SEGMENT) && !%w[. ..].include?(part)

        raise Invalid, "url #{u.inspect}: #{part.inspect} is not a plain name"
      end
      canonical = u.start_with?("https://") ? "https://#{host}/#{owner}/#{repo}.git" : "git@#{host}:#{owner}/#{repo}.git"
      { host: host, owner: owner, repo: repo, url: canonical }
    end

    # The launcher's git clone: only https / ssh transports (protocol.allow=never otherwise: no file://, ext::, git://,
    # a submodule's either), no hook, no submodule — the clone of a URL someone pasted runs nothing from it.
    # Never waits on a prompt: ssh in batch mode (no password / passphrase / host-key question), no terminal prompt
    # (clone_env), stdin /dev/null (bin/launcher) — a clone that needs credentials fails at once.
    def clone_argv(url, dir)
      ["git", "-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "protocol.ssh.allow=always",
       "-c", "core.hooksPath=/dev/null", "-c", "core.sshCommand=ssh -o BatchMode=yes",
       "clone", "--no-recurse-submodules", "--progress", "--", url, dir,]
    end

    # ... in an environment holding only these (spawned with unsetenv_others: true — nothing inherited, so no
    # GIT_CONFIG_COUNT / GIT_CONFIG_PARAMETERS / GIT_SSH_COMMAND / GIT_TEMPLATE_DIR of the launcher's own environment):
    # PATH, an empty HOME, SSH_AUTH_SOCK and LANG when set, no global (an insteadOf or a protocol.<x>.allow there would
    # beat the -c flags) or system gitconfig, an empty template dir, no LFS download. ssh still finds the operator's
    # keys (OpenSSH reads the passwd home, not $HOME) — the supported route for a private repo; an https clone that
    # needs a credential helper does not authenticate.
    def clone_env(home, template, parent: ENV)
      { "PATH" => parent.fetch("PATH"), "HOME" => home, "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_TEMPLATE_DIR" => template, "GIT_LFS_SKIP_SMUDGE" => "1", "GIT_TERMINAL_PROMPT" => "0", }
        .merge(parent.to_h.slice("SSH_AUTH_SOCK", "LANG"))
    end

    # nil = trust it (the launcher answers the prompt), else why the prompt stays on screen. A clone is never trusted.
    def refusal(dir, trusted:, created:)
      real = File.realpath(dir)
      return nil if trusted.include?(real) || created.include?(real)

      "#{real} is not in config/busyyaks.yml launch.trusted_paths and was not made by the launcher's git init: " \
        "the trust prompt is left for you"
    end

    def inside?(path, dir) = path == dir || path.start_with?("#{dir.delete_suffix('/')}/")

    # the real path of a path that may not exist yet: its deepest existing ancestor resolved, the rest appended
    def resolve(path)
      p = Pathname.new(File.expand_path(path))
      rest = []
      until p.exist? || p.root?
        rest.unshift(p.basename.to_s)
        p = p.dirname
      end
      File.join(p.realpath.to_s, *rest).then { |s| s.length > 1 ? s.delete_suffix("/") : s }
    end
  end
end
