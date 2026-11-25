# frozen_string_literal: true

require "time"
require_relative "github_network"
require_relative "github"
require_relative "github_hook"
require_relative "clock"
require_relative "git_hosts"

module Busyyaks
  # The flags on a card's PR links: which repo the PR is in (local · public, from the project's
  # private local-repo enrolment, Scanner#enrolment) and its state (open · draft · merged · closed).
  #
  # The GitHub token lives only in the `github` compose service, so the work is split over gh_pr_states, like CiChecks:
  #   Reader  (web, notifier) — asks for the PRs a card dialog shows and, on every notifier watch pass, every PR
  #                       assigned to a live card (CiChecks::Port#closed_prs: the engine's PR watch); reads the answers.
  #                       No token, no HTTP.
  #   Poller  (github)  — every github_ci_interval_seconds answers the recently requested rows. A merged PR is final:
  #                       answered once, never polled again. A PR closed without merging keeps its closed_at and why
  #                       (its issue events, read once per close: base deleted · head deleted · by <login>).
  # A failed poll, or an answer older than `stale_after`, is said on the link — never shown as the PR's state.
  module PrStates
    PR_URL = %r{\Ahttps://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)\z}
    FINAL = %w[merged].freeze
    UNKNOWN = "unknown: " # a closed PR for which GitHub itself has no reason (no closed_at / closed event / actor)

    module_function

    # owner/name of a github.com remote, nil for any other host
    def slug(remote) = Github.repo_url(remote)&.delete_prefix("https://github.com/")

    # A card's PRs are the ones its agents ASSIGNED to it (the engine's kanban_pr_assign → metadata `prs`, a LIST of
    # {url, repo, number, role, by, at}: any number per role and repo) — never derived from branch
    # names or PR numbers in text. Roles: on an enrolled project `local` (a PR on a private local repo) and `public` (a
    # PR on a public repo); on any other project `pr` (a PR on the project's own repo).
    ROLES = { local: "local", public: "public", pr: "pr" }.freeze
    ROLE_ORDER = ROLES.values.freeze

    class Invalid < StandardError; end

    # The engine's prs: port: the roles kanban_pr_assign takes on a card, the repos each one takes, and
    # which one an agent must have a PR of before the card leaves a work column — the same roles Flags / CiChecks read.
    # A card may change several repos (busyyaks + the kanban engine it vendors), so on an enrolled project `local` takes
    # a PR on ANY enrolled project's local repo the scanner knows, and `public` one on any enrolled project's public
    # repo (both read from the projects rows the scanner wrote from `git mirror-init`'s guard config — never a list in
    # code). `local` is required. A role with no repo the host can read → its `error` names why (the project's own
    # local_error first). Any other project: `pr`, on its own repo (its push remote, or origin), not required. A card
    # of no scanned project → Unavailable.
    class Roles
      # projects: ->(slug) { project row or nil }; enrolled: -> { every enrolled project row (local_mode set) }
      def initialize(projects:, enrolled:)
        @projects = projects
        @enrolled = enrolled
      end

      def pr_roles(card)
        project = @projects.call(card[:project_slug])
        unless project
          raise AgentsKanban::Delivery::Unavailable, "project #{card[:project_slug]} is not a scanned project"
        end
        return { ROLES[:pr] => plain(project) } unless project[:local_mode]

        rows = @enrolled.call
        { ROLES[:local] => side(project, rows, :local_repo, "local", required: true),
          ROLES[:public] => side(project, rows, :public_repo, "public", required: false), }
      end

      # The v14 migration's question (engine Schema.prs_to_lists!): an old `local` PR on a project that is not enrolled,
      # whose repo is in no role of the card (the old code never read it), is kept as removed with this reason; any
      # other PR in no role → nil (the migration stops naming it).
      def unread_reason(card, role, repo)
        project = @projects.call(card[:project_slug])
        return nil unless project && !project[:local_mode] && role == ROLES[:local]

        "v14: #{repo} is in no role this project reads (project not enrolled)"
      end

      private

      def side(project, rows, column, name, required:)
        repos = rows.filter_map { |r| PrStates.slug(r[column]) }.uniq(&:downcase).sort
        return { repos: repos, required: required } unless repos.empty?

        why = project[:local_error] || "no enrolled project has a #{name} repo on github.com " \
                                       "(this one: #{project[column] || 'none'})"
        { repos: [], required: required, error: why }
      end

      def plain(project)
        repos = [project[:pr_remote], project[:remote]].filter_map { |u| PrStates.slug(u) }.uniq(&:downcase)
        return { repos: repos, required: false } unless repos.empty?

        { repos: [], required: false,
error: "the repo of #{project[:slug]} is not on github.com (#{project[:remote] || 'no remote'})", }
      end
    end

    # The PRs the card's agents assigned (metadata `prs`), in the order assigned → [{url:, repo:, number:, role:, by:,
    # at:}]; `role` given = only that role's. A list that is not one of PR entries (or the pre-list {role => url} shape)
    # raises Invalid with the reason — never read as none. `card` is a hydrated card (metadata a Hash) or a raw `cards`
    # row (metadata its JSON text: the engine's watch pass and waiting counts hand those to the ci: port).
    def assigned(card, role = nil)
      meta = card[:metadata]
      begin
        meta = JSON.parse(meta) if meta.is_a?(String)
      rescue JSON::ParserError => e
        raise Invalid, "card ##{card[:id]} metadata is not JSON: #{e.message[0, 200]}"
      end
      list = meta.is_a?(Hash) ? meta["prs"] : nil
      return [] if list.nil?
      unless list.is_a?(Array)
        raise Invalid, "card ##{card[:id]} metadata prs is not a list of PRs: #{JSON.generate(list)[0, 200]}"
      end

      list.filter_map do |p|
        m = p.is_a?(Hash) ? p["url"].to_s.match(PR_URL) : nil
        raise Invalid, "card ##{card[:id]} metadata prs has an entry that is no PR URL: #{p.to_s[0, 200].inspect}" unless m
        next if role && p["role"] != role

        { url: p["url"], repo: m[1], number: m[2].to_i, role: p["role"], by: p["by"], at: p["at"] }
      end
    end

    # The PRs taken off the card (metadata `prs_removed`: kanban_pr_unassign, the operator's unassign, the v14
    # migration) → [{url:, repo:, number:, role:, removed_by:, removed_at:, reason:}]; never polled — history.
    def removed(card)
      meta = card[:metadata]
      meta = JSON.parse(meta) if meta.is_a?(String)
      list = meta.is_a?(Hash) ? meta["prs_removed"] : nil
      return [] if list.nil?
      raise Invalid, "card ##{card[:id]} metadata prs_removed is not a list" unless list.is_a?(Array)

      list.map do |r|
        m = r.is_a?(Hash) ? r["url"].to_s.match(PR_URL) : nil
        raise Invalid,
"card ##{card[:id]} metadata prs_removed has an entry that is no PR URL: #{r.to_s[0, 200].inspect}" unless m

        { url: r["url"], repo: m[1], number: m[2].to_i, role: r["role"], removed_by: r["removed_by"],
          removed_at: r["removed_at"], reason: r["reason"], }
      end
    rescue JSON::ParserError => e
      raise Invalid, "card ##{card[:id]} metadata is not JSON: #{e.message[0, 200]}"
    end

    # GitHub's mergeability of an OPEN PR: each mergeable_state as GitHub names it — clean, behind,
    # blocked (branch rules), unstable (checks failing), has_hooks, draft — except two, which name what they mean:
    # `mergeable` null or mergeable_state "unknown" = "computing" (GitHub starts computing on this read; never guessed
    # either way) and `mergeable` false or "dirty" = "conflicts". A value GitHub adds later = "unknown: <value>",
    # never coerced to one of these.
    STATES = %w[clean behind blocked unstable has_hooks draft].freeze

    def merge_state(pr)
      state = pr["mergeable_state"]
      return "computing" if pr["mergeable"].nil? || state == "unknown"
      return "conflicts" if pr["mergeable"] == false || state == "dirty"

      return state if STATES.include?(state)

      "unknown: #{state || 'none given'}"
    end

    SIDES = { "local" => %i[local_repo local_base], "public" => %i[public_repo public_base] }.freeze

    # The branch a `side` ("local" / "public") PR on `repo` must be based on — read off the enrolled project
    # whose `side` repo IS that repo (a card's PRs may sit on another project's repo, e.g. the engine it
    # vendors), never the card's own project's when the PR is elsewhere. rows = the enrolled project rows (local_mode
    # set). → [base, nil] | [nil, why]: no enrolled project has that repo on that side, its base is not read
    # (local_error), or two enrolments of the repo name different bases — never one picked.
    def side_base(rows, repo, side)
      repo_col, base_col = SIDES.fetch(side)
      hits = rows.select { |r| r[:local_mode] && PrStates.slug(r[repo_col])&.casecmp?(repo) }.uniq { |r| r[:slug] }
                 .sort_by { |r| r[:slug].to_s }
      return [nil, "#{repo} is the #{side} repo of no enrolled project"] if hits.empty?

      unread = hits.find { |r| r[base_col].nil? }
      return [nil, unread[:local_error] || "the scanner has not read the enrolment of #{unread[:slug]} yet"] if unread

      bases = hits.map { |r| r[base_col] }.uniq
      return [bases.first, nil] if bases.size == 1

      named = hits.map { |r| "#{r[:slug]} → #{r[base_col]}" }.join(", ")
      [nil, "the enrolments of #{repo} name different #{side} bases: #{named}"]
    end

    # Seconds a row stays polled after the web last asked for it (Poller and Reader share it).
    def wanted_for(interval) = 10 * interval

    class Reader
      # stale_after: an answer older than this, while the row was wanted, means the github service stopped.
      # wanted_for: the Poller's — a row nobody asked for that long is not polled, so its old answer is not shown.
      def initialize(db:, stale_after:, wanted_for:, clock: -> { Busyyaks::Clock.epoch })
        @db = db
        @stale_after = stale_after
        @wanted_for = wanted_for
        @clock = clock
      end

      # a GitHub account is connected (read once per Reader: one page / pass)
      def connected? = @connected.nil? ? (@connected = !GitHosts.github_login(@db).nil?) : @connected

      # → {state:, number:, url:} | {state: "checking"} | {error: "…"} — and marks the row wanted.
      def lookup(repo, ref)
        # no git host connected: the flag says so — never "checking" (nothing would ever answer)
        return { error: GitHosts.not_connected } unless connected?

        now = @clock.call
        row = @db[:gh_pr_states].where(repo: repo, ref: ref).first
        unless row
          # two views at once: the second insert does nothing (ON CONFLICT DO NOTHING, SQLite and PostgreSQL alike)
          @db[:gh_pr_states].insert_conflict(target: %i[repo ref]).insert(repo: repo, ref: ref, requested_at: now)
          return { state: "checking" }
        end
        @db[:gh_pr_states].where(id: row[:id]).update(requested_at: now)
        unwanted_since = row[:requested_at] + @wanted_for # the Poller stopped polling the row then
        return { error: "GitHub read failed: #{row[:error]}" } if row[:error]
        if row[:checked_at].nil?
          waited = now - row[:requested_at]
          if waited > @stale_after
            return { error: "not read by the github service #{waited}s after the request (is it running?)" }
          end

          return { state: "checking" }
        end
        if !FINAL.include?(row[:state]) && now - row[:checked_at] > @stale_after
          # nobody looked for a while → the old answer is not this PR's state; asked again just now
          return { state: "checking" } if [now, unwanted_since].min - row[:checked_at] <= @stale_after

          return { error: "last GitHub read #{(now - row[:checked_at]) / 60} min ago (github service stopped?)" }
        end

        out = { state: row[:state], number: row[:number], url: row[:url], checked_at: row[:checked_at], base: row[:base],
                merge_state: row[:merge_state], auto_merge: row[:auto_merge], }
        row[:state] == "closed" ? out.merge(closed_at: row[:closed_at], reason: row[:reason]) : out
      end
    end

    # The github service's side. Every read is conditional, like CiChecks::Poller's: the ETag GitHub gave for the PR
    # and the fields read from it (KEEP) are kept in gh_pages under `pr:<fields>:<url>`, so an unchanged PR answers 304, which
    # costs no rate limit — without it every wanted row was a full call each tick. A cached URL nobody read for
    # wanted_for is deleted at the end of each run. While `gate` (GithubPollers) is paused nothing is sent and every
    # wanted row says why.
    class Poller
      KEEP = %w[number html_url state draft merged_at closed_at base mergeable mergeable_state auto_merge].freeze
      PAGE = "pr:"

      def self.cache_key(url) = GithubNetwork.cache_key(PAGE, KEEP, url)

      def initialize(db:, client:, gate:, wanted_for:, clock: -> { Busyyaks::Clock.epoch })
        @db = db
        @client = client
        @gate = gate
        @pages = GithubNetwork::Data.new(db)
        @wanted_for = wanted_for # seconds a row stays interesting after the web last asked
        @clock = clock
      end

      # → number of rows read (0 while paused). dirty: only the rows a GitHub webhook marked (GithubHook; card #472);
      # every selected row's mark is cleared unless a hook marked it again since.
      def run(dirty: false)
        now = @clock.call
        # in id order: one batch, the same order on every database (PostgreSQL returns an updated row last)
        scope = @db[:gh_pr_states].where(Sequel.lit("requested_at >= ?", now - @wanted_for))
        scope = scope.exclude(dirty: nil) if dirty
        rows, final = scope.order(:id).all.partition { |r| !(FINAL.include?(r[:state]) && r[:checked_at] && r[:error].nil?) }
        # a final row is never read again: a mark it still carries (a hook landed while the pass that made it final
        # read it) is cleared here, or the waker would wake for it every wake_seconds
        clean(final)
        paused = @gate.paused
        if paused
          rows.each { |row| fail_row(row, paused) }
          clean(rows)
          return 0
        end

        rows.each_with_index do |row, i|
          @db[:gh_pr_states].where(id: row[:id]).update(poll(row).merge(checked_at: now, error: nil))
        rescue GithubNetwork::RateLimited => e # the token's limit: the rest of the batch would fail the same way
          why = @gate.rate_limited!(e)
          rows[i..].each { |r| fail_row(r, why) }
          break
        rescue StandardError => e # stored on the row and said on the link; the rest of the batch still runs
          fail_row(row, e.is_a?(GithubNetwork::Error) ? e.message : "#{e.class}: #{e.message}")
        end
        clean(rows)
        @db[:gh_pages].where(Sequel.like(:url, "#{PAGE}%")).where(Sequel.lit("at < ?", now - @wanted_for)).delete
        rows.size
      end

      private

      def fail_row(row, error) = @db[:gh_pr_states].where(id: row[:id]).update(error: error[0, 500], checked_at: nil)

      def clean(rows) = rows.each { |row| GithubHook.clean(@db[:gh_pr_states], row) }

      def poll(row)
        kind, name = row[:ref].split(":", 2)
        # a PR assigned to a card: a 404 is "not visible to the token / no such PR", never a state
        raise GithubNetwork::Error, "#{row[:repo]} #{row[:ref]}: not a pr:<n> ref" unless kind == "pr"

        pr = get("/repos/#{row[:repo]}/pulls/#{Integer(name)}")
        raise GithubNetwork::Error, "#{row[:repo]}##{name}: 404 — no such PR, or the token cannot see the repo" unless pr

        state = state(pr)
        out = { number: pr["number"], url: pr["html_url"], state: state, base: pr.dig("base", "ref"), closed_at: nil,
                reason: nil, merge_state: nil, auto_merge: nil, }
        if %w[open draft].include?(state)
          return out.merge(merge_state: PrStates.merge_state(pr), auto_merge: !pr["auto_merge"].nil?)
        end
        return out unless state == "closed"

        closed_at = closed_at(pr)
        # the reason is read once per close: the same close already read keeps its reason (an unknown one too: GitHub
        # has none for it). A failed read raises — the row's error, read again next poll — never stored as the reason.
        known = row[:reason] if row[:state] == "closed" && closed_at && row[:closed_at] == closed_at
        out.merge(closed_at: closed_at, reason: known || close_reason(row[:repo], pr["number"], closed_at))
      end

      # the PR's closed_at as epoch seconds, nil when GitHub gave none or an unreadable one (said as the reason)
      def closed_at(pr)
        Time.iso8601(pr["closed_at"].to_s).to_i
      rescue ArgumentError
        nil
      end

      # With no closed_at GitHub has no time for the close: "unknown: …" (the PR watch says it as the PR's error, never
      # tells it). A failed events read raises (rate limit included: run pauses the pollers).
      def close_reason(repo, number, closed_at)
        return "#{UNKNOWN}GitHub gave #{repo}##{number} no closed_at" unless closed_at

        reason(repo, number)
      end

      # Why a PR closed without merging, from its issue events (every page, oldest first): the events since its last
      # reopen up to its last `closed` — a deleted base closes it ("base deleted": GitHub never retargets), a deleted head
      # too ("head deleted"); otherwise somebody closed it ("by <login>", "by an unknown account" when the event names
      # none). No closed event → "unknown: …": GitHub has no reason to give.
      def reason(repo, number)
        events = []
        url = "/repos/#{repo}/issues/#{number}/events?per_page=#{GithubNetwork::PER_PAGE}"
        while url
          page = @client.get(url)
          events.concat(page.body)
          url = page.next_url
        end
        last = events.rindex { |e| e["event"] == "closed" }
        return "#{UNKNOWN}#{repo}##{number} is closed but its issue events have no closed event" unless last

        # the events since the last reopen up to the close — and those of the close's own second after it: GitHub
        # writes base_ref_deleted and closed in one second, in either order (busyyaks PR #43,
        # test/fixtures/github/issue_43_events.json). A branch deleted LATER (cleanup after a close) is not why.
        from = (events[0...last].rindex { |e| e["event"] == "reopened" } || -1) + 1
        at = events[last]["created_at"]
        upto = last + events[(last + 1)..].take_while { |e| e["created_at"] == at }.size
        kinds = events[from..upto].map { |e| e["event"] }
        return "base deleted" if kinds.include?("base_ref_deleted")
        return "head deleted" if kinds.include?("head_ref_deleted")

        login = events[last].dig("actor", "login").to_s
        login.empty? ? "by an unknown account" : "by #{login}"
      end

      # one conditional GET → the PR's KEEP fields (a 304 = the stored ones, its cache entry marked read now); 404 → nil
      def get(url)
        key = self.class.cache_key(url)
        cached = @pages.page(key)
        cached = nil unless cached&.dig(:items)
        page = @client.get(url, etag: cached&.dig(:etag), missing_ok: true)
        if page.not_modified?
          @db[:gh_pages].where(url: key).update(at: @clock.call)
          return JSON.parse(cached[:items])
        end
        return nil if page.status == 404

        body = page.body.slice(*KEEP)
        body["base"] = body["base"]&.slice("ref") # the base branch's name only, never its repo object
        @pages.save_page(key, page.etag, @clock.call, items: body)
        body
      end

      def state(pr)
        return "merged" if pr["merged_at"]
        return "closed" unless pr["state"] == "open"

        pr["draft"] ? "draft" : "open"
      end
    end

    # The card dialog's links, whose PR rows are the PRs assigned to the card (PrStates.assigned) and nothing else — EVERY
    # one, any number per role and repo . The engine's `pr` links — a `PR #N` in the text, resolved
    # against the card's own repo, and the handoff `pr_url` — are dropped: a number in prose names no repo, so it is never a
    # row (it stays an inline link in the text); a pasted PR URL stays a plain `url` link. Each row: "#N <repo name>" (the
    # number first: a narrow rail truncates the end) + small tags (role on an enrolled project: local · public; state: open
    # · draft · merged · closed · checking · unknown; `base: <ref>` when the PR is not on its side's branch,
    # conflicts · behind · mergeable: computing, auto-merge) + the hover details (repo, role, state, base, mergeable, who
    # assigned it when, when GitHub was read, why it is unknown), grouped by role (the engine's CardLink `group`: the rail
    # lists each role apart — "PRs · local" — and leaves the role tag out under it) in role order, then as assigned;
    # then the PRs taken off the card ("PRs · removed": one struck line each, its chip = the day).
    # None assigned → no row; a list that is not one of PRs, or an
    # enrolment the scanner could not read → a row that says why, linked to the project page.
    class Flags
      TONE = { "open" => "ok", "draft" => "muted", "merged" => "done", "closed" => "bad", "checking" => "muted" }.freeze
      ROLE_NAMES = { "local" => "private local repo", "public" => "public repo" }.freeze
      # an open PR's mergeability (PrStates.merge_state): clean = no tag, draft = the draft tag already shown;
      # a value PrStates does not know ("unknown: <value>") is tagged as it is
      MERGE_TAGS = { "conflicts" => %w[conflicts bad], "behind" => %w[behind warn],
                     "blocked" => ["blocked by branch rules", "warn"], "unstable" => ["checks failing", "warn"],
                     "has_hooks" => ["hooks pending", "muted"], "computing" => ["mergeable: computing", "muted"], }.freeze

      # enrolled: -> { every enrolled project row } — a PR's expected base is its own repo's enrolment's (side_base);
      # clock: the epoch now (a removed PR's day is shown without its year while that is this year)
      def initialize(reader, enrolled:, clock: -> { Busyyaks::Clock.epoch })
        @reader = reader
        @enrolled = enrolled
        @clock = clock
      end

      def apply(links, card, project)
        out = links.reject { |l| l[:kind] == "pr" }
        return out unless project

        enrolled = project[:local_mode] ? true : false
        out += rows(card, project, enrolled)
        return out unless project[:local_error]

        # an enrolment the scanner could not read (or that names no local mode at all) is said, linked to the project
        out + [{ kind: "pr", label: "config", url: "/projects/#{project[:slug]}", group: enrolled ? ROLES[:local] : nil,
                 tags: [tag("local", "info"), tag("unknown", "warn")], detail: [row("Why", project[:local_error])], }.compact]
      end

      private

      def tag(text, tone) = { text: text, tone: tone }
      def row(label, value) = { label: label, value: value.to_s }
      def at(epoch) = Time.at(epoch).strftime("%Y-%m-%d %H:%M:%S %Z")

      def rows(card, project, enrolled)
        prs = PrStates.assigned(card)
        rows = enrolled ? [project] + @enrolled.call : []
        live = prs.sort_by.with_index { |p, i| [ROLE_ORDER.index(p[:role]) || ROLE_ORDER.size, i] }.map do |p|
          want, why = want_base(rows, enrolled, p)
          flagged(p, enrolled, @reader.lookup(p[:repo], "pr:#{p[:number]}"), want_base: want, why: why)
        end
        live + PrStates.removed(card).map { |p| removed_row(p) }
      rescue PrStates::Invalid => e
        [{ kind: "pr", label: "PRs", url: "/projects/#{project[:slug]}", tags: [tag("unknown", "warn")],
           detail: [row("Why", e.message)], }]
      end

      # a PR taken off the card: ONE line in its own "removed" section — struck through (the engine's CardLink
      # `struck`), its chip = the day it was removed (server zone; with the year when that is not this year; no day
      # recorded → "removed"); who and why in the hover; never polled, no unassign
      def removed_row(pr)
        time = pr[:removed_at].is_a?(Integer) ? Time.at(pr[:removed_at]) : nil
        when_by = [pr[:removed_by], time && at(pr[:removed_at])].compact
        detail = [row("Repo", pr[:repo]), pr[:role] && row("Role", pr[:role]), row("State", "removed"),
                  row("Removed", when_by.empty? ? "not recorded" : when_by.join(" · ")), row("Why", pr[:reason]),]
        day = time&.strftime(time.year == Time.at(@clock.call).year ? "%m-%d" : "%Y-%m-%d")
        { kind: "pr", label: "##{pr[:number]} #{pr[:repo].split('/').last}", url: pr[:url], group: "removed",
          tags: [tag(day || "removed", "muted")], detail: detail.compact, struck: true, }
      end

      # The branch a PR must be based on → [base | :unknown, why]: its own repo's enrolment's (PrStates.side_base; the
      # card's project counts as enrolled); [nil, nil] = any (a plain project's `pr`).
      def want_base(rows, enrolled, pr)
        return [nil, nil] unless enrolled && SIDES.key?(pr[:role])

        base, why = PrStates.side_base(rows, pr[:repo], pr[:role])
        [base || :unknown, why]
      end

      def flagged(pr, enrolled, st, want_base: nil, why: nil)
        state = st[:error] ? "unknown" : st[:state]
        role = enrolled ? pr[:role] : nil
        # a PR closed without merging says why on its tag: "closed: base deleted"
        text = if st[:reason]
                 "#{state}: #{st[:reason].start_with?(UNKNOWN) ? 'why unknown' : st[:reason]}"
               else
                 state
               end
        tags = [role && tag(role, "info"), tag(text, TONE.fetch(state, "warn"))].compact
        detail = [row("Repo", pr[:repo]), role && row("Role", ROLE_NAMES.fetch(role, role)),
                  row("State", state == "closed" ? "closed without merging" : state),]
        assigned = [pr[:by], pr[:at].is_a?(Integer) ? at(pr[:at]) : nil].compact
        detail << row("Assigned", assigned.empty? ? "not recorded" : assigned.join(" · "))
        detail << row("Why", st[:error]) if st[:error]
        pr_flags(st, want_base, why, tags, detail) unless st[:error]
        detail << row("Why closed", st[:reason]) if st[:reason]
        # an absolute time: a relative "Ns ago" changed the card JSON on every request, so the card dialog's rev poll
        # refetched the whole card every 3 s
        detail << row("Read", "#{at(st[:checked_at])} (GitHub)") if st[:checked_at]
        detail << row("Read", "waiting for the github service") if state == "checking"
        # unassign: the rail offers the operator's unassign on it (an assigned PR; the config / error rows are not)
        { kind: "pr", label: "##{pr[:number]} #{pr[:repo].split('/').last}", url: pr[:url], group: role, tags: tags,
          detail: detail.compact, unassign: true, }.compact
      end

      # base · mergeability · auto-merge of a read PR → tags + hover rows. The base is shown on every read PR;
      # a base that is not the side's branch is a `base: <ref>` warning (the gate refuses it too).
      def pr_flags(st, want_base, why, tags, detail)
        return unless st[:base]

        detail << row("Base", st[:base])
        if want_base == :unknown
          tags << tag("base: #{st[:base]}", "warn")
          detail << row("Expected base", "unknown: #{why || 'the scanner has not read the enrolment yet'}")
        elsif want_base && st[:base] != want_base
          tags << tag("base: #{st[:base]}", "warn")
          detail << row("Expected base", want_base)
        end
        merge = MERGE_TAGS[st[:merge_state]]
        merge ||= [st[:merge_state], "warn"] if st[:merge_state]&.start_with?("unknown: ")
        tags << tag(*merge) if merge
        detail << row("Mergeable", st[:merge_state]) if st[:merge_state]
        return unless st[:auto_merge]

        tags << tag("auto-merge", "warn")
        detail << row("Auto-merge", "on: GitHub merges it once its checks pass, without the board's approval — the " \
                                    "approval is refused until it is turned off")
      end
    end
  end
end
