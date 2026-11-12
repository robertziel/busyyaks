# frozen_string_literal: true

require_relative "github_network"
require_relative "github"

module Busyyaks
  # The flags on a card's PR links: which repo the PR is in (local · public, from the project's
  # private local-repo enrolment, Scanner#enrolment) and its state (open · draft · merged · closed).
  #
  # The GitHub token lives only in the `github` compose service, so the work is split over gh_pr_states, like CiChecks:
  #   Reader  (web)     — asks for the PRs a card dialog shows (requested_at) and reads the answers. No token, no HTTP.
  #   Poller  (github)  — every GITHUB_CI_INTERVAL_SECONDS answers the recently requested rows. A merged PR is final:
  #                       answered once, never polled again.
  # A failed poll, or an answer older than `stale_after`, is said on the link — never shown as the PR's state.
  module PrStates
    PR_URL = %r{\Ahttps://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)\z}
    FINAL = %w[merged].freeze

    module_function

    # owner/name of a github.com remote, nil for any other host
    def slug(remote) = Github.repo_url(remote)&.delete_prefix("https://github.com/")

    # A card's PRs are the ones its agents ASSIGNED to it (the engine's kanban_pr_assign → metadata `prs.<role>` = the PR
    # URL) — never derived from branch names or PR numbers in text. Roles: on an enrolled project `local` (the
    # PR on the private local repo) and `public` (the PR on the public repo); on any other project `pr` (the card's PR
    # on its work repo).
    ROLES = { local: "local", public: "public", pr: "pr" }.freeze

    class Invalid < StandardError; end

    # The PR the card's agents assigned under `role` → [owner/name, number] on `repo` (nil = on any repo: a plain
    # project's `pr`, whose URL names its repo), nil when none is assigned; a value that is not a PR URL (on `repo`)
    # raises Invalid with the reason. `card` is a hydrated card (metadata a Hash) or a
    # raw `cards` row (metadata its JSON text: the engine's watch pass and waiting counts hand those to the ci: port).
    def assigned(card, role, repo)
      meta = card[:metadata]
      begin
        meta = JSON.parse(meta) if meta.is_a?(String)
      rescue JSON::ParserError => e
        raise Invalid, "card ##{card[:id]} metadata is not JSON: #{e.message[0, 200]}"
      end
      prs = meta.is_a?(Hash) ? meta["prs"] : nil
      url = prs.is_a?(Hash) ? prs[role] : nil
      return nil if url.nil?

      m = url.to_s.match(PR_URL)
      unless m && (repo.nil? || m[1].casecmp?(repo)) # GitHub owner/name: any case
        raise Invalid, "card ##{card[:id]} metadata prs.#{role} is not a PR on #{repo || 'github.com'}: " \
                       "#{url.to_s[0, 200].inspect}"
      end

      [repo || m[1], m[2].to_i]
    end

    # Seconds a row stays polled after the web last asked for it (Poller and Reader share it).
    def wanted_for(interval) = 10 * interval

    class Reader
      # stale_after: an answer older than this, while the row was wanted, means the github service stopped.
      # wanted_for: the Poller's — a row nobody asked for that long is not polled, so its old answer is not shown.
      def initialize(db:, stale_after:, wanted_for:, clock: -> { Time.now.to_i })
        @db = db
        @stale_after = stale_after
        @wanted_for = wanted_for
        @clock = clock
      end

      # → {state:, number:, url:} | {state: "checking"} | {error: "…"} — and marks the row wanted.
      def lookup(repo, ref)
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

        { state: row[:state], number: row[:number], url: row[:url], checked_at: row[:checked_at] }
      end
    end

    class Poller
      def initialize(db:, client:, wanted_for:, clock: -> { Time.now.to_i })
        @db = db
        @client = client
        @wanted_for = wanted_for # seconds a row stays interesting after the web last asked
        @clock = clock
      end

      # → number of rows answered
      def run
        now = @clock.call
        rows = @db[:gh_pr_states].where(Sequel.lit("requested_at >= ?", now - @wanted_for)).all
                                 .reject { |r| FINAL.include?(r[:state]) && r[:checked_at] && r[:error].nil? }
        rows.each do |row|
          @db[:gh_pr_states].where(id: row[:id]).update(poll(row).merge(checked_at: now, error: nil))
        rescue StandardError => e # stored on the row and said on the link; the rest of the batch still runs
          error = e.is_a?(GithubNetwork::Error) ? e.message : "#{e.class}: #{e.message}"
          @db[:gh_pr_states].where(id: row[:id]).update(error: error[0, 500], checked_at: nil)
        end.size
      end

      private

      def poll(row)
        kind, name = row[:ref].split(":", 2)
        # a PR assigned to a card: a 404 is "not visible to the token / no such PR", never a state
        raise GithubNetwork::Error, "#{row[:repo]} #{row[:ref]}: not a pr:<n> ref" unless kind == "pr"

        page = @client.get("/repos/#{row[:repo]}/pulls/#{Integer(name)}", missing_ok: true)
        if page.status == 404
          raise GithubNetwork::Error, "#{row[:repo]}##{name}: 404 — no such PR, or the token cannot see the repo"
        end

        pr = page.body
        { number: pr["number"], url: pr["html_url"], state: state(pr) }
      end

      def state(pr)
        return "merged" if pr["merged_at"]
        return "closed" unless pr["state"] == "open"

        pr["draft"] ? "draft" : "open"
      end
    end

    # The card dialog's links, whose PR rows are the PRs assigned to the card (PrStates.assigned) and nothing else:
    # `local` + `public` on an enrolled project, `pr` on any other. The engine's `pr` links — a `PR #N` in
    # the text, resolved against the card's own repo, and the handoff `pr_url` — are dropped: a number in prose names
    # no repo, so it is never a row (it stays an inline link in the text); a pasted PR URL stays a plain `url` link.
    # Each row: a short label ("#5") + small tags (repo role: local · public; state: open · draft · merged · closed ·
    # checking · unknown) + the hover details (repo, role, state, when GitHub was read, why it is unknown). No enrolment
    # → no role tag. None assigned → no row; an assignment that is no PR of its repo → a row that says so. Tags and
    # details are the engine's CardLink `tags` / `detail`.
    class Flags
      TONE = { "open" => "ok", "draft" => "muted", "merged" => "done", "closed" => "bad", "checking" => "muted" }.freeze

      def initialize(reader)
        @reader = reader
      end

      def apply(links, card, project)
        enrolled = project && project[:local_mode] ? project : nil
        out = links.reject { |l| l[:kind] == "pr" }
        return out unless project

        # not enrolled: the card's assigned `pr` PR; an enrolment that names no local mode at all is said too, linked
        # to the project
        unless enrolled
          out += plain_row(card, project)
          return out unless project[:local_error]

          return out + [{ kind: "pr", label: "config", url: "/projects/#{project[:slug]}",
                          tags: [tag("local", "info"), tag("unknown", "warn")],
                          detail: [row("Why", project[:local_error])], }]
        end

        out += assigned_row(card, enrolled, ROLES[:local], enrolled[:local_repo])
        out + assigned_row(card, enrolled, ROLES[:public], enrolled[:public_repo])
      end

      private

      def tag(text, tone) = { text: text, tone: tone }
      def row(label, value) = { label: label, value: value.to_s }

      def flagged(url, label, repo, role, st)
        state = st[:error] ? "unknown" : st[:state]
        tags = [role && tag(role, "info"), tag(state, TONE.fetch(state, "warn"))].compact
        detail = [row("Repo", repo), role && row("Role", role == "local" ? "private local repo" : "public repo"),
                  row("State", state),]
        detail << row("Why", st[:error]) if st[:error]
        # an absolute time: a relative "Ns ago" changed the card JSON on every request, so the card dialog's rev poll
        # refetched the whole card every 3 s
        detail << row("Read", "#{Time.at(st[:checked_at]).strftime('%Y-%m-%d %H:%M:%S %Z')} (GitHub)") if st[:checked_at]
        detail << row("Read", "waiting for the github service") if state == "checking"
        { kind: "pr", label: label, url: url, tags: tags, detail: detail.compact }
      end

      # a plain project's `pr` PR (on whichever repo its URL names), no role tag
      def plain_row(card, project)
        repo, number = PrStates.assigned(card, ROLES[:pr], nil)
        return [] unless number

        url = "https://github.com/#{repo}/pull/#{number}"
        [flagged(url, "##{number}", repo, nil, @reader.lookup(repo, "pr:#{number}"))]
      rescue PrStates::Invalid => e
        [flagged("/projects/#{project[:slug]}", ROLES[:pr], nil, nil, { error: e.message })]
      end

      # an enrolled side's PR assigned to the card under `role` on `remote`'s repo; none assigned → no row; an assignment
      # that is no PR of that repo, or a repo not on github.com → a row that says why.
      def assigned_row(card, project, role, remote)
        repo = PrStates.slug(remote)
        unless repo
          why = project[:local_error] || "the #{role} repo is not on github.com"
          return [flagged("/projects/#{project[:slug]}", role, remote, role, { error: why })]
        end

        _, number = PrStates.assigned(card, role, repo)
        return [] unless number

        url = "https://github.com/#{repo}/pull/#{number}"
        [flagged(url, "##{number}", repo, role, @reader.lookup(repo, "pr:#{number}"))]
      rescue PrStates::Invalid => e
        [flagged("/projects/#{project[:slug]}", role, repo, role, { error: e.message })]
      end
    end
  end
end
