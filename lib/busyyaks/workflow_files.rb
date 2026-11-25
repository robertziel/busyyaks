# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "yaml"
require_relative "clock"
require_relative "git_read"
require_relative "runtime_settings"
require_relative "agent_rule_files"
require_relative "skill_files"

module Busyyaks
  # A project's workflow — its board's columns (key, label, type, fold-after hours) and named transitions — lives in
  # the repo itself: `<repo>/.busyyaks/workflow.yml` (card #429), git-ignored (never committed, so never public). The
  # file is the source; the engine's boards tables are its validated copy, written by the writer service
  # (bin/writer, the only container with the projects mounted read-write) and by nothing else that edits a shape.
  #
  # The writer's sync, per project, every writer_sync_seconds:
  # - no file → the board the engine holds (the template's copy for a new project) is written into it;
  # - a file whose bytes differ from the ones last applied → applied to the board (the engine validates it and refuses
  #   to drop a column that holds cards); refused → `workflow_files.error`, shown on the board, retried every pass;
  # - the bytes last applied, but the engine's board differs (a host migration reshaped the stored boards) → the board
  #   written into the file again.
  # The workflow editor's Save / Reset go through the writer too (WriterClient): the engine saves and the file is
  # written in one database transaction — a file that cannot be written rolls the save back.
  #
  # Git-ignored, always: before writing, `/.busyyaks/workflow.yml` is added to the repo's own `.git/info/exclude`
  # (local, never committed — no tracked file of the repo changes; card #477: only the file, so a repo commits its
  # `.busyyaks/skills` — lib/busyyaks/skills.rb — and an older `/.busyyaks/` line is replaced); a file git would
  # still track (a `.gitignore` negation, or one already committed) is refused, read and written alike, and an
  # applied file is checked again whenever the repo's index, .gitignore or info/exclude changed (committed later →
  # refused at the next pass) — through a GitRead child (libgit2).
  module WorkflowFiles
    DIR = ".busyyaks"
    FILE = "workflow.yml"
    REL = "#{DIR}/#{FILE}".freeze
    EXCLUDE = "/#{REL}".freeze
    OLD_EXCLUDE = "/#{DIR}/".freeze # before card #477: the whole dir, which hid a repo's .busyyaks/skills from git
    MAX_BYTES = 256 * 1024
    AUTHOR = REL # who a board read from the file is recorded as (boards.updated_by)
    KEYS = %w[columns transitions].freeze
    HEADER = <<~TXT
      # busyyaks workflow of this repo: the board's columns (board order) and its named transitions.
      # Kept out of git (.git/info/exclude). Edit it here or with the board's Workflow editor; the writer service
      # applies a change within writer_sync_seconds and shows a refusal on the board.
    TXT

    class Refused < StandardError; end
    # the file changed on disk since it was applied: an editor save would overwrite it
    class Conflict < StandardError; end

    module_function

    def path(project) = File.join(project.fetch(:path), REL)

    # The file's bytes or nil (none). Refused when the dir or the file is a symlink, not a regular file, or too big.
    def read_bytes(project)
      dir = File.join(project.fetch(:path), DIR)
      return nil unless File.exist?(dir) || File.symlink?(dir)
      raise Refused, "#{DIR} is a symlink: not read" if File.symlink?(dir)
      raise Refused, "#{DIR} is not a directory" unless File.directory?(dir)

      file = File.join(dir, FILE)
      return nil unless File.exist?(file) || File.symlink?(file)
      raise Refused, "#{REL} is a symlink: not read" if File.symlink?(file)
      raise Refused, "#{REL} is not a regular file" unless File.file?(file)
      raise Refused, "#{REL} is over #{MAX_BYTES} bytes" if File.size(file) > MAX_BYTES

      File.binread(file)
    end

    # bytes → {"columns" => […], "transitions" => […]} (the Board hash the engine validates). Refused: not YAML, not a
    # mapping, other keys.
    def parse(bytes)
      doc = YAML.safe_load(bytes.dup.force_encoding("UTF-8"), aliases: false, filename: REL)
      raise Refused, "#{REL} is not a mapping with #{KEYS.join(' + ')}" unless doc.is_a?(Hash)

      extra = doc.keys - KEYS
      missing = KEYS - doc.keys
      raise Refused, "#{REL}: unknown key#{'s' if extra.size > 1} #{extra.join(', ')}" if extra.any?
      raise Refused, "#{REL}: missing #{missing.join(', ')}" if missing.any?

      doc
    rescue Psych::Exception => e
      raise Refused, "#{REL} is not valid YAML: #{e.message}"
    end

    # A Board hash → the file's text (columns as written by the engine: key, label, type, hide_after_hours).
    def dump(board_hash)
      doc = { "columns" => board_hash.fetch("columns"), "transitions" => board_hash.fetch("transitions") }
      HEADER + JSON.parse(JSON.generate(doc)).to_yaml.delete_prefix("---\n")
    end

    def sha(bytes) = Digest::SHA256.hexdigest(bytes)

    # Refused unless git ignores the file and does not track it (GitRead op `ignored`). libgit2 answers "ignored" for a
    # path the repo's .gitignore re-includes with a `!` rule over .git/info/exclude (git itself then shows it as new), so
    # any negation in the top .gitignore that could name the dir or the file is refused as well.
    def ignored!(project, root: GitRead.mount)
      r = GitRead.call("ignored", path: project.fetch(:path), root: root, file: REL)
      raise Refused, "#{REL} is tracked by git: it must stay local (git rm --cached it)" if r["tracked"]
      raise Refused, "#{REL} is not ignored by git" unless r["ignored"]

      rule = negation(project) and raise Refused, ".gitignore's #{rule.inspect} would un-ignore #{REL}: not written"
    end

    # What decides git's answer for the file: the index (what is tracked), the top .gitignore and .git/info/exclude.
    # → [[path, size, mtime_ns] or nil, …]. The writer re-asks git (a GitRead child) only when this changed, so a file
    # committed after it was applied is refused at the next pass, with no git-read child per project per pass.
    def git_view(project)
      root = project.fetch(:path)
      [".git/index", ".gitignore", ".git/info/exclude"].map do |rel|
        st = File.lstat(File.join(root, rel))
        [rel, st.size, st.mtime.to_r]
      rescue Errno::ENOENT
        nil
      end
    end

    NAMES = [DIR, REL, FILE].freeze
    FNM = File::FNM_DOTMATCH | File::FNM_PATHNAME

    # the first `!` rule of <repo>/.gitignore that matches .busyyaks, .busyyaks/workflow.yml or workflow.yml, or nil
    def negation(project)
      gi = File.join(project.fetch(:path), ".gitignore")
      return nil unless File.file?(gi) && !File.symlink?(gi)
      raise Refused, ".gitignore is over #{MAX_BYTES} bytes" if File.size(gi) > MAX_BYTES

      File.read(gi).each_line.map(&:strip).find do |l|
        next false unless l.start_with?("!")

        pat = l.delete_prefix("!").delete_prefix("/").delete_suffix("/")
        NAMES.any? { |n| File.fnmatch?(pat, n, FNM) || File.fnmatch?("**/#{pat}", n, FNM) }
      end
    end

    # `/.busyyaks/workflow.yml` in the repo's .git/info/exclude (added once, at the end; an old `/.busyyaks/` line
    # removed). Only a repo whose .git is a directory.
    def exclude!(project)
      git = File.join(project.fetch(:path), ".git")
      raise Refused, ".git is not a directory (a linked checkout or a submodule): no exclude file to write" if
        File.symlink?(git) || !File.directory?(git)

      info = File.join(git, "info")
      raise Refused, ".git/info is a symlink: not written" if File.symlink?(info)

      FileUtils.mkdir_p(info)
      file = File.join(info, "exclude")
      raise Refused, ".git/info/exclude is a symlink: not written" if File.symlink?(file)

      # read and compared as BYTES: the file is the user's, and any byte that is not UTF-8 is kept as it is (a String#strip
      # of such a line raised, and stopped the writer's sync pass at that repo every turn)
      body = File.exist?(file) ? File.binread(file) : "".b
      lines = body.lines.map(&:strip)
      return if lines.include?(EXCLUDE.b) && !lines.include?(OLD_EXCLUDE.b)

      body = body.lines.reject { |l| l.strip == OLD_EXCLUDE.b }.join.b
      return File.binwrite(file, body) if lines.include?(EXCLUDE.b)

      File.binwrite(file, body + ("\n" unless body.empty? || body.end_with?("\n")).to_s.b + "#{EXCLUDE}\n".b)
    end

    # Write the text atomically (a temp file in the dir, renamed over the file) — only over the bytes the caller last
    # saw (`expected` = their sha, nil = no file): anything else on disk is a hand edit made meanwhile → Conflict, the
    # file left as it is. → the written bytes' sha.
    def write!(project, text, expected:)
      exclude!(project)
      dir = File.join(project.fetch(:path), DIR)
      raise Refused, "#{DIR} is a symlink: not written" if File.symlink?(dir)

      FileUtils.mkdir_p(dir)
      target = File.join(dir, FILE)
      raise Refused, "#{REL} is a symlink: not written" if File.symlink?(target)

      tmp = File.join(dir, ".#{FILE}.#{Process.pid}.tmp")
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o644) do |f|
        f.write(text)
        f.fsync
      end
      now = read_bytes(project)
      raise Conflict, "#{REL} changed on disk during the write: not overwritten" unless (now && sha(now)) == expected

      File.rename(tmp, target)
      sha(text.b)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end

    # What the board shows of the project's file: its host path, the last apply, the refusal, the writer's last look.
    def state(db, project, now: Clock.epoch, interval: RuntimeSettings.get(db)[:writer_sync_seconds])
      row = status(db, project[:slug])
      iso = ->(t) { t && Time.at(t).utc.iso8601 }
      host = on_host(path(project))
      return { file: REL, path: host, applied_at: nil, error: "the writer has not read #{REL} yet", error_at: nil,
               checked_at: nil, stale: true, } unless row

      { file: REL, path: host, applied_at: iso.(row[:applied_at]), error: row[:error], error_at: iso.(row[:error_at]),
        checked_at: iso.(row[:checked_at]), stale: now - row[:checked_at] > 3 * interval, }
    end

    def on_host(container_path)
      mount = GitRead.mount.chomp("/")
      return container_path unless container_path.start_with?("#{mount}/")

      File.join(GitRead.host_root, container_path.delete_prefix(mount))
    end

    # The status row the board shows: {path, applied_sha, applied_at, error, error_at, checked_at} or nil.
    def status(db, slug) = db[:workflow_files].where(project_slug: slug.to_s).first

    # The writer: the sync pass and the editor's saves, one at a time (a Mutex: the socket thread and the sync loop).
    class Writer
      # store: -> { a fresh kanban Store } (each call reads the current agent settings revision); api: ->(store) { Api }
      # skills: -> { config/busyyaks.yml `skills` (Skills::Settings) }: the limits a project's agent rule files are
      # written within (agent_rules)
      # checkout: this busyyaks checkout (its skills/busyyaks + skills.local_dir: the layers a project's own layer is
      # read after — and checked against — on a save, as a launch reads them)
      # own_skills: this busyyaks checkout's skills/ dir as mounted here read-only (compose: ./skills), nil = none — what
      # identifies the checkout among the scanned repos (skills_save)
      def initialize(db:, store:, api:, skills:, checkout:, root: GitRead.mount, clock: -> { Clock.epoch },
                     log: ->(_) {}, own_skills: nil)
        @db = db
        @store = store
        @api = api
        @skills = skills
        @checkout = checkout
        @own_skills = own_skills
        @root = root
        @clock = clock
        @log = log
        @lock = Mutex.new
        @views = {} # slug → the git_view git last said ignores the file (memory only: a restart asks again)
      end

      # Every project in the projects table. → {slug => "exported" | "applied" | "unchanged" | "refused: …"}
      # a project whose repo the scanner no longer finds (present: false) is left alone: nothing to read or write
      # one repo's failure never stops the pass: it is recorded on that repo (its board says so) and the next is synced
      def sync_all
        @db[:projects].where(present: true).order(:slug).all.to_h do |p|
          [p[:slug], begin
            sync(p)
          rescue StandardError => e
            @lock.synchronize { refused(p, "#{e.class}: #{e.message}") }
          end,]
        end
      end

      def sync(project)
        @lock.synchronize { sync_one(project, @store.call) }
      end

      # The editor's Save: the engine saves, then the file is written, in one transaction. → [status, body]
      def save(slug, board, by:) = change(slug) { |st| @api.call(st).board_shape_save(slug, board, by: by) }

      # The editor's Reset to template, the same way.
      def reset(slug, by:) = change(slug) { |st| @api.call(st).board_shape_reset(slug, by: by) }

      # The project page's Settings tab's Save: any file of the repo's own .busyyaks/skills (agents/<type>.md, on-demand
      # skills and their reference files: AgentRuleFiles.write!) — the layer as it would be after the save read the way
      # a launch reads it, against busyyaks's own layers of this checkout (Skills.busyyaks! + project + select +
      # check_selection! for every agent type: the override rule, frontmatter, sizes, max_start_bytes), then written.
      # → [status, body]: 200 {written: [paths]} · 404 · 409 a file changed on disk since the editor read it · 422 refused
      def agent_rules(slug, files, by:)
        @lock.synchronize do
          project = @db[:projects].where(slug: slug.to_s).first or return [404, { error: "no project #{slug}" }]
          types = @store.call.config.agent_type_keys
          settings = @skills.call
          own = Skills.busyyaks!(@checkout, types: types, settings: settings)
          check = lambda do |repo|
            layer = Skills.project(repo, types: types, settings: settings)
            types.each { |t| Skills.check_selection!(Skills.select(own + [layer].compact, t), settings) }
          end
          # the old `/.busyyaks/` exclude line would hide the files written here from git: replaced first
          WorkflowFiles.exclude!(project)
          written = AgentRuleFiles.write!(project, files, types: types, settings: settings, check: check)
          written.each { |f| @log.call("#{project[:slug]}: #{AgentRuleFiles.rel(f)} #{by_word(project, f)} (#{by})") }
          [200, { written: written }]
        end
      rescue AgentRuleFiles::Conflict => e
        [409, { error: "#{e.message} — load the newest, then save again" }]
      rescue AgentRuleFiles::Refused => e
        [422, { error: e.message }]
      rescue Refused => e
        [422, { error: "not written: #{e.message}" }]
      rescue Skills::Invalid => e
        [422, { error: "not written: busyyaks's own skills cannot be read (#{e.message})" }]
      end

      def by_word(project, path) = File.exist?(File.join(project[:path], AgentRuleFiles.rel(path))) ? "written" : "removed"

      # Settings → Agent rules' Save: busyyaks's own skills files (SkillFiles.write!: the launch's checks on the tree as
      # it would be — and on every scanned project's launch with it — then written). The checkout is never the client's
      # word: it is the scanned repo whose skills/ dir IS the one this writer was started with (own_skills: the
      # checkout's ./skills mounted read-only — the same directory, by device and inode); a clone or fork carrying the
      # same files is another directory and never written. None found (the checkout is not under PROJECTS_ROOT) →
      # refused, saying so. → [status, body]: 200 {written: [paths]} · 409 a file changed on disk since the editor read
      # it · 422 refused
      def skills_save(files, by:)
        @lock.synchronize do
          checkout, why = own_checkout
          return [422, { error: "not written: #{why}" }] unless checkout

          projects = @db[:projects].where(present: true).order(:slug).select(:slug, :path).all
          written = SkillFiles.write!(checkout, files, types: @store.call.config.agent_type_keys, settings: @skills.call,
                                                       projects: projects)
          written.each { |f| @log.call("busyyaks skills: #{f} written (#{by})") }
          [200, { written: written }]
        end
      rescue SkillFiles::Conflict => e
        [409, { error: "#{e.message} — load the newest, then save again" }]
      rescue SkillFiles::Refused => e
        [422, { error: e.message }]
      end

      # → [the scanned repo that is this busyyaks checkout, nil] or [nil, why there is none]
      def own_checkout
        return [nil, "this writer has no busyyaks checkout to write (own_skills is not set)"] unless @own_skills

        mine = File.stat(@own_skills)
        rows = @db[:projects].where(present: true).select(:path).map { |r| r[:path] }
        hit = rows.find do |path|
          st = File.stat(File.join(path, "skills"))
          st.dev == mine.dev && st.ino == mine.ino
        rescue SystemCallError
          false
        end
        return [hit, nil] if hit

        why = "the busyyaks checkout is not a repo the scanner found under PROJECTS_ROOT (no scanned repo's skills/ is " \
              "the checkout's own): the writer cannot reach it — edit the files in the checkout and commit them, or " \
              "move the checkout under PROJECTS_ROOT"
        [nil, why]
      rescue SystemCallError => e
        [nil, "the busyyaks checkout's skills/ cannot be read here (#{e.message}): its read-only mount is missing"]
      end

      private

      def change(slug)
        @lock.synchronize do
          project = @db[:projects].where(slug: slug.to_s).first or return [404, { error: "no project #{slug}" }]
          st = @store.call
          before = sync_one(project, st)
          if before == "applied"
            return [409, { error: "#{REL} changed on disk and was applied — reload the editor" }]
          end
          return [409, { error: "#{REL} changed on disk while read (the next look applies it) — reload" }] if
            before == "changed"
          if before.start_with?("refused")
            why = before.delete_prefix("refused: ")
            msg = "not saved: #{REL} on disk is refused (#{why}) — fix it, or delete it (the writer then writes the " \
                  "board into it), and save again"
            return [422, { error: msg }]
          end

          out = nil
          failed = transact(project) do
            out = yield(st)
            raise Sequel::Rollback unless out[0] == 200

            put(project, st.board_of(project[:slug]), expected: WorkflowFiles.status(@db, project[:slug])[:applied_sha])
          end
          failed || out
        end
      rescue Conflict => e
        [409, { error: "#{e.message} — reload the editor" }]
      rescue Refused, SystemCallError, GitRead::Failed => e
        [422, { error: "#{REL}: #{e.message}" }]
      end

      # The tables and the file together, or neither: the file is renamed inside the transaction, so any failure after
      # the rename (the row, the log, the COMMIT) puts the bytes from before back — only over the bytes this save wrote
      # (a hand edit made meanwhile is kept, and applied by the next look). → nil, or the failure's [status, body].
      def transact(project)
        old = WorkflowFiles.read_bytes(project)
        @written = nil
        @db.transaction { yield }
        nil
      rescue StandardError => e
        raise unless @written # nothing renamed: the error is the save's own (Conflict, Refused, …)

        begin
          raise Refused, "there was no file before" if old.nil?

          WorkflowFiles.write!(project, old, expected: @written)
        rescue Conflict
          why = "not saved: #{e.message} (#{REL} changed on disk meanwhile: kept, applied on the writer's next look) " \
                "— reload the editor"
          return [500, { error: why }]
        rescue Refused, SystemCallError => r
          why = "not saved (#{e.class}) and #{REL} could not be put back (#{r.message}): the writer applies the file " \
                "on its next look — reload the editor"
          return [504, { error: why }]
        end
        [500, { error: "not saved: #{e.message} (#{REL} put back as it was)" }]
      end

      def sync_one(project, st)
        # every pass, not only when the file is written: a repo still holding the old `/.busyyaks/` line (it hid the
        # repo's committed .busyyaks/skills from git) gets it replaced even while its workflow.yml never changes
        WorkflowFiles.exclude!(project)
        bytes = WorkflowFiles.read_bytes(project)
        row = WorkflowFiles.status(@db, project[:slug])
        if bytes.nil?
          put(project, st.board_of(project[:slug]), expected: nil)
          return "exported"
        end

        sha = WorkflowFiles.sha(bytes)
        if row && row[:applied_sha] == sha
          board = st.board_of(project[:slug])
          if board.to_h == normal(WorkflowFiles.parse(bytes), st)
            ignored!(project) # committed after it was applied, or a new `!` rule: refused, the board keeps its shape
            return checked(project)
          end

          put(project, board, expected: sha) # the stored board moved (a migration): the file follows
          return "exported"
        end

        WorkflowFiles.exclude!(project) # a hand-made file in a repo the writer never wrote to: the rule first
        ignored!(project, fresh: true)
        status, body = @api.call(st).board_shape_save(project[:slug], WorkflowFiles.parse(bytes), by: AUTHOR)
        raise Refused, body[:error] unless status == 200

        record(project, applied_sha: sha, applied_at: @clock.call, error: nil, error_at: nil)
        @log.call("#{project[:slug]}: #{REL} applied")
        "applied"
      rescue Conflict
        "changed" # a hand edit landed while writing: the next pass applies it
      rescue Refused, SystemCallError, GitRead::Failed, AgentsKanban::Invalid => e
        refused(project, e.message)
      end

      # the engine's own form of a hash (defaults filled in), to compare with the stored board
      def normal(hash, st) = AgentsKanban::Board.new(hash, host: st.config).to_h

      def put(project, board, expected:)
        WorkflowFiles.exclude!(project) # the rule first, then git's own answer, then the file
        ignored!(project, fresh: true)
        sha = @written = WorkflowFiles.write!(project, WorkflowFiles.dump(board.to_h), expected: expected)
        record(project, applied_sha: sha, applied_at: @clock.call, error: nil, error_at: nil)
        @log.call("#{project[:slug]}: #{REL} written")
      end

      # git's answer (WorkflowFiles.ignored!), asked again only when the repo's git_view moved since git last said yes —
      # always when `fresh` (before every write or apply)
      def ignored!(project, fresh: false)
        view = WorkflowFiles.git_view(project)
        return if !fresh && @views[project[:slug]] == view

        @views.delete(project[:slug])
        WorkflowFiles.ignored!(project, root: @root)
        @views[project[:slug]] = view
      end

      def checked(project)
        record(project, error: nil, error_at: nil)
        "unchanged"
      end

      def refused(project, why)
        row = WorkflowFiles.status(@db, project[:slug])
        @log.call("#{project[:slug]}: #{REL} refused: #{why}") unless row && row[:error] == why
        record(project, error: why, error_at: row && row[:error] == why ? row[:error_at] : @clock.call)
        "refused: #{why}"
      end

      def record(project, **fields)
        now = @clock.call
        vals = { path: WorkflowFiles.path(project), checked_at: now, **fields }
        ds = @db[:workflow_files].where(project_slug: project[:slug])
        return if ds.update(vals) == 1

        @db[:workflow_files].insert({ project_slug: project[:slug], applied_sha: nil, applied_at: nil, error: nil,
                                      error_at: nil, }.merge(vals))
      end
    end

    # The writer's socket side: one JSON line in ({op: workflow_save | workflow_reset | agent_rules_save, slug, board? /
    # files?, by}), one out
    # ({status, body}). bin/writer runs it; the tests run it on a thread.
    class Server
      def initialize(writer, socket)
        @writer = writer
        @socket = socket
      end

      # Accept forever on a thread of its own, one thread per client. → the thread
      def start
        Thread.new do
          loop do
            client = @socket.accept
            Thread.new(client) { |c| serve(c) }
          end
        rescue IOError, Errno::EBADF
          nil # the socket was closed: the server stops
        end
      end

      def serve(client)
        client.puts(handle(client.gets.to_s))
      ensure
        client.close
      end

      # a request line → the answer line
      def handle(line)
        req = JSON.parse(line)
        status, body = req.is_a?(Hash) ? answer(req) : [400, { error: "the request is not an object" }]
        JSON.generate(status: status, body: body)
      rescue JSON::ParserError => e
        JSON.generate(status: 400, body: { error: "not JSON: #{e.message}" })
      rescue StandardError => e
        warn "writer: request failed: #{e.class}: #{e.message}"
        JSON.generate(status: 500, body: { error: "writer: #{e.class}: #{e.message}" })
      end

      private

      def answer(req)
        case req["op"]
        when "workflow_save" then @writer.save(req.fetch("slug"), req.fetch("board"), by: req.fetch("by"))
        when "workflow_reset" then @writer.reset(req.fetch("slug"), by: req.fetch("by"))
        when "agent_rules_save" then @writer.agent_rules(req.fetch("slug"), req.fetch("files"), by: req.fetch("by"))
        when "skills_save" then @writer.skills_save(req.fetch("files"), by: req.fetch("by"))
        else [400, { error: "unknown op #{req['op'].inspect}" }]
        end
      rescue KeyError => e
        [400, { error: e.message }]
      end
    end
  end
end
