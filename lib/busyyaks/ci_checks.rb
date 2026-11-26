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
require_relative "git_hosts"

module Busyyaks
  # PR check status for the kanban idle watch (config/kanban.yml idle_watch; the engine's CiChecks port).
  #
  # The GitHub token lives only in the `github` compose service, so the work is split over the db (gh_pr_checks):
  #   Port    (notifier)  — names the PR a card is about (the one its agents assigned to it: PrStates.assigned),
  #                         registers "I want this" (requested_at) and reads the answer. No token, no HTTP.
  #   Poller  (github)    — every github_ci_interval_seconds answers the recently requested rows through
  #                         GithubNetwork::Client.
  # A poll that failed, or answers older than `stale_after` seconds, make the Port raise Unavailable: the engine skips the
  # idle watch for that pass and says why. Nothing is guessed.
  module CiChecks
    FINISHED = %w[success failure].freeze
    CHECKED = %w[success failure pending nochecks].freeze # an open PR's pr:<N> answer (its checks read)
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
      # an age growing by one watch pass (the line carries the age, so it was said every pass).
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
      # WITHOUT merging, {role:, number:, repo:, closed_at:, why:}, and one {error:} per PR (or list) that cannot be read
      # — beside the closes, so a closed PR never hides another one's failure. A PR not read yet is not closed yet; nor
      # is a closed row whose reason was never read (polled before the reason existed): told once the poller re-reads it.
      # Every PR of the card's list (any role, any repo) is watched; each close names its repo (the engine
      # keys the watch per PR).
      def closed_prs(card)
        errors = []
        closed = assigned_prs(card, errors).filter_map { |role, repo, number| closed_pr(role, repo, number) }
        closed + errors.map { |e| { error: e } }
      end

      # → [[role, owner/name, number], …] every PR assigned to the card (PrStates.assigned: the list); a list
      # that cannot be read is added to `errors`.
      def assigned_prs(card, errors)
        PrStates.assigned(card).map { |p| [p[:role], p[:repo], p[:number]] }
      rescue PrStates::Invalid => e
        errors << e.message
        []
      end

      # The idle watch: every PR the card's agents assigned under its watched role (enrolled: `local`, any other: `pr`),
      # one answer for all of them (combine) — nil when none is assigned or none is open.
      def pr_checks(card)
        answers = targets(card).filter_map { |repo, number| tagged(read(repo, "pr:#{number}"), repo) }
        answers.empty? ? nil : combine(answers)
      end

      # The engine's approval gate (a gate column's requires_green_ci): what each approval step checks.
      # The PRs are the ones the card's agents ASSIGNED (kanban_pr_assign → metadata prs, a list; PrStates.assigned),
      # EVERY one of the step's role — a card may change several repos (busyyaks + the engine it vendors): all must be
      # green. A project that is not enrolled: its `pr` PRs, step by step (see plain_step).
      # An enrolled one works on its `local` PRs:
      #   - the board's FIRST approval step (Local: Human review) = every local PR OPEN with green checks (one merged
      #     ahead of the approval → refused);
      #   - a later non-final step (Local: Deploy check → Open public PR) = every local PR MERGED and the CI of each one's
      #     merge commit on its working branch green (`merge:<N>` — jenkins/ci on `local`);
      #   - the final step (the public merge) = every `public` PR green, and only once every local PR is MERGED.
      # None of the role assigned, or one that is no PR → Unavailable with the reason. Several PRs → one answer
      # (combine): the first that is not green, said with its repo; all green → success, `head` = every PR's head
      # joined by "+", `builds` = every PR's required builds.
      # An open PR a step reads must also be mergeable as it stands (#mergeable): not a draft, on its side's
      # base branch, no GitHub auto-merge, its mergeability computed (not asked at an Approve; behind: warned, not
      # refused) — every one of the step's PRs. A conflict with its base does not refuse: the green answer carries
      # rebase: and the engine accepts the approval marked needs rebase — the owner rebases, re-runs CI and merges on
      # green.
      # Asked for a HANDOFF (the engine passes handoff_ci_url = its ci_url, a key only a handoff carries), a green
      # answer is also checked against that ci_url: it must be the build of a required context on a commit the answer
      # read (`builds`, any of the PRs' heads) — never an older build, nor a URL naming no build. An Approve or a watch
      # pass asks only whether the heads' required checks are green: a rebuild of the same head after the handoff never
      # parks the card.
      def approval_checks(card, step)
        # no git host connected (Settings → Git hosts): nothing can be read, so nothing is green — refused
        # naming why, never "not read yet" (that would wait forever)
        return blocked(nil, GitHosts.not_connected) unless GitHosts.github_login(@db)

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

      # Every PR the card's agents assigned (a list — the idle watch's targets), each its head + that head's
      # CI; with several PRs each kind names its PR ("pr head o/r#5"), one PR keeps the plain kinds.
      def pr_progress(card)
        prs = targets(card)
        prs.flat_map do |repo, number|
          row = answer(repo, "pr:#{number}")
          head = row[:head] or next []

          sha = head[0, 7]
          of = prs.size > 1 ? " #{repo}##{number}" : ""
          [{ kind: "pr head#{of}", key: head, text: "PR #{repo}##{number} head #{sha}" },
           { kind: "ci#{of}", key: [head, row[:state], row[:finished_at], *row[:builds]].compact.join(" "),
             text: "CI #{row[:state]} on #{sha}#{of.empty? ? '' : " (#{repo}##{number})"}", },]
        end
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
        # several PRs: every head, each shortened (abc1234+def5678), as the engine's short_heads says them
        head = answer[:head] ? answer[:head].split("+").map { |h| h[0, 7] }.join("+") : "the commit read"
        blocked(answer[:number], "ci_url #{url} is not the build of #{head} (#{builds}) — hand off with the head's build")
      end

      def step_checks(card, step)
        project = @projects.call(card[:project_slug])
        return plain_step(card, step) unless project && project[:local_mode]

        locals = prs!(card, PrStates::ROLES[:local])
        unless step[:final]
          if first_step?(card, step)
            local_base = ->(repo) { base_of(card, project, repo, "local") }
            return combine(locals.map { |repo, number| tagged(first_step_pr(card, repo, number, local_base), repo) })
          end

          # the merge commit's CI on the working branch, for each local PR once it is merged
          return combine(locals.map { |repo, number| tagged(local_unmerged(repo, number) || merge_ci(repo, number), repo) })
        end

        unmerged = locals.filter_map { |repo, number| tagged(local_unmerged(repo, number), repo) }
        return combine(unmerged) unless unmerged.empty?

        gate_checks(card, prs!(card, PrStates::ROLES[:public]), "public", ->(repo) { base_of(card, project, repo, "public") })
      rescue PrStates::Invalid => e
        raise Unavailable, e.message
      end

      # A project that is not enrolled (its `pr` PRs): its first and final step = every `pr` PR open and green
      # (a merged one left out, as gate_checks says). A step between them is read per PR as it stands — the workflow
      # does not say which steps follow its merge: one still OPEN answers with its head, as every step did before (a
      # review gate before the merge is unchanged); one MERGED with its merge commit's CI (`merge:<N>`, ci.required —
      # never the PR head: a Deploy check after the board's merge, e.g. Staging: Merged → Staging: Deploy check); closed
      # unmerged or not found blocks, named repo#N.
      def plain_step(card, step)
        prs = targets(card)
        return gate_checks(card, prs, nil, nil) if prs.empty? || step[:final] || first_step?(card, step)

        combine(prs.map do |repo, number|
          merged = answer(repo, "pr:#{number}")[:state] == "merged"
          tagged(merged ? merge_ci(repo, number, nil) : gate_read(card, repo, number, nil, nil), repo)
        end)
      end

      # An approval over several PRs of one role (the final step's public PRs, a plain project's `pr` PRs): only a
      # MERGED one is done and left out; one closed without merging or not found is never dropped — it blocks, named
      # repo#N (two public PRs, one closed, the other green, must not approve the merge). Every PR
      # merged → nil (the engine: no PR whose checks could be read). Each open one must be mergeable: role
      # and want_base as `mergeable` takes them. A card marked needs rebase whose PR merged since: that
      # merge commit's CI answers (merged_since_mark), never "nothing to read".
      def gate_checks(card, prs, role, want_base)
        answers = prs.filter_map { |repo, number| tagged(gate_read(card, repo, number, role, want_base), repo) }
        answers.empty? ? nil : combine(answers)
      end

      # An open PR the approval would let through only when it can merge as it stands — refused (state
      # "blocked" + the reason) when it is a draft, is based on another branch than its side's (want_base; nil = a
      # plain project's PR, any base; a Proc of the PR's repo: asked only for a read PR), has GitHub's auto-merge on
      # (GitHub would merge it on green, without the board's approval), or — unread, refused the same way (`unpolled` +
      # the reason) — GitHub is still computing whether it merges (mergeable null: never guessed), except at the
      # operator's Approve (computing_approvable?).
      # `behind` is NOT refused: the working branch moves on every other card's merge,
      # and a conflict never parks a card — the rail warns, the merge itself is where it counts. Conflicts with its base
      # are not refused either: the row gains rebase: {state: "conflicts", base:, base_sha:} — the engine accepts the
      # approval (its CI still decides: a red or pending one refuses first), marks the card needs rebase and holds its
      # onward move until an answer comes back green without it. A conflicting row whose base commit was not read yet
      # is refused as not read, never guessed.
      # Not read yet (unpolled) or no open PR → the row as it is.
      def mergeable(card, row, repo, number, role, want_base)
        return row unless row && CHECKED.include?(row[:state])

        want_base = want_base&.call(repo)

        pr = "the #{[role, 'PR'].compact.join(' ')} ##{number}"
        # a row the github service answered before it read these fields
        unless row.key?(:draft)
          return unread(number, "#{pr}'s draft / base / mergeable state is not read yet (asked now — try again in a minute)")
        end

        why = merge_refusal(row, pr, repo, number, want_base)
        return blocked(number, why) if why

        unknown = merge_unknown(row, pr)
        return computing_approvable?(card, row) ? row : unread(number, unknown) if unknown

        return row unless row[:merge_state] == "conflicts"

        row.merge(rebase: { state: "conflicts", base: row[:base], base_sha: row[:base_sha] })
      end

      # Every merge into the base makes GitHub compute every open PR's mergeability afresh — for a poll or
      # two (~2 min) each PR waiting in a gate read `computing`, and the operator's Approve was refused 422 over and
      # over while other cards merged. Both answers it can turn into are approvable (clean; conflicts → approved marked
      # needs rebase), so at an Approve (a card not approved yet, no handoff) it refuses nothing: the row as read,
      # merge_state "computing" kept, no rebase: (nothing known to rebase onto) — the owner's merge itself meets a
      # conflict if there is one, and the approved card's quiet ping reads it again (approved → unread, below).
      # Still not read yet: at a HANDOFF (handoff_ci_url — a conflicting PR is never handed in), for a card marked
      # needs rebase (its mark clears only on a known clean answer) and for an APPROVED card (its next step waits for
      # a known answer). A conflict computed after such an Approve is not marked needs rebase (the mark is written
      # only by the Approve's own answer), and need not be: the approved card's step is read again on every watch pass
      # (engine approved_ci_pass / approved_nudge), its answer then carries rebase: and its owner's ping says it is
      # held on the conflict; GitHub refuses the merge of a conflicting PR.
      def computing_approvable?(card, row)
        row[:merge_state] == "computing" && !card.key?(:handoff_ci_url) && !card[:needs_rebase] && !card[:approved_at]
      end

      # What GitHub says refuses this PR as it stands, or nil.
      def merge_refusal(row, pr, repo, number, want_base)
        if row[:draft] then "#{pr} is a draft"
        elsif want_base && row[:base] != want_base
          "#{pr} is based on #{row[:base]}, not #{want_base}"
        elsif row[:auto_merge]
          "#{pr} has GitHub auto-merge on: GitHub would merge it on green CI without the board's approval — " \
            "turn it off (gh pr merge --disable-auto #{number} -R #{repo})"
        elsif row[:merge_state]&.start_with?(PrStates::UNKNOWN) # a value busyyaks does not know: never passed
          "#{pr}'s mergeability is #{row[:merge_state]}: GitHub answered a state busyyaks does not know"
        end
      end

      # What is not known yet about whether this PR merges, or nil: an unread answer, which refuses like any non-green one.
      def merge_unknown(row, pr)
        if row[:merge_state] == "computing"
          "GitHub is still computing whether #{pr} merges cleanly (asked now — try again in a minute)"
        elsif row[:merge_state] == "conflicts" && !row[:base_sha]
          "#{pr} has conflicts with #{row[:base]}; its base commit is not read yet (asked now — try again in a minute)"
        end
      end

      # The branch the card's `side` PR on `repo` must be based on: the scanner's local_base / public_base of the
      # enrolled project whose `side` repo that is (PrStates.side_base — the PR may be on another project's
      # repo; the card's own project counts as enrolled); not known → the approval is refused with the reason, never
      # let through on any base.
      def base_of(card, project, repo, side)
        rows = [project] + @db[:projects].exclude(local_mode: nil).order(:slug).all
        base, why = PrStates.side_base(rows, repo, side)
        base || raise(Unavailable, "card ##{card[:id]}: the #{side} PR #{repo}'s base branch is not known: #{why}")
      end

      # one assigned PR for the PR watch: its close, its error, or nil (open, merged, not read yet)
      def closed_pr(role, repo, number)
        st = @states.lookup(repo, "pr:#{number}")
        return { error: "#{role} PR ##{number} on #{repo}: #{st[:error]}" } if st[:error]
        return nil unless st[:state] == "closed" && st[:reason]
        unless st[:closed_at]
          return { error: "#{role} PR ##{number} on #{repo}: closed, #{st[:reason].delete_prefix(PrStates::UNKNOWN)}" }
        end

        { role: role, number: number, repo: repo, closed_at: st[:closed_at], why: said(st[:reason]) }
      end

      def said(reason) = reason.start_with?(PrStates::UNKNOWN) ? "reason #{reason}" : reason

      # Why the PR closed without merging (gh_pr_states: its issue events), or what is not known yet.
      def closed_why(repo, number)
        st = @states.lookup(repo, "pr:#{number}")
        return said(st[:reason]) if st[:reason]

        st[:error] ? "why unknown: #{st[:error]}" : "why not read yet"
      end

      # a card holds PRs of several repos: the PR is named with its repo
      def closed(repo, number) = "PR #{repo}##{number} closed without merging (#{closed_why(repo, number)})"

      def gate_read(card, repo, number, role, want_base)
        case answer(repo, "pr:#{number}")[:state]
        when "merged" then merged_since_mark(card, repo, number, role)
        when "closed" then blocked(number, "the #{closed(repo, number)}")
        when "none" then blocked(number, "the PR #{repo}##{number} was not found")
        else mergeable(card, read(repo, "pr:#{number}"), repo, number, role, want_base)
        end
      end

      # The first step for one local PR: open and green; merged ahead of the approval / closed / not found → blocked.
      def first_step_pr(card, repo, number, want_base)
        case answer(repo, "pr:#{number}")[:state]
        when "merged"
          # approved once already (an approve after the newest handoff), merged, then the card was moved back into the
          # gate: nothing is left to approve, the merge commit's CI answers
          return merge_ci(repo, number) if approved_after_handoff?(card)

          blocked(number, "the local PR #{repo}##{number} was merged before its approval")
        when "closed" then blocked(number, "the local #{closed(repo, number)}")
        when "none" then blocked(number, "the local PR #{repo}##{number} was not found")
        else
          mergeable(card, read(repo, "pr:#{number}"), repo, number, "local", want_base) ||
            unread(number, "the local PR #{repo}##{number} cannot be read")
        end
      end

      # → [[owner/name, number], …] of the card's PRs under `role`, as assigned. None → Unavailable.
      def prs!(card, role)
        prs = PrStates.assigned(card, role).map { |p| [p[:repo], p[:number]] }
        return prs unless prs.empty?

        raise Unavailable, "card ##{card[:id]} has no #{role} PR assigned (kanban_pr_assign role #{role})"
      end

      # the repo an answer is about, kept beside it until combine says it (numbers overlap between repos)
      def tagged(answer, repo) = answer && answer.merge(repo: repo)

      WORDS = { "failure" => "CI failed", "stuck" => "CI is stuck", "pending" => "CI is still running",
                "unpolled" => "CI not read yet (asked now)", "nochecks" => "no CI checks ran", }.freeze

      # Several PRs' answers → one, as the engine reads a single PR's: the first red one (failure · stuck · blocked),
      # else the first that is not green — its reason naming its repo; every one green → success with every head
      # ("+"-joined, in assignment order) and every build. One answer is that answer as it was.
      def combine(answers)
        answers = answers.compact
        return answers.first.except(:repo) if answers.size == 1

        bad = answers.find { |a| %w[failure stuck blocked].include?(a[:state]) } ||
              answers.find { |a| a[:state] != "success" }
        if bad
          why = bad[:reason] || "PR ##{bad[:number]}: #{WORDS.fetch(bad[:state], "CI state #{bad[:state]}")}"
          return bad.except(:repo).merge(reason: why.include?(bad[:repo]) ? why : "#{bad[:repo]} #{why}")
        end

        # a PR that conflicts with its base: its rebase: and number go with the green answer — the engine
        # marks the card needs rebase on that PR
        conflicting = answers.find { |a| a[:rebase] }
        out = { number: (conflicting || answers.first)[:number], state: "success",
                finished_at: answers.filter_map { |a| a[:finished_at] }.max, }
        out[:rebase] = conflicting[:rebase] if conflicting
        heads = answers.map { |a| a[:head] }
        out[:head] = heads.join("+") if heads.all?
        builds = answers.flat_map { |a| a[:builds].to_a }
        out[:builds] = builds unless builds.empty?
        out
      end

      # The merge:<N> answer; anything but green carries what was read (the shas) as the refusal's reason.
      def merge_ci(repo, number, role = "local")
        row = answer(repo, "merge:#{number}")
        return row if %w[success unpolled].include?(row[:state])

        # the CI's own state is kept (a red merge CI is "failure": the engine's gate watch pings the owner), the words
        # name what was read
        { number: number, state: row[:state], finished_at: row[:finished_at],
          reason: "#{role == 'local' ? 'jenkins/ci' : 'CI'} for the #{[role, 'PR'].compact.join(' ')} #{repo}##{number} " \
                  "merge is #{row[:state]}: #{row[:detail]}", }
      end

      # A card the engine marked needs rebase (it carries `needs_rebase`) whose step PR has since MERGED —
      # the rebase landed and the agent merged before a watch pass cleared the mark: the merge commit's CI answers (green
      # clears the mark, red / pending holds it), never "no PR" (which would hold the card for good). Only for a marked
      # card: an unmarked approval of a merged PR is refused as before. → nil when not marked or not merged.
      def merged_since_mark(card, repo, number, role)
        return nil unless card[:needs_rebase] && answer(repo, "pr:#{number}")[:state] == "merged"

        merge_ci(repo, number, role)
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

      # Nothing is known yet: its own state, never "blocked". It refuses an Approve and a handoff like every non-green
      # answer (the engine's green_ci!), holds a gate card, is never called red, and an approved card's ping says unread.
      def unread(number, reason) = { number: number, state: "unpolled", finished_at: nil, reason: reason }

      # → nil when the local PR is merged, else the refusal (engine `reason:`): not read yet, open, closed.
      def local_unmerged(repo, number)
        row = answer(repo, "pr:#{number}")
        return nil if row[:state] == "merged"
        return blocked(number, "the local #{closed(repo, number)}") if row[:state] == "closed"

        # not read is its own state, never "blocked": the engine says it is unread, and its gate watch never calls it red
        return unread(number,
"the local PR #{repo}##{number} is not read yet (asked now — try again in a minute)") if row[:state] == "unpolled"

        what = row[:state] == "none" ? "not found" : "still open, not merged into the local repo"
        { number: row[:number], state: "blocked", finished_at: nil, reason: "the local PR #{repo}##{number} is #{what}" }
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
        # an open pr: row's (base_sha: the base commit GitHub compared the PR with)
        %i[base base_sha draft merge_state auto_merge].each { |k| out[k] = row[k] unless row[k].nil? }
        out[:builds] = JSON.parse(row[:builds]) if row[:builds] # the required checks' build URLs
        row[:detail] ? out.merge(detail: row[:detail]) : out
      end

      # an answer the github service read within stale_after, without an error
      def fresh?(row, now) = !row[:error] && row[:checked_at] && now - row[:checked_at] <= @stale_after

      # → [[owner/name, number], …] of the PRs the idle watch follows ([] when none is assigned): on an enrolled
      # project the card's `local` PRs, on any other its `pr` PRs. A list that is not one of PRs → Unavailable (the
      # watch says why).
      def targets(card)
        project = @projects.call(card[:project_slug])
        role = project && project[:local_mode] ? PrStates::ROLES[:local] : PrStates::ROLES[:pr]
        PrStates.assigned(card, role).map { |p| [p[:repo], p[:number]] }
      rescue PrStates::Invalid => e
        raise Unavailable, e.message
      end
    end

    # The github service's side. Every read is conditional (If-None-Match on the ETag GitHub gave for that URL last
    # time, kept in gh_pages under `ci:<fields>:<url>` with the fields the poller reads — KEEP, never the whole response): an
    # unchanged PR or check list answers 304, which GitHub does not count against the token's rate limit — a card
    # waiting days in a gate, its checks asked every minute (the engine's approval prefetch), costs nothing
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
      # dirty: only the rows a GitHub webhook marked (GithubHook; card #472); every selected row's mark is cleared
      # unless a hook marked it again since.
      def run(dirty: false)
        now = @clock.call
        # in id order: one batch, the same order on every database (PostgreSQL returns an updated row last)
        scope = @db[:gh_pr_checks].where(Sequel.lit("requested_at >= ?", now - @wanted_for))
        rows = (dirty ? scope.exclude(dirty: nil) : scope).order(:id).all
        paused = @gate.paused
        if paused
          rows.each { |row| fail_row(row, paused) }
          clean(rows)
          return 0
        end

        rows.each_with_index do |row, i|
          cleared = { detail: nil, head: nil, builds: nil, base: nil, base_sha: nil, draft: nil, merge_state: nil,
                      auto_merge: nil, }
          answer = cleared.merge(poll(row)).merge(checked_at: now, error: nil)
          @db[:gh_pr_checks].where(id: row[:id]).update(answer)
        rescue GithubNetwork::RateLimited => e # the token's limit: the rest of the batch would fail the same way
          why = @gate.rate_limited!(e)
          rows[i..].each { |r| fail_row(r, why) }
          break
        rescue StandardError => e
          fail_row(row, [GithubNetwork::Error, Unconfigured].any? { |k| e.is_a?(k) } ? e.message : "#{e.class}: #{e.message}")
        end
        clean(rows)
        @db[:gh_pages].where(Sequel.like(:url, "#{PAGE}%")).where(Sequel.lit("at < ?", now - @wanted_for)).delete
        rows.size
      end

      private

      def fail_row(row, error) = @db[:gh_pr_checks].where(id: row[:id]).update(error: error[0, 500], checked_at: nil)

      def clean(rows) = rows.each { |row| GithubHook.clean(@db[:gh_pr_checks], row) }

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
        # head: the engine's approvable-now check; base · draft · merge_state · auto_merge: the gate's; base_sha: what a
        # conflicting PR is rebased onto
        { number: pr["number"], head: sha, base: pr.dig("base", "ref"), base_sha: pr.dig("base", "sha"),
          draft: pr["draft"] == true,
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
