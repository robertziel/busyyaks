# frozen_string_literal: true

# The kanban engine is the vendored agents_kanban (vendor/agents_kanban, pinned in its VENDOR.md). This file holds
# NO board logic: it loads busyyaks's host config once (config/kanban.yml; the boards themselves are rows the engine
# keeps per project, seeded by migration 20261116000000), applies the deployment's env
# (ATTACHMENTS_DIR, ATTACHMENT_MAX_BYTES, ATTACHMENT_TYPES) and hands the engine its ports — the Hanami DB connection,
# the projects table as the boards, the launcher socket as delivery. test/unit/no_kanban_code_test.rb fails when
# engine code grows back here.
require "monitor"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban"
require_relative "agent_settings"
require_relative "launcher_client"
require_relative "store"
require_relative "ci_checks"
require_relative "pr_states"
require_relative "dashboard_url"
require_relative "git_port"
require_relative "session_git"

module Busyyaks
  module Kanban
    Invalid = AgentsKanban::Invalid
    Denied = AgentsKanban::Denied
    # the host config file: KANBAN_CONFIG (compose: /app/config/kanban.yml, the deployment's copy of config/kanban.example.yml;
    # the test suite: the example itself). Required — no default path.
    CONFIG_PATH = ENV.fetch("KANBAN_CONFIG")
    # Backlog.md statuses (lower-case) → column TYPES (like every other rule): a task lands on the project's board's
    # first column of that type; a board the operator edited that has no column of the type shows the task as an error
    # ("status X maps to type review but this board has no review column"), never a guess, never a refused board read.
    # Drafts are always the first column. "Human input" is no column since workflow v3 (a flag on a card): a task with
    # that status is reported as unmapped, never placed.
    BACKLOG_STATUS_MAP = {
      "backlog" => "parked", "draft" => "parked",
      "to do" => "queued", "todo" => "queued",
      "in progress" => "working", "doing" => "working",
      "qa" => "review", "review" => "review", "in review" => "review",
      "human check" => "gate", "ready to merge" => "gate", "ready" => "gate",
      "done" => "done", "merged" => "done",
    }.freeze

    # The memos below are built on first use, which may be on any Puma / notifier thread; the first caller builds
    # each one, the others wait for it. A Monitor: `markdown` reads `config` while it holds the lock.
    MEMO = Monitor.new
    # each host config `config` built → the {id, doc} revision it was built from; the key is weak (a config nobody
    # holds any more goes), the value strong (a WeakMap would collect the revision while its config is still in use)
    REVISIONS = ObjectSpace::WeakKeyMap.new

    module_function

    # The host config FILE (without launchers / agent_types, which are revisions in the database: AgentSettings), read once.
    def file_config = MEMO.synchronize { @file_config ||= AgentSettings.file_hash(CONFIG_PATH) }

    # Boot: the file must load on the engine with a valid agent part (the repo template's, only to validate the file's
    # own keys — the running config is always the database's revision: `config`). No database is touched here, so
    # `hanami db migrate` boots before the agent_settings table exists.
    def check_file! = AgentSettings.host(file_config, AgentSettings.template)

    # The engine's host config = the file + the newest agent settings revision. Rebuilt when a newer revision is saved
    # (one indexed max(id) per call), so web, mcp and the notifier run what Settings saved without a restart.
    def config(conn = db)
      rev = AgentSettings.current_id(conn)
      MEMO.synchronize do
        if @config.nil? || @config_rev != rev
          cur = AgentSettings.current(conn)
          @config = AgentSettings.host(file_config, cur[:doc])
          @config_rev = cur[:id]
          REVISIONS[@config] = { id: cur[:id], doc: cur[:doc] }.freeze
        end
        @config
      end
    end

    # {id, doc} of the revision `config` was built from.
    def config_revision(conn = db) = revision_of(config(conn))

    # {id, doc} of the revision a host config (a store's, an api's) was built from — what a launch planned on that
    # config hands bin/launcher (which rebuilds the same config from it and checks every command against the host
    # allowlist), so a revision saved between the plan and the start never runs under the plan's registration.
    def revision_of(cfg)
      MEMO.synchronize { REVISIONS[cfg] } or raise ArgumentError, "no agent settings revision recorded for this config"
    end

    def markdown
      MEMO.synchronize { @markdown ||= AgentsKanban::Markdown.new(attachment_url_prefix: file_config["attachment_url_prefix"]) }
    end
    def db = Hanami.app["db.gateway"].connection

    # The attachment policy from the deployment's env — required, validated at boot (config/app.rb), never a default.
    def policy
      MEMO.synchronize do
        @policy ||= AgentsKanban::AttachmentPolicy.new(max_bytes: ENV.fetch("ATTACHMENT_MAX_BYTES"),
                                                       types: ENV.fetch("ATTACHMENT_TYPES"),
                                                       max_bytes_name: "ATTACHMENT_MAX_BYTES", types_name: "ATTACHMENT_TYPES")
      end
    end

    # A store over the app's connection (or any Sequel db, with a settable clock — tests).
    def store(conn = db, clock: -> { Time.now.to_i })
      boards = ->(slug) { conn[:projects].where(slug: slug.to_s).any? }
      AgentsKanban::Store.new(conn, config: config(conn), markdown: markdown, clock: clock, boards: boards,
                              ci: ci_port(conn, clock: clock)) # approval.requires_green_ci
    end
    def default = store

    def attachments(st = default) = AgentsKanban::Attachments.new(st, root: ENV.fetch("ATTACHMENTS_DIR"), policy: policy)
    def project(slug) = Store.default.project(slug.to_s)
    def backlog(project, board) = AgentsKanban::BacklogMd.read(project[:path], board: board, status_map: BACKLOG_STATUS_MAP)
    def backlog_md?(path) = AgentsKanban::BacklogMd.present?(path)

    # Seconds a session the board launched counts as running before tmux lists it = the watchdog grace (one value, env).
    def grace = Integer(ENV.fetch("WATCHDOG_GRACE_SECONDS"))

    # The MCP tools (agents). sessions: live tmux session names, the launcher's `sessions` op by default.
    def tools(st = default, sessions: nil)
      AgentsKanban::Tools.new(store: st, attachments: attachments(st), projects: method(:project), backlog: method(:backlog),
                              sessions: sessions || -> { LauncherClient.session_names }, grace: grace,
                              card_url: ->(slug, id) { card_url(slug, id) }) # each card's `url` (Links rule)
    end

    # config/kanban.yml session_boards' slug prefix (nil = session boards off).
    # The key is required (KeyError when missing); null = off.
    def session_prefix = file_config.fetch("session_boards")&.fetch("slug_prefix")

    # The SPA path of a card: its project's board, or — a session board's card — the /session-boards page.
    def card_path(slug, id)
      pre = session_prefix
      return DashboardUrl.session_card_path(slug.to_s.delete_prefix(pre), id) if pre && slug.to_s.start_with?(pre)

      DashboardUrl.card_path(slug, id)
    end

    def card_url(slug, id) = "#{DashboardUrl.origin}#{card_path(slug, id)}"

    # The engine's operator API with the session ports (launches / launch / sessions): live names from the launcher's
    # `sessions` op, starts through its `name` + `launch` ops (LauncherClient::LaunchPort). Extras are the caller's.
    def api(st = default, **extras)
      AgentsKanban::Api.new(store: st, attachments: attachments(st), markdown: markdown, projects: method(:project),
                            backlog: method(:backlog),
                            sessions: -> { LauncherClient.session_names },
                            launcher: LauncherClient::LaunchPort.new(revision_of(st.config)), grace: grace,
                            press: ->(**kw) { LauncherClient.answer(**kw) }, **extras)
    end

    # The notifier: deliver + watch + the spawn pass (a To do card gets its own worker session through the same launch
    # path as the Launch button: Api#spawn_pass).
    def notifier(grace: self.grace)
      st = default
      a = api(st)
      AgentsKanban::Notifier.new(st, client: LauncherClient, grace: grace, spawner: -> { a.spawn_pass }, ci: ci_port(st.db))
    end

    # The notifier's watch pass keeps every gated card's approval checks asked (the engine's approval prefetch), so
    # the github service always holds a fresh answer (card #247). A pass slower than the poller's window lets a request
    # lapse between two passes, and Approve waits for a CI read again — refused at boot (bin/notifier).
    def watch_fits!(watch:, interval:)
      window = CiChecks.wanted_for(Integer(ENV.fetch("GITHUB_CI_INTERVAL_SECONDS")))
      period = [watch, interval].max # the watch runs inside the deliver loop, which sleeps `interval` between turns
      return if period < window

      raise ArgumentError, "a watch pass every #{period} s (NOTIFIER_WATCH_SECONDS=#{watch}, " \
                           "NOTIFIER_INTERVAL_SECONDS=#{interval}) must be below #{window} s, the CI poll window " \
                           "(10 × GITHUB_CI_INTERVAL_SECONDS): a slower watch pass lets gated cards' CI requests lapse"
    end

    # The idle watch's CI port: PR check status the github service polled (the token never leaves that service), the owner
    # branch and its last commit read here (SessionGit: the launcher names the session's dir, a GitRead child reads it).
    # An answer older than 3 poll intervals is Unavailable.
    def ci_port(conn = db, clock: -> { Time.now.to_i })
      interval = Integer(ENV.fetch("GITHUB_CI_INTERVAL_SECONDS"))
      CiChecks::Port.new(db: conn, projects: ->(slug) { conn[:projects].where(slug: slug.to_s).first },
                         approvals: ->(slug) { CiChecks.steps(store(conn, clock: clock).board_of(slug)) },
                         launcher: SessionGit,
                         stale_after: 3 * interval, wanted_for: CiChecks.wanted_for(interval), clock: clock)
    end

    # the PR flags on a card's links — PR state the github service polled, same freshness rule as ci_port; the card's
    # own PRs are the ones assigned to it (PrStates.assigned).
    def pr_flags(conn = db)
      interval = Integer(ENV.fetch("GITHUB_CI_INTERVAL_SECONDS"))
      PrStates::Flags.new(PrStates::Reader.new(db: conn, stale_after: 3 * interval, wanted_for: PrStates.wanted_for(interval)))
    end

    # CardLinks' `git:` port (one per process: its files_at answers are kept per scan). No git in this process.
    def git_port = MEMO.synchronize { @git_port ||= GitPort.new(root: GitRead.mount) }

    # The template board's column labels for busyyaks's own readers (search): {key => label}. A card's own board may
    # differ — readers that have the card's project ask the engine for its board (Store#board_of).
    def columns = default.board_template.labels
  end
end
