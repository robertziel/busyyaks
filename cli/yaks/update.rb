# frozen_string_literal: true

require_relative "../../lib/busyyaks/updates"

module Busyyaks
  module CLI
    # `yaks update [--main] [--check]` (card 536): this checkout onto its newest release tag (or, --main, the head of
    # config/busyyaks.yml updates.branch), then the stack on the new code — the steps a deploy runs (docs/DEPLOY.md):
    #   check → back up the database → move the checkout (a fast-forward) → docker build → compose up --wait →
    #   deploy/install-launcher.sh → server status.
    # A failed build puts the checkout back where it was (the running stack never changed). A failure after the
    # services started on the new image is NOT undone: the database may be migrated — the record names the backup
    # and the previous commit. Every step is written to LAUNCHER_STATE_DIR/update.json (Settings → Updates reads it,
    # whether the update started there or here); one update at a time (a flock on update.lock).
    # The image is built under a tag of its own (busyyaks:update-<sha>) and becomes busyyaks:local only after the
    # backup, right before compose up: the backup is as fresh as it can be with the old stack still serving, and a
    # failed build or backup leaves busyyaks:local (what any later compose up starts) as it was.
    module Update
      IMAGE = "busyyaks:local" # docker-compose.yml's image of the stack's services

      module_function

      def run(ctx, args)
        mode = "tags"
        check_only = false
        json = false
        expect = nil
        log = nil
        CLI.parse!(OptionParser.new do |o|
          o.on("--main") { mode = "branch" }
          o.on("--check") { check_only = true }
          o.on("--json") { json = true }
          o.on("--expect SHA") { |v| expect = v }
          o.on("--log PATH") { |v| log = v }
        end, args)
        CLI.no_more!(args)
        raise Usage, "--expect must be a 40-hex commit sha" if expect && !expect.match?(Updates::SHA)
        raise Usage, "--json goes with --check" if json && !check_only

        settings = load_settings(ctx)
        git = git_for(ctx)
        return checked(ctx, Updates.check(settings, git: git, now: Clock.now), json: json) if check_only

        state = ctx.dotenv_values("LAUNCHER_STATE_DIR").fetch("LAUNCHER_STATE_DIR")
        raise Refused,
