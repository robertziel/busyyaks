# frozen_string_literal: true

module Busyyaks
  # All reads/writes, over the Sequel connection hanami-db already holds.
  class Store
    def self.default = new(Hanami.app["db.gateway"].connection)

    attr_reader :db

    def initialize(db, clock: -> { Time.now.to_i })
      @db = db
      @clock = clock
    end

    # --- scans
    def scan_started(at) = @db[:scans].insert(started_at: at)

    def scan_finished(id, at, repos, error)
      @db[:scans].where(id: id).update(finished_at: at, repos: repos, error: error)
    end

    # the last scan that FINISHED: a scan in progress has no result yet, and reporting its start as
    # "scanned Ns ago" claimed fresh data the page did not have
    def last_scan = @db[:scans].exclude(finished_at: nil).order(Sequel.desc(:id)).first

    # What GET /api/today shows that the scanner / reports change: every repo's state but the scan time,
    # the commits table's size + newest row, the reports. The page re-reads /api/today only when this changes.
    def today_rev_parts
      cols = %i[slug branch remote pr_remote own present last_commit_at commits_window mine_window dirty unpushed]
      [@db[:projects].order(:slug).select_map(cols),
       @db[:commits].get { [count.function.*.as(:n), max(:id).as(:newest)] },
       @db[:reports].get { [count.function.*.as(:n), max(:id).as(:newest)] },]
    end

    # --- projects
    def upsert_project(attrs)
      attrs = attrs.merge(present: true)
      ds = @db[:projects].where(slug: attrs[:slug])
      ds.update(attrs).zero? && @db[:projects].insert(attrs)
    end

    # a repo the scanner could not read: its last good row stays, with why (nothing to keep = no row: the scan's
    # error says it)
    def project_git_failed(slug, error)
      @db[:projects].where(slug: slug).update(git_error: error.to_s[0, 2000], present: true)
    end

    # the listed project whose checkout holds this path (the path itself or a dir inside it), the deepest one
    def project_at(path)
      path = path.to_s
      @db[:projects].where(present: true).all.select { |p| path == p[:path] || path.start_with?("#{p[:path]}/") }
                    .max_by { |p| p[:path].size }
    end

    def mark_absent(except:)
      @db[:projects].exclude(slug: except).update(present: false)
    end

    def projects(own: nil)
      ds = @db[:projects].where(present: true)
      ds = ds.where(own: own) unless own.nil?
      ds.order(Sequel.desc(Sequel.function(:coalesce, :last_commit_at, 0))).all
    end

    def project(slug) = @db[:projects].where(slug: slug).first

    # --- commits
    def replace_commits(slug, commits, since)
      @db.transaction do
        @db[:commits].where(project_slug: slug).where { committed_at < since }.delete
        commits.each do |c|
          @db[:commits].insert_conflict(target: %i[project_slug sha], update: { subject: c[:subject] })
                       .insert(c.merge(project_slug: slug))
        end
      end
    end

    def commits(slug: nil, since: nil, limit: 200)
      ds = @db[:commits]
      ds = ds.where(project_slug: slug) if slug
      ds = ds.where { committed_at >= since } if since
      ds.order(Sequel.desc(:committed_at)).limit(limit).all
    end

    # Per-project commit counts since a timestamp: [{project_slug:, commits:, mine:}]
    def activity_since(since)
      @db[:commits].where { committed_at >= since }
                   .group_and_count(:project_slug)
                   .select_append { sum(Sequel.case({ { mine: true } => 1 }, 0)).as(:mine) }
                   .order(Sequel.desc(:count)).all
                   .map { |r| { project_slug: r[:project_slug], commits: r[:count], mine: r[:mine].to_i } }
    end

    # --- daily (contribution graph)
    def replace_daily(slug, days)
      @db.transaction do
        @db[:daily].where(project_slug: slug).delete
        @db[:daily].multi_insert(days.map { |day, (c, m)| { project_slug: slug, day: day, commits: c, mine: m } })
      end
    end

    # {"YYYY-MM-DD" => commits}, one repo or all; mine_only counts the operator's commits.
    def daily(slug: nil, mine_only: false)
      ds = @db[:daily]
      ds = ds.where(project_slug: slug) if slug
      col = mine_only ? :mine : :commits
      ds.group(:day).select(:day) { sum(col).as(:n) }.all.to_h { |r| [r[:day], r[:n].to_i] }
    end

    def commits_by_sha(shas)
      return {} if shas.empty?

      @db[:commits].where(Sequel.function(:substr, :sha, 1, 7) => shas.map { |s| s[0, 7] }.uniq).all
                   .each_with_object({}) { |c, acc| shas.each { |s| acc[s] ||= c if c[:sha].start_with?(s) } }
    end

    def find_commit(prefix)
      @db[:commits].where(Sequel.like(:sha, "#{prefix}%")).order(Sequel.desc(:committed_at)).first
    end

    def neighbours(report)
      at = report[:created_at]
      rid = report[:id]
      older = @db[:reports].where { (created_at < at) | ((created_at =~ at) & (id < rid)) }
                           .order(Sequel.desc(:created_at), Sequel.desc(:id)).first
      newer = @db[:reports].where { (created_at > at) | ((created_at =~ at) & (id > rid)) }
                           .order(:created_at, :id).first
      [older, newer]
    end

    # --- reports
    def add_report(date:, title:, body_md:, author:)
      @db[:reports].insert(date: date, title: title, body_md: body_md, author: author, created_at: @clock.call)
    end

    def reports(limit: 50, date: nil)
      ds = @db[:reports]
      ds = ds.where(date: date) if date
      ds.order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(limit).all
    end

    def report(id) = @db[:reports].where(id: id).first

    # --- agents sidebar: when the operator last saw each session (herdr's "done" = a turn ended after that)
    # keys: the live sessions' keys; attached: the keys whose tmux session is attached now (= being looked at).
    # A key seen for the first time is recorded as seen now. → {key => seen_at}
    def agent_seen(keys, attached: [], now: Time.now.to_f)
      known = @db[:agent_seen].where(key: keys).select_hash(:key, :seen_at)
      ((keys - known.keys) | attached).each do |k|
        agent_seen!(k, now: now)
        known[k] = now
      end
      known
    end

    # an upsert on the key, the same SQL on SQLite and PostgreSQL (INSERT … ON CONFLICT (key) DO UPDATE)
    def agent_seen!(key, now: Time.now.to_f)
      @db[:agent_seen].insert_conflict(target: :key, update: { seen_at: Sequel[:excluded][:seen_at] })
                      .insert(key: key, seen_at: now)
    end

    # --- notes
    def add_note(body:, author:, project_slug: nil)
      @db[:notes].insert(project_slug: project_slug, body: body, author: author, created_at: @clock.call)
    end

    def notes(project_slug: :any, limit: 100)
      ds = @db[:notes]
      ds = ds.where(project_slug: project_slug) unless project_slug == :any
      ds.order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(limit).all
    end
  end
end
