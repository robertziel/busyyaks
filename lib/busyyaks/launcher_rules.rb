# frozen_string_literal: true

require "fileutils"
require "pathname"

module Busyyaks
  # The checks bin/launcher (and deploy/install-launcher.sh) run on what a container or .env hands it, as functions it
  # calls (pure Ruby: the host launcher requires this file alone) so the suite tests them without a host tmux.
  module LauncherRules
    class Invalid < StandardError; end

    # The prompt values the engine sends (Launch.prepare's vars); {dir} is the launcher's own, never the request's.
    LAUNCH_VARS = %w[slug session agent type cards].freeze

    module_function

    # A container path under container_root → the repo dir's REAL path under projects_root (what tmux and the trust
    # check then use: a symlink swapped after this check is never followed). Refused: a path outside the root, an
    # empty / . / .. segment, a dir that is no git repo, and a symlink that leads out of projects_root.
    def host_dir(container_path, container_root:, projects_root:)
      rel = container_path.to_s.delete_prefix("#{container_root}/")
      raise ArgumentError, "path outside #{container_root}" if rel == container_path.to_s || rel.empty?
      raise ArgumentError, "bad path" if rel.split("/").any? { |seg| seg.empty? || seg == "." || seg == ".." }

      dir = File.join(projects_root, rel)
      raise ArgumentError, "not a git repo: #{dir}" unless File.directory?(dir) && File.exist?(File.join(dir, ".git"))

      real = File.realpath(dir)
      root = File.realpath(projects_root)
      raise ArgumentError, "#{dir} resolves to #{real}, outside #{root}" unless real.start_with?("#{root}/")

      real
    end

    # The type's prompt values: only the engine's keys from the request, {dir} last (the request cannot set it).
    def launch_vars(vars, dir:)
      raise ArgumentError, "vars must be an object" unless vars.is_a?(Hash)

      extra = vars.keys.map(&:to_s) - LAUNCH_VARS
      raise ArgumentError, "unknown vars #{extra.join(', ')} (allowed: #{LAUNCH_VARS.join(', ')})" if extra.any?

      vars.to_h { |k, v| [k.to_sym, v] }.merge(dir: dir)
    end

    # .env LAUNCHER_RUN_DIR → its real path, created 0700. Refused: a relative path; one under PROJECTS_ROOT (every
    # container mounts that, and a read-only mount does not stop connect() on a socket) or under the checkout (./data,
    # .env, the test service's .:/app); one that contains either; an existing one owned by another uid or open to group
    # / other (never repaired: what another user put there earlier would stay). A dir it cannot create → Invalid.
    def run_dir!(path, projects_root:, checkout:, uid:)
      raise Invalid, "LAUNCHER_RUN_DIR must be an absolute path (got #{path.inspect})" unless path.to_s.start_with?("/")

      real = resolve(path)
      # compose mounts the path AS WRITTEN and the launcher binds the real one: they must be the same path
      unless File.expand_path(path) == real
        raise Invalid, "LAUNCHER_RUN_DIR #{path} goes through a symlink (it is #{real}): write #{real}"
      end
      # ./data by its own real path too: a data dir symlinked out of the checkout is mounted by every container
      { "PROJECTS_ROOT" => projects_root, "the busyyaks checkout" => checkout,
        "./data" => File.join(checkout, "data"), }.each do |what, other|
        o = resolve(other)
        if inside?(real, o) || inside?(o, real)
          raise Invalid, "LAUNCHER_RUN_DIR #{path} (#{real}) overlaps #{what} (#{o}): every container mounts it, and " \
                         "a socket in it is reachable from all of them; put it outside both"
        end
      end
      parents!(real, uid)
      begin
        FileUtils.mkdir_p(real, mode: 0o700)
      rescue SystemCallError => e
        raise Invalid, "LAUNCHER_RUN_DIR #{real} cannot be created: #{e.message}"
      end
      st = File.stat(real)
      raise Invalid, "LAUNCHER_RUN_DIR #{real} is not a directory" unless st.directory?
      parent = File.stat(File.dirname(real))
      unless parent.uid == uid
        raise Invalid, "LAUNCHER_RUN_DIR #{real}: its parent #{File.dirname(real)} is owned by uid #{parent.uid}, not #{uid}"
      end
      unless st.uid == uid
        raise Invalid, "LAUNCHER_RUN_DIR #{real} is owned by uid #{st.uid}, not #{uid} (created by Docker before the " \
                       "launcher? remove it and run deploy/install-launcher.sh before compose starts)"
      end
      if st.mode.anybits?(0o077)
        raise Invalid, "LAUNCHER_RUN_DIR #{real} is mode #{format('%o', st.mode & 0o777)}: open to group / other; check " \
                       "what is in it, then chmod 700 #{real}"
      end

      real
    end

    # Every existing ancestor (up to /) is this uid's or root's and not writable by group / other — else another user
    # could swap a path component between the launcher's bind and compose's mount, or (a sticky /tmp too) create the
    # dir first while it is absent, after a reboot, so the containers mount theirs.
    def parents!(real, uid)
      dir = File.dirname(real)
      loop do
        if File.exist?(dir)
          st = File.lstat(dir)
          raise Invalid, "LAUNCHER_RUN_DIR #{real}: #{dir} is a symlink" if st.symlink?
          unless [uid, 0].include?(st.uid)
            raise Invalid, "LAUNCHER_RUN_DIR #{real}: its parent #{dir} is owned by uid #{st.uid}, not #{uid} or root"
          end
          if st.mode.anybits?(0o022)
            raise Invalid, "LAUNCHER_RUN_DIR #{real}: its parent #{dir} is writable by group / other " \
                           "(mode #{format('%o', st.mode & 0o7777)})"
          end
        end
        break if dir == "/"

        dir = File.dirname(dir)
      end
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
