# frozen_string_literal: true

require "time"
require "uri"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/errors"
require_relative "github_network"
require_relative "github"
require_relative "pr_states"

module Busyyaks
  # PR check status for the kanban idle watch (config/kanban.yml idle_watch; the engine's CiChecks port).
  #
  # The GitHub token lives only in the `github` compose service, so the work is split over the db (gh_pr_checks):
  #   Port    (notifier)  — names the PR a card is about (its pr_url, else the open PR on the owner session's branch),
  #                         registers "I want this" (requested_at) and reads the answer. No token, no HTTP.
  #   Poller  (github)    — every GITHUB_CI_INTERVAL_SECONDS answers the recently requested rows through
  #                         GithubNetwork::Client.
  # A poll that failed, or answers older than `stale_after` seconds, make the Port raise Unavailable: the engine skips the
  # idle watch for that pass and says why. Nothing is guessed.
  module CiChecks
    FINISHED = %w[success failure].freeze
    BAD_RUN = %w[failure timed_out cancelled action_required startup_failure stale].freeze
    PR_URL = %r{\Ahttps://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)}
    PR_URL_ANY = %r{https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)}

    Unavailable = AgentsKanban::Delivery::Unavailable

    # How long the github service keeps polling a request after it was last made (Poller wanted_for); a request older
    # than this is no longer polled, so the Port asks it afresh instead of reading its old answer as stale.
    def self.wanted_for(interval) = 10 * interval

    # The notifier's side. launcher (SessionGit): answers git(session:, socket:) →
    # {"ok"=>true, "branch"=>…, "last_commit_at"=>…}.
    class Port
      # approvals: ->(slug) { the board's approval steps as hashes, in order } (Store#board_of(slug).approvals)
      def initialize(db:, projects:, approvals:, launcher:, stale_after:, wanted_for:, clock: -> { Time.now.to_i })
        @db = db
        @approvals = approvals
        @wanted_for = wanted_for
        @projects = projects # ->(slug) { project row or nil }
        @launcher = launcher
        @stale_after = stale_after
        @clock = clock
      end

      def pr_checks(card)
        repo, ref = target(card)
        repo ? read(repo, ref) : nil
      end

      # The engine's approval gate (config/kanban.yml approval.requires_green_ci): what each approval step checks.
      # A project that is not enrolled: the card's PR (pr_url, else the owner's branch). An enrolled one
      # works on its LOCAL PR (#local_pr — the pr_url, or the newest handoff naming a PR on the local repo: the public
      # loop's handoffs carry the public PR):
      #   - the board's FIRST approval step (Local: Human review) = the local PR OPEN with green checks (merged ahead
      #     of the approval → refused);
      #   - a later non-final step (Local: Deploy check → Open public PR) = the local PR MERGED and the CI of its merge
      #     commit on the working branch green (`merge:<N>` — jenkins/ci on `local`);
      #   - the final step (the public merge) = the public PR = the card's metadata `prs.public` (a PR on the public
      #     repo; git mirror-publish names its branch after the change, never the card), and only once the local PR is
      #     MERGED. None recorded, or not a PR of the public repo → Unavailable with the reason.
      # An enrolment the scanner could not read, or a card with no local PR → Unavailable with the reason.
      def approval_checks(card, step)
        project = @projects.call(card[:project_slug])
        return pr_checks(card) unless project && project[:local_mode]

        repo, number = local_pr(card, project)
        unless step[:final]
          state = answer(repo, "pr:#{number}")[:state]
          if first_step?(card, step)
            case state
            when "merged"
              # approved once already (an approve after the handoff that named it), merged, then the card was moved
              # back into the gate: nothing is left to approve, the merge commit's CI answers
              return merge_ci(repo, number) if approved_after_handoff?(card, repo, number)

              return blocked(number, "the local PR ##{number} was merged before its approval")
            when "closed" then return blocked(number, "the local PR ##{number} was closed without merging")
            when "none" then return blocked(number, "the local PR ##{number} was not found on #{repo}")
            end

            return read(repo, "pr:#{number}")
          end

          unmerged = local_unmerged(repo, number)
          return unmerged if unmerged

          return merge_ci(repo, number) # the merge commit's CI on the working branch
        end

        unmerged = local_unmerged(repo, number)
        return unmerged if unmerged

        repo = PrStates.slug(project[:public_repo])
        unless repo
          raise Unavailable, "the public PR of card ##{card[:id]} cannot be found: " \
                             "#{project[:local_error] || 'the public repo is not on github.com'}"
        end

        _, number = PrStates.public_pr(card, repo)
        raise Unavailable, "card ##{card[:id]} records no public PR (metadata prs.public, a PR on #{repo})" unless number

        read(repo, "pr:#{number}")
      rescue PrStates::Invalid => e
        raise Unavailable, e.message
      end

      def last_commit_at(card)
        return nil unless card[:owner_session]

        git = @launcher.git(session: card[:owner_session], socket: card[:owner_socket] || "default")
        git["last_commit_at"]
      end

      private

      # → [owner/name, number] of the card's PR on the project's local repo: its pr_url, else the newest handoff that
      # names one (a handoff's activity line carries its PR URL). None → Unavailable (nothing guessed).
      def local_pr(card, project)
        repo = PrStates.slug(project[:local_repo])
        unless repo
          raise Unavailable, "the local PR of card ##{card[:id]} cannot be found: " \
                             "#{project[:local_error] || 'the local repo is not on github.com'}"
        end

        handoffs = @db[:card_activity].where(card_id: card[:id], kind: "handoff").order(Sequel.desc(:id)).select_map(:body)
        [card[:pr_url].to_s, *handoffs].each do |text|
          text.scan(PR_URL_ANY) { |r, n| return [r, n.to_i] if r == repo }
        end
        raise Unavailable, "card ##{card[:id]} has no local PR (a PR on #{repo} in its pr_url or a handoff)"
      end

      # The merge:<N> answer; anything but green carries what was read (the shas) as the refusal's reason.
      def merge_ci(repo, number)
        row = answer(repo, "merge:#{number}")
        return row if %w[success unpolled].include?(row[:state])

        # the CI's own state is kept (a red merge CI is "failure": the engine's gate watch pings the owner), the words
        # name what was read
        { number: number, state: row[:state], finished_at: row[:finished_at],
          reason: "jenkins/ci for the local PR ##{number} merge is #{row[:state]}: #{row[:detail]}", }
      end

      # Did the operator approve the card after the newest handoff naming the local PR repo#number? (card_activity: the
      # engine's `approve` entry, logged by an approval move only.)
      def approved_after_handoff?(card, repo, number)
        acts = @db[:card_activity].where(card_id: card[:id], kind: %w[handoff approve]).order(Sequel.desc(:id))
                                  .select_map(%i[kind body])
        names = ->(body) { body.to_s.scan(PR_URL_ANY).any? { |r, n| r == repo && n.to_i == number } }
        handed = acts.index { |kind, body| kind == "handoff" && names.call(body) }
        !handed.nil? && acts.first(handed).any? { |kind, _| kind == "approve" }
      end

      # The board's first approval step (the engine's derivation order: board order).
      def first_step?(card, step) = @approvals.call(card[:project_slug]).first&.fetch(:from) == step[:from]

      def blocked(number, reason) = { number: number, state: "blocked", finished_at: nil, reason: reason }

      # → nil when the local PR is merged, else the refusal (engine `reason:`): not read yet, open, closed.
      def local_unmerged(repo, number)
        row = answer(repo, "pr:#{number}")
        return nil if row[:state] == "merged"

        what = case row[:state]
               when "unpolled" then "not read yet (asked now — try again in a minute)"
               when "closed" then "closed without merging"
               when "none" then "not found"
               else "still open, not merged into the local repo"
               end
        { number: row[:number], state: "blocked", finished_at: nil, reason: "the local PR ##{number} is #{what}" }
      end

      # The polled answer for repo + ref, registering the request ("I want this") — never a guess. No open PR → nil.
      def read(repo, ref)
        row = answer(repo, ref)
        return nil if %w[none closed merged].include?(row[:state])

        row
      end

      # The poll row's answer, any state. A request last made longer ago than wanted_for has fallen out of the github
      # service's window (it polls only recent requests): its old answer is dropped and it is asked again.
      # Inside the window, an unanswered or old answer still means the service is not answering → Unavailable.
      def answer(repo, ref)
        now = @clock.call
        row = @db[:gh_pr_checks].where(repo: repo, ref: ref).first
        if row && now - row[:requested_at] > @wanted_for
          @db[:gh_pr_checks].where(id: row[:id]).update(requested_at: now, checked_at: nil, error: nil)
          return { number: nil, state: "unpolled", finished_at: nil }
        end
        unless row
          @db[:gh_pr_checks].insert(repo: repo, ref: ref, requested_at: now)
          return { number: nil, state: "unpolled", finished_at: nil }
        end
        @db[:gh_pr_checks].where(id: row[:id]).update(requested_at: now)
        raise Unavailable, "GitHub check poll for #{repo} #{ref} failed: #{row[:error]}" if row[:error]
        if row[:checked_at].nil?
          waited = now - row[:requested_at]
          if waited > @stale_after
            raise Unavailable, "#{repo} #{ref} was requested #{waited}s ago and the github service has not polled it " \
                               "(is it running?)"
          end

          return { number: nil, state: "unpolled", finished_at: nil }
        end
        age = now - row[:checked_at]
        if age > @stale_after
          raise Unavailable, "GitHub check status for #{repo} #{ref} is #{age}s old (github service stopped?)"
        end

        out = { number: row[:number], state: row[:state], finished_at: row[:finished_at] }
        out[:head] = row[:head] if row[:head] # the PR head sha (pr: / branch: / head: rows; a merge: row has none)
        row[:detail] ? out.merge(detail: row[:detail]) : out
      end

      # → [owner/name, "pr:N" | "branch:b"] | nil (no repo on github.com, or the owner is on no branch)
      def target(card)
        m = card[:pr_url].to_s.match(PR_URL)
        return [m[1], "pr:#{m[2]}"] if m

        project = @projects.call(card[:project_slug])
        repo = project && Github.repo_url(project[:pr_remote])&.delete_prefix("https://github.com/") # push remote
        return nil unless repo && card[:owner_session]

        git = @launcher.git(session: card[:owner_session], socket: card[:owner_socket] || "default")
        branch = git["branch"].to_s
        branch.empty? ? nil : [repo, "branch:#{branch}"]
      end
    end

    # The github service's side. Every read is conditional (If-None-Match on the ETag GitHub gave for that URL last
    # time, kept in gh_pages under `ci:<url>` with the fields the poller reads — KEEP, never the whole response): an
    # unchanged PR or check list answers 304, which GitHub does not count against the token's rate limit — a card
    # waiting days in a gate, its checks asked every minute (the engine's approval prefetch, card #247), costs nothing
    # while its PR stands still. A cached URL nobody read for wanted_for (a pushed-over sha, a card out of the gate)
    # is deleted at the end of each run.
    class Poller
      KEEP = %w[number state merged_at merge_commit_sha head base sha ref statuses updated_at check_runs status
                conclusion completed_at commit].freeze
      PAGE = "ci:"

      def initialize(db:, client:, wanted_for:, clock: -> { Time.now.to_i })
        @db = db
        @client = client
        @pages = GithubNetwork::Data.new(db)
        @wanted_for = wanted_for # seconds a request stays interesting after the notifier last asked
        @clock = clock
      end

      # → number of rows answered
      def run
        now = @clock.call
        rows = @db[:gh_pr_checks].where(Sequel.lit("requested_at >= ?", now - @wanted_for)).all
        rows.each do |row|
          @db[:gh_pr_checks].where(id: row[:id]).update({ detail: nil, head: nil }.merge(poll(row)).merge(checked_at: now,
error: nil))
        rescue GithubNetwork::Error => e
          @db[:gh_pr_checks].where(id: row[:id]).update(error: e.message[0, 500], checked_at: nil)
        end
        @db[:gh_pages].where(Sequel.like(:url, "#{PAGE}%")).where(Sequel.lit("at < ?", now - @wanted_for)).delete
        rows.size
      end

      private

      # One conditional GET → the body's KEEP fields (a 304 = the stored ones, its row marked read now); a 404 with
      # missing_ok → nil.
      def get(url, missing_ok: false)
        key = "#{PAGE}#{url}"
        cached = @pages.page(key)
        cached = nil unless cached&.dig(:items)
        page = @client.get(url, etag: cached&.dig(:etag), missing_ok: missing_ok)
        if page.not_modified?
          @db[:gh_pages].where(url: key).update(at: @clock.call)
          return JSON.parse(cached[:items])
        end
        return nil if page.status == 404

        body = slim(page.body)
        @pages.save_page(key, page.etag, @clock.call, items: body)
        body
      end

      def slim(v)
        case v
        when Hash then v.slice(*KEEP).transform_values { |x| slim(x) }
        when Array then v.map { |x| slim(x) }
        else v
        end
      end

      def poll(row)
        repo = row[:repo]
        kind, name = row[:ref].split(":", 2)
        pr = if %w[pr merge].include?(kind)
               get("/repos/#{repo}/pulls/#{Integer(name)}", missing_ok: true)
             else # branch:<b> on the repo's own owner; head:<owner>:<b> (a public PR from a fork)
               head = kind == "head" ? name : "#{repo.split('/').first}:#{name}"
               get("/repos/#{repo}/pulls?state=open&head=#{URI.encode_www_form_component(head)}").first
             end
        return { number: nil, state: "none", finished_at: nil } unless pr
        return merge_checks(repo, pr) if kind == "merge"
        # merged (the public step needs the local PR merged) vs closed unmerged
        unless pr["state"] == "open"
          return { number: pr["number"], state: pr["merged_at"] ? "merged" : "closed", finished_at: nil }
        end

        sha = pr.dig("head", "sha")
        { number: pr["number"], head: sha }.merge(checks(repo, sha)) # head: the engine's approvable-now check (card #248)
      end

      # merge:<N> = the CI of the PR's merge commit on its base branch. Jenkins coalesces a branch's builds, so the merge
      # commit may never get checks of its own: then the base branch's HEAD is read, but only when it CONTAINS the merge
      # commit (compare merge...head = ahead | identical) — the build of a descendant includes the change. `detail`
      # names the shas read. Not merged yet → its state, no checks read.
      def merge_checks(repo, pr)
        base = { number: pr["number"], finished_at: nil }
        unless pr["merged_at"]
          return base.merge(state: pr["state"] == "open" ? "open" : "closed", detail: "PR ##{pr['number']} is not merged")
        end

        sha = pr["merge_commit_sha"]
        own = checks(repo, sha)
        return base.merge(own).merge(detail: "merge commit #{sha[0, 7]}") unless own[:state] == "nochecks"

        branch = pr.dig("base", "ref")
        head = get("/repos/#{repo}/branches/#{URI.encode_www_form_component(branch)}").dig("commit", "sha")
        if head == sha
          return base.merge(state: "nochecks", detail: "merge commit #{sha[0, 7]} (the head of #{branch}) has no checks")
        end

        status = get("/repos/#{repo}/compare/#{sha}...#{head}")["status"]
        unless %w[ahead identical].include?(status)
          return base.merge(state: "nochecks", detail: "merge commit #{sha[0, 7]} has no checks and #{branch} head " \
                                                       "#{head[0, 7]} does not contain it (compare: #{status})")
        end

        base.merge(checks(repo, head)).merge(detail: "merge commit #{sha[0, 7]} has no checks of its own; read " \
                                                     "#{branch} head #{head[0, 7]}, which contains it")
      end

      # statuses (Jenkins posts these) + check runs (Actions): finished = nothing pending; failure = any failed.
      def checks(repo, sha)
        st = get("/repos/#{repo}/commits/#{sha}/status")
        runs = get("/repos/#{repo}/commits/#{sha}/check-runs?per_page=100")["check_runs"]
        statuses = st["statuses"]
        return { state: "nochecks", finished_at: nil } if statuses.empty? && runs.empty?

        pending = statuses.any? { |s| s["state"] == "pending" } || runs.any? { |r| r["status"] != "completed" }
        return { state: "pending", finished_at: nil } if pending

        times = statuses.map { |s| Time.iso8601(s["updated_at"]).to_i } + runs.map { |r| Time.iso8601(r["completed_at"]).to_i }
        bad = statuses.any? { |s| %w[failure error].include?(s["state"]) } ||
              runs.any? { |r| BAD_RUN.include?(r["conclusion"]) }
        { state: bad ? "failure" : "success", finished_at: times.max }
      end
    end
  end
end
