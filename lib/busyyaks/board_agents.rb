# frozen_string_literal: true

require "json"
require_relative "project_agents"
require_relative "launcher_client"
require_relative "agent_settings"
require_relative "clock"

module Busyyaks
  # Which agent type works a board's cards: the MCP server asks this before the engine's kanban_spawn /
  # kanban_assign_worker, and answers the lead's `board_agents` tool. The rule is ProjectAgents' (one definition); the
  # repo's .busyyaks/agents.yml is read by bin/launcher's `project_agents` op (only that side decides folder trust);
  # the board's columns come from the engine. A session busyyaks started with kanban_spawn is recorded with its type and
  # role (table session_roles), so a worker handed a card later is checked against the card's column.
  class BoardAgents
    TABLE = :session_roles

    # store: the engine's Store (cards, boards) · projects: slug → the projects row · launcher: LauncherClient-like
    # (call(req) → answer, raises LauncherClient::Refused / Unavailable) · revision: {id, doc} of the agent settings
    # the engine runs · db: the busyyaks database
    def initialize(store:, projects:, revision:, db:, launcher: LauncherClient, clock: -> { Busyyaks::Clock.epoch })
      @store = store
      @projects = projects
      @revision = revision
      @db = db
      @launcher = launcher
      @clock = clock
    end

    # [state, Agents | nil, opt-in type keys] of a project's file, read by bin/launcher. Its refusal (an invalid file)
    # → ProjectAgents::Invalid with its reason; the launcher down → ProjectAgents::Invalid saying so (never "no file").
    # A loaded file's columns are checked against the board as it is NOW (a hand-edited file, a Workflow save that
    # renamed a column): a key that is no work column of it refuses, naming the key — never skipped.
    # A repo with no file (the repos are mounted here read-only) is "none" without asking: the launcher's own answer for
    # it, and kanban_claim / kanban_assign_worker on a board that maps nothing never wait on the launcher.
    def state(slug)
      p = @projects.call(slug) or raise ProjectAgents::Invalid, "no project #{slug}"
      file = File.join(p[:path], ProjectAgents::FILE)
      return ["none", nil, AgentSettings.opt_in(@revision.fetch(:doc))] unless File.exist?(file) || File.symlink?(file)

      ans = @launcher.call(op: "project_agents", path: p[:path], settings: @revision)
      agents = ans["agents"] && ProjectAgents.from_h(ans["agents"])
      ProjectAgents.board_columns!(agents, board_types(slug)) if agents
      [ans["state"], agents, ans["opt_in"]]
    rescue LauncherClient::Refused => e
      raise ProjectAgents::Invalid, e.message
    rescue LauncherClient::Unavailable => e
      raise ProjectAgents::Invalid, "cannot read #{ProjectAgents::FILE}: #{e.message} — try again when the launcher is up"
    end

    def board_types(slug)
      b = @store.board_of(slug)
      b.keys.to_h { |k| [k, b.type_of(k).key] }
    end

    # The card an agent names, as the engine's tools see it: a held card is "no card N" and a session
    # board's card belongs to no project's agent types — refused in the engine's words, before anything else is read
    def card!(args)
      id = Integer(args.fetch("id"))
      raise AgentsKanban::Invalid, "no card #{id}" if @store.on_hold_ids([id]).any?

      c = @store.card!(id)
      if @store.session_slug?(c[:project_slug])
        raise AgentsKanban::Invalid, "card ##{id} is on #{c[:project_slug]}, a session board: no lead spawns for it"
      end

      c
    end

    # kanban_spawn's arguments → [the role to start (nil = none), the card's project], or ProjectAgents::Invalid naming
    # what to ask for
    def spawn!(args)
      c = card!(args)
      board = @store.board_of(c[:project_slug])
      state, agents, opt_in = state(c[:project_slug])
      role = args["role"]
      raise ProjectAgents::Invalid, "role must be a role name (a string) when given" unless role.nil? || role.is_a?(String)

      ProjectAgents.spawn!(state: state, agents: agents, column: c[:column], column_label: board.label(c[:column]),
                           type: args["type"].to_s, role: role, opt_in: opt_in)
      [role, c[:project_slug]]
    end

    # what a spawned session is: kept for kanban_assign_worker (a session name is never reused while it runs)
    def record!(session:, slug:, type:, role:)
      @db.transaction do
        @db[TABLE].where(session: session).delete
        @db[TABLE].insert(session: session, project_slug: slug, type_key: type, role: role, created_at: @clock.call)
      end
    end

    # {type, role} busyyaks recorded for a session it started with kanban_spawn on `slug`, nil = none recorded
    def worker(session, slug)
      row = @db[TABLE].where(session: session.to_s, project_slug: slug.to_s).first
      row && { type: row[:type_key], role: row[:role] }
    end

    # kanban_assign_worker's arguments: the worker matches the card's column, or ProjectAgents::Invalid
    def assign!(args)
      c = card!(args)
      board = @store.board_of(c[:project_slug])
      state, agents, = state(c[:project_slug])
      session = args["worker_session"].to_s
      ProjectAgents.assign!(state: state, agents: agents, column: c[:column], column_label: board.label(c[:column]),
                            worker: worker(session, c[:project_slug]), session: session)
    end

    # kanban_claim's arguments: a session taking a card in a mapped column is of that type or role,
    # as a worker handed one is (assign!) — the caller is its tmux_session
    def claim!(args)
      assign!(args.merge("worker_session" => args["tmux_session"].to_s))
    end

    # The lead's view (MCP board_agents): the file's state, the opt-in types it uses, its roles and, per column of the
    # board, the type or role a session for a card there is (nil = any type the board runs)
    def view(slug)
      state, agents, opt_in = state(slug)
      board = @store.board_of(slug)
      a = agents || ProjectAgents::EMPTY
      { project: slug, file: ProjectAgents::FILE, state: state, opt_in: opt_in, use: a.use,
        roles: a.roles.transform_values { |r| { label: r.label, like: r.like, brief: role_brief(r.key) } },
        columns: board.keys.map do |k|
          name = a.for_column(k)
          { column: k, label: board.label(k), type: board.type_of(k).key, takes: name,
            spawn: name && ProjectAgents.spawn_args(a, name), }
        end, }
    end

    def role_brief(key) = File.join(Skills::PROJECT_DIR, "skills", Skills::AGENTS, "#{key}.md")
  end
end
