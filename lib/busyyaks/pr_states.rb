# frozen_string_literal: true

require "uri"
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

    # The public PR's branch for a card (the name the private local-repo publish step gives it).
    def pub_branch(card_id) = "pub/card-#{card_id}"

    # The card's work branches start with this (the card flow's `card/<id>-<slug>`).
    def card_branch_prefix(card_id) = "card/#{card_id}-"

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
        if kind == "pr" # a PR the card names: a 404 is "not visible to the token / no such PR", never a state
          page = @client.get("/repos/#{row[:repo]}/pulls/#{Integer(name)}", missing_ok: true)
          if page.status == 404
            raise GithubNetwork::Error, "#{row[:repo]}##{name}: 404 — no such PR, or the token cannot see the repo"
          end

          pr = page.body
        else # head:owner:branch — the newest PR from that head, any state; none = not opened yet
          pr = @client.get("/repos/#{row[:repo]}/pulls?state=all&head=#{URI.encode_www_form_component(name)}").body.first
          return { number: nil, url: nil, state: "none" } unless pr
        end

        { number: pr["number"], url: pr["html_url"], state: state(pr) }
      end

      def state(pr)
        return "merged" if pr["merged_at"]
        return "closed" unless pr["state"] == "open"

        pr["draft"] ? "draft" : "open"
      end
    end

    # The card dialog's links with every PR (a `pr` link, or a `url` one that is a github.com PR) flagged: a short label
    # ("#5") + small tags (repo role: local · public; state: open · draft · merged · closed · checking · unknown) +
    # the hover details (repo, role, state, when GitHub was read, why it is unknown). No enrolment → no role tag.
    # the PRs the text does not name are found by their head on GitHub — the one opened from the card's
    # branch (`card/<id>-*` in the checkout, or a branch the text names) on the work repo, and, on an enrolled project,
    # the public PR (`pub/card-<id>` on the public repo). A row is a pull request GitHub returned, never a placeholder:
    # none opened (or not answered yet) → no row; a failed read → a row that says so. Tags and details are the engine's
    # CardLink `tags` / `detail`.
    class Flags
      TONE = { "open" => "ok", "draft" => "muted", "merged" => "done", "closed" => "bad", "checking" => "muted" }.freeze

      # branches: ->(project row) { Set of the repo's branch names } — Kanban.git_port (the scanner's last read) in
      # production; raises GitPort::Unavailable for a repo it has not read (the card shows why).
      def initialize(reader, branches:)
        @reader = reader
        @branches = branches
      end

      def apply(links, card, project)
        enrolled = project && project[:local_mode] ? project : nil
        roles = if enrolled
                  { PrStates.slug(enrolled[:local_repo]) => "local", PrStates.slug(enrolled[:public_repo]) => "public" }
                else
                  {}
                end
        out = links.map do |l|
          next l unless %w[pr url].include?(l[:kind])

          m = l[:url].match(PR_URL) # a PR pasted as a bare URL is a PR too
          next l unless m

          flagged(l[:url], "##{m[2]}", m[1], roles[m[1]], @reader.lookup(m[1], "pr:#{m[2]}"))
        end
        return out unless project

        out += branch_prs(out, card, project, roles)
        # an enrolment that names no local mode at all: said, linked to the project
        if !enrolled && project[:local_error]
          return out + [{ kind: "pr", label: "config", url: "/projects/#{project[:slug]}",
                          tags: [tag("local", "info"), tag("unknown", "warn")],
                          detail: [row("Why", project[:local_error])], }]
        end
        return out unless enrolled

        out + public_pr(out, card, enrolled)
      end

      private

      def tag(text, tone) = { text: text, tone: tone }
      def row(label, value) = { label: label, value: value.to_s }

      def flagged(url, label, repo, role, st, extra: [])
        state = st[:error] ? "unknown" : st[:state]
        tags = [role && tag(role, "info"), tag(state, TONE.fetch(state, "warn"))].compact
        detail = [row("Repo", repo), role && row("Role", role == "local" ? "private local repo" : "public repo"), *extra,
                  row("State", state),]
        detail << row("Why", st[:error]) if st[:error]
        # an absolute time: a relative "Ns ago" changed the card JSON on every request, so the card dialog's rev poll
        # refetched the whole card every 3 s
        detail << row("Read", "#{Time.at(st[:checked_at]).strftime('%Y-%m-%d %H:%M:%S %Z')} (GitHub)") if st[:checked_at]
        detail << row("Read", "waiting for the github service") if state == "checking"
        { kind: "pr", label: label, url: url, tags: tags, detail: detail.compact }
      end

      def search_url(repo, branch)
        "https://github.com/#{repo}/pulls?q=#{URI.encode_www_form_component("is:pr head:#{branch}")}"
      end

      # GitHub's answer for one head as a row: the PR it returned (skipped when the links already list it), a failed
      # read said on the search for that head, nothing while there is no PR (none opened, or not answered yet).
      def head_row(links, repo, owner, branch, role)
        st = @reader.lookup(repo, "head:#{owner}:#{branch}")
        return nil unless st[:url] || st[:error]
        return nil if st[:url] && links.any? { |l| l[:url] == st[:url] }

        extra = [row("Branch", "#{owner}:#{branch}")]
        return flagged(st[:url], "##{st[:number]}", repo, role, st, extra: extra) if st[:url]

        flagged(search_url(repo, branch), branch, repo, role, st, extra: extra)
      end

      # the PR opened from one of the card's branches on the work repo (the branch's push remote): the
      # checkout's `card/<id>-*` branches and the branches the text names (the engine's branch links). The public
      # branch is pushed to the public repo only (public_pr looks there), so it is not asked for here.
      def branch_prs(links, card, project, roles)
        repo = PrStates.slug(project[:pr_remote]) or return []
        owner = repo.split("/").first
        prefix = PrStates.card_branch_prefix(card[:id])
        own = project[:path] ? @branches.call(project).select { |b| b.start_with?(prefix) } : []
        named = links.select { |l| l[:kind] == "branch" }.map { |l| l[:label] }
        (own + named).uniq.sort.reject { |b| b == PrStates.pub_branch(card[:id]) }
                     .filter_map { |b| head_row(links, repo, owner, b, roles[repo]) }
      end

      def public_pr(links, card, project)
        repo = PrStates.slug(project[:public_repo])
        branch = PrStates.pub_branch(card[:id])
        head = PrStates.slug(project[:public_head])&.split("/")&.first
        unless repo && head # e.g. upstream mode before `gh repo fork`: no fork remote → whose head is unknown, said
          why = project[:local_error] || "the public repo is not on github.com"
          url = repo ? search_url(repo, branch) : "/projects/#{project[:slug]}"
          return [flagged(url, branch, repo || project[:public_repo], "public", { error: why }, extra: [row("Branch", branch)])]
        end

        [head_row(links, repo, head, branch, "public")].compact
      end
    end
  end
end