".env LAUNCHER_STATE_DIR #{state} is not a directory (the launcher makes it)" unless File.directory?(state)

        lock = Updates.lock(state) or raise Refused, "an update is already running (#{File.join(state, Updates::LOCK_FILE)})"
        begin
          Run.new(ctx, settings, git, state, mode: mode, expect: expect, log: log).run
        ensure
          lock.close
        end
      rescue Updates::Refused => e
        raise Refused, e.message
      end

      def load_settings(ctx)
        Updates.load!(ctx.home)
      rescue Updates::Invalid => e
        raise Refused, e.message
      end

      # git in this checkout, through the one Runner (argv, PATH lookup), each call under Updates::GIT_TIMEOUT_S (a
      # call past it: killed, Refused naming it) and with Updates::GIT_ENV (no terminal prompt, the repo-configured
      # programs switched off; the rest refused by Updates.preflight!)
      def git_for(ctx, timeout: Updates::GIT_TIMEOUT_S)
        lambda do |args|
          out, err, code = ctx.runner.capture_all("git", "-C", ctx.home, *args, env: Updates::GIT_ENV, timeout: timeout)
          [out, err, code.zero?]
        end
      end

      # --check: printed (a table, or --json: the check as JSON — what bin/launcher asks; the launcher itself never runs
      # git), and kept as LAUNCHER_STATE_DIR/update-check.json when .env names that dir and it exists (Settings →
      # Updates shows a check made here too)
      def checked(ctx, c, json:)
        state = ctx.dotenv["LAUNCHER_STATE_DIR"].to_s
        Updates.write_json!(state, Updates::CHECK_FILE, c) if !state.empty? && File.directory?(state)
        return show(ctx, c) unless json

        ctx.out.puts JSON.generate(c)
        0
      end

      def show(ctx, c)
        head = c[:head]
        rows = [["checkout", "#{head[:sha][0, 7]} #{head[:branch] ? "on #{head[:branch]}" : 'detached'} (#{head[:describe]})"],
                ["newest tag", c[:tag][:state] == "none" ? "none" : target_line(c[:tag])],
                ["#{c[:remote]}/#{c[:branch][:name]}", target_line(c[:branch])],]
        rows << ["changed files", c[:dirty].join(", ")] if c[:dirty].any?
        rows << ["not versions", c[:ignored_tags].join(", ")] if c[:ignored_tags].any?
        width = rows.map { |k, _| k.size }.max
        rows.each { |k, v| ctx.out.puts "#{k.ljust(width)}  #{v}" }
        ctx.out.puts(c[:available] ? "update available (channel #{c[:channel]})" : "up to date (channel #{c[:channel]})")
        0
      end

      def target_line(t)
        behind = t[:state] == "available" || t[:state] == "diverged" ? ", #{t[:behind]} commits" : ""
        "#{t[:name]} #{t[:sha][0, 7]} · #{t[:state]}#{behind}"
      end

      # one update, step by step; @rec is the record on disk
      class Run
        def initialize(ctx, settings, git, state, mode:, expect:, log:)
          @ctx = ctx
          @settings = settings
          @git = git
          @state = state
          @rec = { "state" => "running", "step" => "check", "mode" => mode, "started_at" => Clock.now.iso8601,
                   "log" => log, }
          @mode = mode
          @expect = expect
        end

        def run
          write_record
          target = Updates.target!(Updates.check(@settings, git: @git, now: Clock.now), @settings, mode: @mode,
                                                                                               expect: @expect)
          write_record("from" => target[:from], "to" => target[:sha], "name" => target[:name], "behind" => target[:behind])
          say "#{target[:from][0, 7]} → #{target[:name]} #{target[:sha][0, 7]} (#{target[:behind]} commits)"
          built = "busyyaks:update-#{target[:sha][0, 12]}"
          back = -> { Updates.back!(target, git: @git) }
          step("checkout") { Updates.move!(target, git: @git) }
          # the new version's secrets in .env (one it added is written, nothing set is touched) — before the backup, whose
          # `docker compose` already reads the new compose file (a `${KEY:?}` it requires)
          step("setup", undo: back) { run!("bin/setup secrets", File.join(@ctx.home, "bin", "setup"), "secrets") }
          step("build", undo: back) { run!("docker build", "docker", "build", "-t", built, @ctx.home) }
          # the image the running stack started from, named before anything replaces it (and a failed inspect is undone
          # like the backup: the checkout back, nothing tagged)
          step("backup", undo: back) do
            write_record("previous_image" => image_id)
            write_record("backup" => backup)
          end
          step("up") do
            run!("docker tag", "docker", "tag", built, IMAGE)
            run!("docker compose up", *@ctx.compose("up", "-d", "--wait", "--no-build", *SERVICES))
          end
          step("launcher") { run!("deploy/install-launcher.sh", File.join(@ctx.home, "deploy", "install-launcher.sh")) }
          step("status") { Server.status(@ctx).zero? or raise Refused, "yaks server status: a check failed (above)" }
          write_record("state" => "done", "step" => nil, "done_at" => Clock.now.iso8601)
          say "updated to #{target[:name]} #{target[:sha][0, 7]}"
          0
        rescue Updates::Refused, Refused => e
          fail!(e.message)
        rescue StandardError => e
          # anything else (a full disk, a killed git) is a failure too, recorded — never a "running" left behind
          fail!("#{@rec['step']}: #{e.class}: #{e.message}")
        end

        private

        # a failed step: its undo runs (the build: the checkout back), then the refusal goes up with what is in place
        def step(name, undo: nil)
          write_record("step" => name)
          say "== #{name}"
          yield
        rescue StandardError => e
          why = e.is_a?(Updates::Refused) || e.is_a?(Refused) ? e.message : "#{e.class}: #{e.message}"
          raise Refused, "#{name}: #{why}" unless undo

          begin
            undo.call
          rescue StandardError => back
            raise Refused, "#{name}: #{why} — and putting the checkout back failed: #{back.message}"
          end
          raise Refused, "#{name}: #{why} — the checkout is back on #{@rec['from'][0, 7]}, the stack unchanged"
        end

        def run!(what, *argv)
          @ctx.runner.system(*argv) or raise Refused, "#{what} failed"
        end

        # the image busyyaks:local is now (the one the running stack started from), before the tag moves it: the record
        # names it, so going back after a failed up is `docker tag <it> busyyaks:local`
        def image_id
          out, ok = @ctx.runner.capture("docker", "image", "inspect", "-f", "{{.Id}}", IMAGE)
          id = out.to_s.strip
          raise Refused, "docker image inspect #{IMAGE} failed: no image to come back to" unless ok && !id.empty?

          id
        end

        # The database before anything changes (docs/DEPLOY.md § The database) → the backup's host path
        def backup
          adapter = @ctx.dotenv_values("DATABASE_ADAPTER").fetch("DATABASE_ADAPTER")
          stamp = Clock.now.utc.strftime("%Y%m%dT%H%M%SZ")
          dir = File.join(@ctx.home, "data", "backups")
          FileUtils.mkdir_p(dir)
          case adapter
          when "sqlite"
            name = "busyyaks-update-#{stamp}.sqlite3"
            run!("the SQLite backup (VACUUM INTO)",
                 *@ctx.compose("exec", "-T", "web", "sqlite3", "/data/busyyaks.sqlite3", "VACUUM INTO '/data/backups/#{name}'"))
            File.join(dir, name)
          when "postgresql"
            file = File.join(dir, "busyyaks-update-#{stamp}.pgdump")
            dump = 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump -h /var/run/postgresql -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"'
            ok = File.open(file, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
              pid = @ctx.runner.spawn(*@ctx.compose("exec", "-T", "postgres", "sh", "-c", dump), out: f, err: @ctx.err)
              Process.wait2(pid).last.success?
            end
            raise Refused, "pg_dump failed (#{file} left for a look)" unless ok && File.size(file).positive?

            file
          else raise Refused, ".env DATABASE_ADAPTER #{adapter.inspect} is neither sqlite nor postgresql"
          end
        end

        def fail!(why)
          after = %w[up launcher status].include?(@rec["step"])
          why += " — the services may run the new code on a migrated database: backup #{@rec['backup']}, " \
                 "previous commit #{@rec['from']}, previous image #{@rec['previous_image'] || 'unknown'}" if after
          write_record("state" => "failed", "error" => why, "done_at" => Clock.now.iso8601)
          @ctx.err.puts "yaks: update failed: #{why}"
          1
        end

        def write_record(fields = {})
          @rec = @rec.merge(fields)
          Updates.write_json!(@state, Updates::RECORD_FILE, @rec)
        end

        def say(line) = @ctx.out.puts(line)
      end
    end
  end
end
