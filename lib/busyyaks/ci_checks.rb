# frozen_string_literal: true

require "json"
require "time"
require "uri"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/errors"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/card_links"
require_relative "github_network"
require_relative "github"
require_relative "pr_states"
require_relative "clock"

module Busyyaks
  # PR check status for the kanban idle watch (config/kanban.yml idle_watch; the engine's CiChecks port).
  #
  # The GitHub token lives only in the `github` compose service, so the work is split over the db (gh_pr_checks):
  #   Port    (notifier)  — names the PR a card is about (the one its agents assigned to it: PrStates.assigned),
  #                         registers "I want this" (requested_at) and reads the answer. No token, no HTTP.
  #   Poller  (github)    — every GITHUB_CI_INTERVAL_SECONDS answers the recently requested rows through
  #                         GithubNetwork::Client.
  # A poll that failed, or answers older than `stale_after` seconds, make the Port raise Unavailable: the engine skips the
  # idle watch for that pass and says why. Nothing is guessed.
  module CiChecks
    FINISHED = %w[success failure].freeze
    CHECKED = %w[success failure pending nochecks].freeze # an open PR's pr:<N> answer (its checks read)
    NO_CLOSED_AT = 0 # the PR watch's key for a close GitHub gave no closed_at (never shown as a time)
    BAD_RUN = %w[failure timed_out cancelled action_required startup_failure stale].freeze

    Unavailable = AgentsKanban::Delivery::Unavailable
    # a row whose repo config/busyyaks.yml ci.required does not list (stored on the row as is, said by the Port)
    class Unconfigured < StandardError; end

    # How long the github service keeps polling a request after it was last made (Poller wanted_for); a request older
    # than this is no longer polled, so the Port asks it afresh instead of reading its old answer as stale.
    def self.wanted_for(interval) = 10 * interval

    # A board's approval steps as the Port reads them: the engine's step hashes, in order, each with the label of the
    # gate it leaves (`from_label`) — the label the engine writes into the handoff and approve entries of that gate.
    def self.steps(board) = board.approvals.map { |s| s.to_h.merge(from_label: board.label(s.from)) }

    # → the repos (owner/name, sorted) an enrolled project's roles name — its local repo and its public repo — that
    # config ci.required does not list: a card's PR there is never judged (its gate is refused with "no required CI
    # contexts for <repo>"). Shown on /github ("CI contexts not configured for …"), never a reason to stop the poller.
    def self.unlisted(db, ci)
      repos = db[:projects].exclude(local_mode: nil).select_map(%i[local_repo public_repo]).flatten
      repos.filter_map { |url| PrStates.slug(url) }.uniq { |r| r.downcase }.reject { |r| ci.required_for(r) }.sort
    end

    # Card #511's live guard: every card the operator can Approve now (the engine's Store#approval_pending_cards — the
    # cards its prefetch asks) whose step reads a request the github service no longer polls: never asked, or last
    # asked longer ago than wanted_for. Its Approve would be refused "not read yet". Run right
    # after the notifier's prefetch, the list is empty unless a card was not asked — said by the notifier (GateGuard)
    # and on /github. → [{card:, project:, column:, reads: [{repo:, ref:, age: seconds | nil (never asked)}]}]
    def self.stale_gates(store, port)
      store.approval_pending_cards.filter_map do |c, step|
        reads = port.stale_reads(c, step.to_h)
        { card: c[:id], project: c[:project_slug], column: c[:column], reads: reads } if reads.any?
      end
    end

    # The notifier's line for stale_gates: one per card per change of what is stale, one when it is fresh again.
    class GateGuard
      def initialize(log:, window:)
        @log = log
        @window = window
        @said = {} # card id => the line said last
      end

      # A change = another column, another set of rows, a row never asked turning asked, or another poll error — never
      # an age growing by one watch pass (review round 1: the line carries the age, so it was said every pass).
      def check(stale)
        now = stale.to_h { |g| [g[:card], key(g)] }
        stale.each { |g| @log.puts(line(g)) unless @said[g[:card]] == now[g[:card]] }
        (@said.keys - now.keys).each { |id| @log.puts("gate guard: card #{id} reads fresh again") }
        @said = now
      end

      private

      def key(g) = [g[:column], g[:reads].map { |r| [r[:repo], r[:ref], r[:age].nil?, r[:error], r[:why]] }]

      def line(g)
        reads = g[:reads].map do |r|
          what = if r[:error] then "poll failed: #{r[:error]}"
                 elsif r[:why] then r[:why]
                 elsif r[:age] then "last asked #{r[:age]}s ago"
                 else "never asked"
                 end
          "#{r[:repo]} #{r[:ref]} #{what}"
        end
        "gate guard: card #{g[:card]} (#{g[:column]}): #{reads.join('; ')} — not answered inside the #{@window}s " \
          "poll window: its Approve is refused until each is read"
      end
    end

    # The notifier's side. launcher (SessionGit): answers git(session:, socket:) →
    # {"ok"=>true, "branch"=>…, "last_commit_at"=>…}.
    class Port
      # approvals: ->(slug) { the board's approval steps, in order } (CiChecks.steps(Store#board_of(slug)))
      def initialize(db:, projects:, approvals:, launcher:, stale_after:, wanted_for:, clock: -> { Busyyaks::Clock.epoch })
        @db = db
        @approvals = approvals
        @wanted_for = wanted_for
        @projects = projects # ->(slug) { project row or nil }
        @launcher = launcher
        @stale_after = stale_after
        @clock = clock
        # the PR states (gh_pr_states) behind the PR watch and a closed PR's reason: same freshness rule
        @states = PrStates::Reader.new(db: db, stale_after: stale_after, wanted_for: wanted_for, clock: clock)
      end

      # The engine's PR watch (Store#pr_watch_pass, every notifier watch pass, every card outside a terminal column):
      # every PR assigned to the card is asked (gh_pr_states, so the github service keeps them read) → the ones closed
      # WITHOUT merging, {role:, number:, closed_at:, why:}, and one {error:} per PR (or assignment) that cannot be read
      # — beside the closes, so a closed PR never hides another one's failure. A PR not read yet is not closed yet; nor
      # is a closed row whose reason was never read (polled before the reason existed): told once the poller re-reads it.
      def closed_prs(card)
        errors = []
        closed = assigned_prs(card, errors).filter_map { |role, repo, number| closed_pr(role, repo, number) }
        closed + errors.map { |e| { error: e } }
      end

      def pr_checks(card)
        repo, ref = target(card)
        repo ? read(repo, ref) : nil
      end

      # The engine's approval gate (config/kanban.yml approval.requires_green_ci): what each approval step checks.
      # Every PR is the one the card's agents ASSIGNED (kanban_pr_assign → metadata prs.<role>; PrStates.assigned).
      # A project that is not enrolled: the card's `pr` PR. An enrolled one works on its `local` PR:
      #   - the board's FIRST approval step (Local: Human review) = the local PR OPEN with green checks (merged ahead
      #     of the approval → refused);
      #   - a later non-final step (Local: Deploy check → Open public PR) = the local PR MERGED and the CI of its merge
      #     commit on the working branch green (`merge:<N>` — jenkins/ci on `local`);
      #   - the final step (the public merge) = the `public` PR, and only once the local PR is MERGED.
      # None assigned, one that is no PR of its repo, or an enrolment the scanner could not read → Unavailable with the
      # reason. An open PR a step reads must also be mergeable as it stands (#mergeable): not a draft, on its
      # side's base branch, no conflicts, no GitHub auto-merge, its mergeability computed (behind: warned, not refused).
      # Asked for a HANDOFF (the engine passes handoff_ci_url = its ci_url, a key only a handoff carries), a green
      # answer is also checked against that ci_url: it must be the build of a required context on the commit the answer
      # read (`builds`) — never an older build, nor a URL naming no build. An Approve or a watch pass asks only whether
      # the head's required checks are green: a rebuild of the same head after the handoff never parks the card.
      def approval_checks(card, step)
        built!(card, step_checks(card, step))
      end

      # The engine's progress watch (Store#progress_watch_pass, config/kanban.yml progress_watch): what moved on the card's
      # work OUTSIDE the card, as {kind, key, text} — the engine calls a changed key progress:
      #   the PR the idle watch follows (#target: the `local` PR on an enrolled project, else the `pr` one) — its head
      #     (gh_pr_checks pr:<N> .head) and that head's CI (state + finish + the required checks' build URLs: a rebuild
      #     of the same head is a new check); nothing while the github service has not read it yet;
      #   each branch the card names (its title, description and comments — the words CardLinks links as branches)
      #     that the scanner saw (projects.branch_tips): its tip shas — never a base branch (the checkout's branch, each
      #     remote's default branch = projects.remote_heads, the enrolment's local / public base): those move with
      #     every other card's merge.
      # A PR the github service cannot answer, an assignment that names no PR, a project the scanner never read →
      # Unavailable (the engine skips the card and says why).
      PROGRESS_KINDS = ["the card's PR head", "the CI on that head", "commits on the branches the card names"].freeze
      BRANCHES_MAX = 10 # branches named on one card that are followed (sorted by name)

      def progress_kinds = PROGRESS_KINDS

      def progress(card)
        pr_progress(card) + branch_progress(card)
      end

      # The poll rows on the path of card's Approve of `step` that the github service does not answer
      # (CiChecks.stale_gates): never asked, or outside its window, or failed. step_checks is walked over the
      # stored rows by a dup of this port with @peek on — no poll request is written. The walk goes past a stale row
      # on its stored answer: the list is EVERY row the operator would wait for, while a real Approve
      # stops at the first (one refusal per click) — a superset of what one click names, never fewer.
      # → [{repo:, ref:, age: seconds since last asked | nil (never asked), error: the poll's error (only when failed),
      #     why: the github service is not answering (only then)}]
      def stale_reads(card, step)
        peek = dup
        peek.peek!
        peek.peek_reads(card, step)
      end

      def last_commit_at(card)
        return nil unless card[:owner_session]

        git = @launcher.git(session: card[:owner_session], socket: card[:owner_socket] || "default")
        git["last_commit_at"]
      end

      protected

      def peek! = (@peek = [])

      def peek_reads(card, step)
        begin
          step_checks(card, step)
        rescue Unavailable
          nil # the reads made before the port gave up are still listed; the refusal itself is the prefetch's log line
        end
        @peek.uniq # a step may read one row twice (Deploy check: the local PR's state, then its merge)
      end

      private

      def pr_progress(card)
        repo, ref = target(card)
        return [] unless repo

        row = answer(repo, ref)
        head = row[:head] or return []

        sha = head[0, 7]
        [{ kind: "pr head", key: head, text: "PR #{repo}##{row[:number]} head #{sha}" },
         { kind: "ci", key: [head, row[:state], row[:finished_at], *row[:builds]].compact.join(" "),
           text: "CI #{row[:state]} on #{sha}", },]
      end

      def branch_progress(card)
        project = @projects.call(card[:project_slug]) or raise Unavailable, "no project #{card[:project_slug]}"
        raw = project[:branch_tips] or raise Unavailable, "#{card[:project_slug]} has not been read by the scanner yet"
        heads = project[:remote_heads] or raise Unavailable, "#{card[:project_slug]} has not been read by the scanner yet"

        tips = JSON.parse(raw)
        comments = @db[:card_activity].where(card_id: card[:id], kind: "comment").select_map(:body)
        text = [card[:title], card[:notes], *comments].compact.join("\n")
        words = text.scan(AgentsKanban::CardLinks::WORD).to_set { |w| w.sub(/[.,;:!?)]+\z/, "") }
        # a base branch moves with every other card's merge: it says nothing about THIS card — the
        # checkout's branch, each remote's default branch (its HEAD: `main` on a plain repo too), the enrolment's bases
        bases = [project[:default_ref], *JSON.parse(heads), project[:local_base], project[:public_base]].compact
        ((words & tips.keys.to_set) - bases).sort.first(BRANCHES_MAX).map do |b|
          shas = tips.fetch(b)
          { kind: "branch #{b}", key: shas.join(" "), text: "branch #{b} at #{shas.map { |x| x[0, 7] }.join('/')}" }
        end
      end

      def built!(card, answer)
        return answer unless card.key?(:handoff_ci_url)

        url = card[:handoff_ci_url].to_s.strip
        return answer if url.empty? || answer.nil? || answer[:state] != "success"
        return answer if answer[:builds]&.include?(url)

        builds = answer[:builds].to_a.empty? ? "no required check names a build" : answer[:builds].join(", ")
        head = answer[:head] ? answer[:head][0, 7] : "the commit read"
        blocked(answer[:number], "ci_url #{url} is not the build of #{head} (#{builds}) — hand off with the head's build")
      end

      def step_checks(card, step)
        project = @projects.call(card[:project_slug])
        unless project && project[:local_mode]
          row = pr_checks(card)
          return mergeable(row, row && target(card).first, row&.dig(:number), nil, nil)
        end

        repo, number = local_pr(card, project)
        unless step[:final]
          state = answer(repo, "pr:#{number}")[:state]
          if first_step?(card, step)
            case state
            when "merged"
              # approved once already (an approve after the newest handoff), merged, then the card was moved
              # back into the gate: nothing is left to approve, the merge commit's CI answers
              return merge_ci(repo, number) if approved_after_handoff?(card)

              return blocked(number, "the local PR ##{number} was merged before its approval")
            when "closed" then return blocked(number, "the local #{closed(repo, number)}")
            when "none" then return blocked(number, "the local PR ##{number} was not found on #{repo}")
            end

            return mergeable(read(repo, "pr:#{number}"), repo, number, "local", -> { base_of(card, project, :local_base) })
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

        _, number = PrStates.assigned(card, PrStates::ROLES[:public], repo)
        raise Unavailable, unassigned(card, PrStates::ROLES[:public], repo) unless number

        mergeable(read(repo, "pr:#{number}"), repo, number, "public", -> { base_of(card, project, :public_base) })
      rescue PrStates::Invalid => e
        raise Unavailable, e.message
      end

      # An open PR the approval would let through only when it can merge as it stands — refused (state
      # "blocked" + the reason) when it is a draft, is based on another branch than its side's (want_base; nil = a
      # plain project's PR, any base; a Proc: asked only for a read PR), conflicts with its base, has GitHub's
      # auto-merge on (GitHub would merge it on green, without the board's approval), or GitHub is still computing
      # whether it merges (mergeable null: never guessed). `behind` is NOT refused: the working branch moves on every
      # other card's merge, and a conflict never parks a card — the rail warns, the merge itself is where it counts.
      # Not read yet (unpolled) or no open PR → the row as it is.
      def mergeable(row, repo, number, role, want_base)
        return row unless row && CHECKED.include?(row[:state])

        want_base = want_base&.call

        pr = "the #{[role, 'PR'].compact.join(' ')} ##{number}"
        why = if !row.key?(:draft) # a row the github service answered before it read these fields
                "#{pr}'s draft / base / mergeable state is not read yet (asked now — try again in a minute)"
              elsif row[:draft] then "#{pr} is a draft"
              elsif want_base && row[:base] != want_base
                "#{pr} is based on #{row[:base]}, not #{want_base}"
              elsif row[:merge_state] == "conflicts" then "#{pr} has conflicts with #{row[:base]}"
              elsif row[:auto_merge]
                "#{pr} has GitHub auto-merge on: GitHub would merge it on green CI without the board's approval — " \
                  "turn it off (gh pr merge --disable-auto #{number} -R #{repo})"
              elsif row[:merge_state] == "computing"
                "GitHub is still computing whether #{pr} merges cleanly (asked now — try again in a minute)"
              elsif row[:merge_state]&.start_with?(PrStates::UNKNOWN) # a value busyyaks does not know: never passed
                "#{pr}'s mergeability is #{row[:merge_state]}: GitHub answered a state busyyaks does not know"
              end
        why ? blocked(number, why) : row
      end

      # The branch the card's `side` PR must be based on (the scanner's local_base / public_base); not known → the
      # approval is refused with the enrolment's reason, never let through on any base.
      def base_of(card, project, side)
        project[side] || raise(Unavailable, "card ##{card[:id]}: the #{side.to_s.delete_suffix('_base')} PR's base " \
                                            "branch is not known: #{project[:local_error] || 'the scanner has not ' \
                                                                                            'read the enrolment yet'}")
      end

      # → [[role, owner/name, number], …] every PR assigned to the card: `local` + `public` on an enrolled project, `pr`
      # on any other (PrStates.assigned); an assignment or enrolment that cannot be read is added to `errors`.
      def assigned_prs(card, errors)
        project = @projects.call(card[:project_slug])
        # not enrolled: the `pr` PR on whichever repo its URL names (repo nil = any)
        return pr_of(card, PrStates::ROLES[:pr], nil, errors) unless project && project[:local_mode]

        [[PrStates::ROLES[:local], project[:local_repo]], [PrStates::ROLES[:public], project[:public_repo]]]
          .flat_map do |role, remote|
          repo = PrStates.slug(remote)
          next pr_of(card, role, repo, errors) if repo

          # a PR assigned on a side whose repo cannot be named is an error; an unassigned side is nothing
          if PrStates.assigned(card, role, nil)
            errors << "#{role} PR: #{project[:local_error] || "the #{role} repo is not on github.com"}"
          end
          []
        rescue PrStates::Invalid => e
          errors << e.message
          []
        end
      end

      def pr_of(card, role, repo, errors)
        r, number = PrStates.assigned(card, role, repo)
        number ? [[role, r, number]] : []
      rescue PrStates::Invalid => e
        errors << e.message
        []
      end

      # one assigned PR for the PR watch: its close, its error, or nil (open, merged, not read yet)
      def closed_pr(role, repo, number)
        st = @states.lookup(repo, "pr:#{number}")
        return { error: "#{role} PR ##{number} on #{repo}: #{st[:error]}" } if st[:error]
        return nil unless st[:state] == "closed" && st[:reason]
        unless st[:closed_at]
          return { error: "#{role} PR ##{number} on #{repo}: closed, #{st[:reason].delete_prefix(PrStates::UNKNOWN)}" }
        end

        { role: role, number: number, closed_at: st[:closed_at], why: said(st[:reason]) }
      end

      def said(reason) = reason.start_with?(PrStates::UNKNOWN) ? "reason #{reason}" : reason

      # Why the PR closed without merging (gh_pr_states: its issue events), or what is not known yet.
      def closed_why(repo, number)
        st = @states.lookup(repo, "pr:#{number}")
        return said(st[:reason]) if st[:reason]

        st[:error] ? "why unknown: #{st[:error]}" : "why not read yet"
      end

      def closed(repo, number) = "PR ##{number} closed without merging (#{closed_why(repo, number)})"

      # → [owner/name, number] of the card's `local` PR on the project's local repo. None → Unavailable.
      def local_pr(card, project)
        repo = PrStates.slug(project[:local_repo])
        unless repo
          raise Unavailable, "the local PR of card ##{card[:id]} cannot be found: " \
                             "#{project[:local_error] || 'the local repo is not on github.com'}"
        end

        pr = PrStates.assigned(card, PrStates::ROLES[:local], repo)
        pr || raise(Unavailable, unassigned(card, PrStates::ROLES[:local], repo))
      end

      def unassigned(card, role, repo)
        "card ##{card[:id]} has no #{role} PR assigned (kanban_pr_assign role #{role}, a PR on #{repo})"
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

      # Did the operator approve the first step after the card's newest handoff INTO that step's gate? Read off the
      # entries the engine writes itself (never an agent's text, never a PR named in it): a `handoff` entry
      # "handed to <gate>: …" and an `approve` entry "approved <gate> → …", logged by an approval move only. A later
      # handoff into another gate (e.g. the deploy check after the merge) hides no approval of the first step; a new
      # handoff into the first gate asks for a new one.
      def approved_after_handoff?(card)
        gate = @approvals.call(card[:project_slug]).first&.fetch(:from_label)
        return false unless gate

        acts = @db[:card_activity].where(card_id: card[:id], kind: %w[handoff approve]).order(Sequel.desc(:id))
                                  .select_map(%i[kind body])
        handed = acts.index { |kind, body| kind == "handoff" && body.start_with?("handed to #{gate}:") }
        !handed.nil? && acts.first(handed).any? { |kind, body| kind == "approve" && body.start_with?("approved #{gate} →") }
      end

      # The board's first approval step (the engine's derivation order: board order).
      def first_step?(card, step) = @approvals.call(card[:project_slug]).first&.fetch(:from) == step[:from]

      def blocked(number, reason) = { number: number, state: "blocked", finished_at: nil, reason: reason }

      # → nil when the local PR is merged, else the refusal (engine `reason:`): not read yet, open, closed.
      def local_unmerged(repo, number)
        row = answer(repo, "pr:#{number}")
        return nil if row[:state] == "merged"
        return blocked(number, "the local #{closed(repo, number)}") if row[:state] == "closed"

        what = case row[:state]
               when "unpolled" then "not read yet (asked now — try again in a minute)"
               when "none" then "not found"
               else "still open, not merged into the local repo"
               end
        { number: row[:number], state: "blocked", finished_at: nil, reason: "the local PR ##{number} is #{what}" }
      end

      # The polled answer for repo + ref, registering the request ("I want this") — never a guess. No PR, or a merged
      # one → nil; closed without merging → blocked, saying why (a gate never refuses it with the generic "no PR").
      def read(repo, ref)
        row = answer(repo, ref)
        return blocked(row[:number], closed(repo, row[:number])) if row[:state] == "closed"
        return nil if %w[none merged].include?(row[:state])
        return row.merge(reason: "PR ##{row[:number]}: CI stuck — #{row[:detail]}") if row[:state] == "stuck"

        row
      end

      # The poll row's answer, any state. A request last made longer ago than wanted_for has fallen out of the github
      # service's window (it polls only recent requests): its old answer is dropped and it is asked again — unless
      # that answer is itself fresh (read within stale_after, no error): the service's last poll of the window can
      # land seconds before the request ages out, and that read is used as it is (dropping it refused a
      # handoff "CI not read yet" while a green for the same head was stored).
      # Inside the window, an unanswered or old answer still means the service is not answering → Unavailable.
      def answer(repo, ref)
        now = @clock.call
        row = @db[:gh_pr_checks].where(repo: repo, ref: ref).first
        return peek_answer(repo, ref, row, now) if @peek
        if row && now - row[:requested_at] > @wanted_for && !fresh?(row, now)
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

        answered(row)
      end

      # stale_reads' answer: the row as stored, nothing written; a request the poller dropped (or never got) is noted
      def peek_answer(repo, ref, row, now)
        if row&.dig(:error)
          # Approve raises Unavailable on it ("GitHub check poll … failed"): listed with the poll's error
          @peek << { repo: repo, ref: ref, age: now - row[:requested_at], error: row[:error] }
        elsif row.nil? || now - row[:requested_at] > @wanted_for
          @peek << { repo: repo, ref: ref, age: row && (now - row[:requested_at]) }
        elsif stalled(row, now)
          # Approve raises Unavailable on it too (answer: unpolled after stale_after, or an answer older than that)
          @peek << { repo: repo, ref: ref, age: now - row[:requested_at], why: stalled(row, now) }
        end
        return { number: nil, state: "unpolled", finished_at: nil } if row.nil? || row[:error] || row[:checked_at].nil?

        answered(row)
      end

      # Why answer raises Unavailable on a row inside the window that the github service is not answering, or nil
      def stalled(row, now)
        if row[:checked_at].nil?
          "requested, not polled within #{@stale_after}s (github service running?)" if now - row[:requested_at] > @stale_after
        elsif now - row[:checked_at] > @stale_after
          "answer older than #{@stale_after}s (github service stopped?)"
        end
      end

      # a polled row as the gate reads it
      def answered(row)
        out = { number: row[:number], state: row[:state], finished_at: row[:finished_at] }
        out[:head] = row[:head] if row[:head] # the PR head sha (a pr: row; a merge: row has none)
        %i[base draft merge_state auto_merge].each { |k| out[k] = row[k] unless row[k].nil? } # an open pr: row's
        out[:builds] = JSON.parse(row[:builds]) if row[:builds] # the required checks' build URLs
        row[:detail] ? out.merge(detail: row[:detail]) : out
      end

      # an answer the github service read within stale_after, without an error
      def fresh?(row, now) = !row[:error] && row[:checked_at] && now - row[:checked_at] <= @stale_after

      # → [owner/name, "pr:N"] of the PR the idle watch follows | nil when none is assigned: on an enrolled project the
      # card's `local` PR (on the local repo), on any other its `pr` PR (its URL names the repo). An assignment that is
      # no PR of its repo, or an enrolment whose local repo cannot be read → Unavailable (the watch says why).
      def target(card)
        project = @projects.call(card[:project_slug])
        if project && project[:local_mode]
          repo = PrStates.slug(project[:local_repo])
          unless repo
            raise Unavailable, "the local PR of card ##{card[:id]} cannot be found: " \
                               "#{project[:local_error] || 'the local repo is not on github.com'}"
          end
          _, number = PrStates.assigned(card, PrStates::ROLES[:local], repo)
        else
          repo, number = PrStates.assigned(card, PrStates::ROLES[:pr], nil)
        end
        number ? [repo, "pr:#{number}"] : nil
      rescue PrStates::Invalid => e
        raise Unavailable, e.message
      end
    end

    # The github service's side. Every read is conditional (If-None-Match on the ETag GitHub gave for that URL last
    # time, kept in gh_pages under `ci:<fields>:<url>` with the fields the poller reads — KEEP, never the whole response): an
    # unchanged PR or check list answers 304, which GitHub does not count against the token's rate limit — a card
    # waiting days in a gate, its checks asked every minute (the engine's approval prefetch, card #247), costs nothing
    # while its PR stands still. A cached URL nobody read for wanted_for (a pushed-over sha, a card out of the gate)
    # is deleted at the end of each run. While `gate` (GithubPollers) is paused — the token's rate limit used up —
    # nothing is sent and every wanted row says why and until when.
    class Poller
      KEEP = %w[number state merged_at merge_commit_sha head base sha ref statuses updated_at check_runs status
                conclusion completed_at commit total_count context name created_at started_at target_url
                details_url check_suite id draft mergeable mergeable_state auto_merge].freeze
      PAGE = "ci:"
      PER_PAGE = 100 # GitHub's maximum for both commit status and check-run lists

      def self.cache_key(url) = GithubNetwork.cache_key(PAGE, KEEP, url)

      # ci: CiSettings::Settings (config/busyyaks.yml ci) — the contexts that gate per repo + the stuck limit
      def initialize(db:, client:, gate:, wanted_for:, ci:, clock: -> { Busyyaks::Clock.epoch })
        @db = db
        @client = client
        @gate = gate
        @pages = GithubNetwork::Data.new(db)
        @wanted_for = wanted_for # seconds a request stays interesting after the notifier last asked
        @ci = ci
        @clock = clock
      end

      # → number of rows answered (0 while paused). One row's failure — GitHub's, or any other (a body of an unexpected
      # shape, a bug) — is stored on that row and said by the Port; the rest of the batch still runs (as
      # PrStates::Poller). A rate-limited answer is the token's: it pauses the gate and fails the rest of the batch.
      def run
        now = @clock.call
        # in id order: one batch, the same order on every database (PostgreSQL returns an updated row last)
        rows = @db[:gh_pr_checks].where(Sequel.lit("requested_at >= ?", now - @wanted_for)).order(:id).all
        paused = @gate.paused
        if paused
          rows.each { |row| fail_row(row, paused) }
          return 0
        end

        rows.each_with_index do |row, i|
          cleared = { detail: nil, head: nil, builds: nil, base: nil, draft: nil, merge_state: nil, auto_merge: nil }
          answer = cleared.merge(poll(row)).merge(checked_at: now, error: nil)
          @db[:gh_pr_checks].where(id: row[:id]).update(answer)
        rescue GithubNetwork::RateLimited => e # the token's limit: the rest of the batch would fail the same way
          why = @gate.rate_limited!(e)
          rows[i..].each { |r| fail_row(r, why) }
          break
        rescue StandardError => e
          fail_row(row, [GithubNetwork::Error, Unconfigured].any? { |k| e.is_a?(k) } ? e.message : "#{e.class}: #{e.message}")
        end
        @db[:gh_pages].where(Sequel.like(:url, "#{PAGE}%")).where(Sequel.lit("at < ?", now - @wanted_for)).delete
        rows.size
      end

      private

      def fail_row(row, error) = @db[:gh_pr_checks].where(id: row[:id]).update(error: error[0, 500], checked_at: nil)

      # One conditional GET → the body's KEEP fields (a 304 = the stored ones, its row marked read now); a 404 with
      # missing_ok → nil.
      def get(url, missing_ok: false)
        key = self.class.cache_key(url)
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
        # pr:<n> = a PR assigned to a card, merge:<n> = its merge commit's CI
        raise GithubNetwork::Error, "#{repo} #{row[:ref]}: not a pr:<n> / merge:<n> ref" unless %w[pr merge].include?(kind)

        pr = get("/repos/#{repo}/pulls/#{Integer(name)}", missing_ok: true)
        return { number: nil, state: "none", finished_at: nil } unless pr
        return merge_checks(repo, pr) if kind == "merge"
        # merged (the public step needs the local PR merged) vs closed unmerged
        unless pr["state"] == "open"
          return { number: pr["number"], state: pr["merged_at"] ? "merged" : "closed", finished_at: nil }
        end

        sha = pr.dig("head", "sha")
        # head: the engine's approvable-now check; base · draft · merge_state · auto_merge: the gate's
        { number: pr["number"], head: sha, base: pr.dig("base", "ref"), draft: pr["draft"] == true,
          merge_state: PrStates.merge_state(pr), auto_merge: !pr["auto_merge"].nil?, }.merge(checks(repo, sha))
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
        return base.merge(own).merge(detail: "merge commit #{sha[0, 7]}: #{own[:detail]}") unless own[:state] == "nochecks"

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

        read = checks(repo, head)
        base.merge(read).merge(detail: "merge commit #{sha[0, 7]} has no checks of its own; read #{branch} head " \
                                       "#{head[0, 7]}, which contains it: #{read[:detail]}")
      end

      # One check on the commit, whatever posted it: a commit status (Jenkins) or a check run (Actions).
      Check = Struct.new(:context, :state, :started, :at, :url)

      # The commit's CI, judged on the repo's REQUIRED contexts only (config ci.required; every other check is
      # informational, named in `detail` when it fails): a required one pending → pending, or `stuck` once it has been
      # pending longer than ci.max_pending_minutes (finished_at = the moment it became stuck: one gate ping per stuck
      # build); one not reported → nochecks; all finished → failure when any failed, else success. `builds` = the
      # required checks' build URLs (a handoff's ci_url must be one of them). A repo with no required contexts → refused.
      def checks(repo, sha)
        required = @ci.required_for(repo)
        unless required
          raise Unconfigured, "no required CI contexts for #{repo}: config/busyyaks.yml ci.required does not list it"
        end

        all = statuses(repo, sha) + runs(repo, sha)
        req = all.select { |c| required.include?(c.context) }
        failing = (all - req).select { |c| c.state == "failure" }.map(&:context)
        note = failing.any? ? "; informational, failing: #{failing.uniq.join(', ')}" : ""
        out = { builds: JSON.generate(req.filter_map(&:url).uniq) }
        running = req.select { |c| c.state == "pending" }
        return out.merge(pending(running, note)) if running.any?

        missing = required - req.map(&:context)
        if missing.any?
          return out.merge(state: "nochecks", finished_at: nil,
                           detail: "required #{missing.join(', ')} not reported on #{sha[0, 7]}#{note}")
        end

        bad = req.select { |c| c.state == "failure" }.map(&:context)
        undated = req.reject(&:at).map(&:context)
        if undated.any? # a finished check GitHub gives no finish time: its completion is unknown, never assumed
          raise GithubNetwork::Error, "#{repo} #{sha[0, 7]}: finished check #{undated.uniq.join(', ')} has no completion time"
        end

        out.merge(state: bad.any? ? "failure" : "success", finished_at: req.map(&:at).max,
                  detail: "#{bad.any? ? "failed: #{bad.uniq.join(', ')}" : "passed: #{required.join(', ')}"}#{note}")
      end

      def pending(checks, note)
        max = @ci.max_pending_seconds
        stuck = checks.select { |c| c.started && @clock.call - c.started > max }
        if stuck.any?
          since = stuck.map(&:started).min
          return { state: "stuck", finished_at: since + max,
                   detail: "#{stuck.map(&:context).uniq.join(', ')} pending since #{Time.at(since).utc.iso8601}, over " \
                           "ci.max_pending_minutes #{@ci.max_pending_minutes}#{note}", }
        end

        { state: "pending", finished_at: nil, detail: "running: #{checks.map(&:context).uniq.join(', ')}#{note}" }
      end

      # The combined status (Jenkins posts these: the latest status per context; created_at = when that state was posted).
      def statuses(repo, sha)
        paged("/repos/#{repo}/commits/#{sha}/status", "statuses").map do |s|
          state = case s["state"]
                  when "success", "pending" then s["state"]
                  when "failure", "error" then "failure"
                  else raise GithubNetwork::Error, "#{repo} #{sha[0, 7]}: status #{s['context']} is #{s['state'].inspect}"
                  end
          Check.new(s["context"], state, time(s["created_at"]), time(s["updated_at"]), s["target_url"])
        end
      end

      # Check runs (Actions; GitHub's default filter=latest: a re-run replaces the run it re-ran). A check run has no
      # created_at; a queued one may have no started_at yet — then its pending time counts from the LATER of its check
      # suite's created_at (one conditional read of that suite) and the first poll that saw THIS run (by its id)
      # pending: a run queued forever still becomes stuck, and a re-run (which reuses the old suite) queued hours after
      # the push starts its clock when it appeared, not at the suite's old created_at.
      def runs(repo, sha)
        paged("/repos/#{repo}/commits/#{sha}/check-runs", "check_runs").map do |r|
          state = if r["status"] != "completed" then "pending"
                  elsif BAD_RUN.include?(r["conclusion"]) then "failure"
                  else "success"
                  end
          started = time(r["started_at"]) || (state == "pending" ? [queued_at(repo, r), first_seen(repo, r)].max : nil)
          Check.new(r["name"], state, started, time(r["completed_at"]), r["details_url"])
        end
      end

      # When a poll first saw this run pending (gh_pages `ci:seen:<repo>:<run id>`, items = that time). Every sighting
      # touches the row's `at`, so the end-of-run prune drops it only once nobody has seen the run for wanted_for.
      def first_seen(repo, run)
        key = "#{PAGE}seen:#{repo}:#{Integer(run['id'])}"
        now = @clock.call
        row = @pages.page(key)
        if row
          @db[:gh_pages].where(url: key).update(at: now)
          return JSON.parse(row[:items])
        end

        @pages.save_page(key, "seen", now, items: now)
        now
      end

      def queued_at(repo, run)
        suite = run.dig("check_suite", "id")
        raise GithubNetwork::Error, "#{repo}: check run #{run['name']} has no started_at and no check suite" unless suite

        at = time(get("/repos/#{repo}/check-suites/#{Integer(suite)}")["created_at"])
        at || raise(GithubNetwork::Error, "#{repo}: check suite #{suite} of #{run['name']} has no created_at")
      end

      # Every page of a list GitHub counts (`total_count`): pages of PER_PAGE until all are read. A short page before
      # the total, or a body with no count → refused: an unread check is never taken for a passed one.
      def paged(path, key)
        items = []
        page = 1
        loop do
          body = get("#{path}?per_page=#{PER_PAGE}&page=#{page}")
          total = body["total_count"]
          got = body[key]
          unless total.is_a?(Integer) && got.is_a?(Array)
            raise GithubNetwork::Error, "#{path}: no total_count / #{key} in GitHub's answer"
          end

          items.concat(got)
          return items if items.size >= total
          if got.size < PER_PAGE
            raise GithubNetwork::Error, "#{path}: GitHub counts #{total} #{key} but #{items.size} were read " \
                                        "(page #{page} was short)"
          end

          page += 1
        end
      end

      def time(iso) = iso && Time.iso8601(iso).to_i
    end
  end
end
