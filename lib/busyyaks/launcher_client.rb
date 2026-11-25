# frozen_string_literal: true

require "socket"
require "timeout"
require "json"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/errors"
require_relative "clock"

module Busyyaks
  # Talks to the host's bin/launcher over the unix socket at LAUNCHER_SOCKET. No socket = Unavailable
  # (the page says the launcher is down); a refused request = Refused with the launcher's reason.
  # This client IS the kanban engine's DELIVERY port (notify / agents / dialog / answer), so its errors are the
  # engine's own classes — the notifier and the tools rescue exactly these.
  module LauncherClient
    Unavailable = AgentsKanban::Delivery::Unavailable
    Refused = AgentsKanban::Delivery::Refused

    module_function

    def sessions = call(op: "sessions")["sessions"]
    # only the sessions busyyaks launched (the launcher's `launched`): what a page lists, stops or offers as an assignee
    def launched_sessions = sessions.select { |s| s["launched"] }
    # the engine's live sessions (claim, register, presence, terminals): only the ones busyyaks started — a session
    # started by hand is never a card's live owner (a fresh launch counts through the engine's grace until its start is
    # recorded). The `sessions` op itself already lists only `by_` sessions (a hand-run one never leaves the host); the
    # notifier's watch reads that op, so it sees the same set
    def session_names = launched_sessions.map { |s| s["name"] }
    # config/harnesses.yml + launch.commands resolved in the launch shell on the host:
    # {shell, harnesses: [{key, label, command, kind, launch_args, install_url, found, type, path, version, version_error}],
    #  commands: [{command, found, type, path}]}
    def harnesses = call(op: "harnesses")
    # the projects dir (card 532): the launcher's answers as is — {ok, ...} or {ok: false, error, status}
    def browse(path:) = raw(op: "browse", path: path)
    def projects_root(step:, path: nil, plan_id: nil) = raw(op: "projects_root", step: step, path: path, plan_id: plan_id)
    # updating this checkout (card 536): status | check | apply {mode, sha} — the launcher's answer as is
    def update(step:, mode: nil, sha: nil) = raw(op: "update", step: step, mode: mode, sha: sha)
    # what a launch in the repo does with its own .busyyaks/skills (the project page's Settings tab): the launcher's
    # answer as is — {ok, project_skills: "loaded" | "none" | "left: <why>"} or {ok: false, error}
    def project_skills(path:, settings:) = raw(op: "project_skills", path: path, settings: settings)
    # busyyaks's own skills layers as a launch of the host checkout reads them (Settings → Agent rules): the answer as
    # is — {ok, files, types, creatable, checkout, limits} or {ok: false, error, status}
    def skills_layers(settings:) = raw(op: "skills_layers", settings: settings)
    def create(root:, name:, url:) = call(op: "create", root: root, name: name, url: url)
    def jobs = call(op: "jobs")["jobs"]
    def agents = call(op: "agents")

    # The `agents` answer shared by the pollers of one web process (the sidebar every 10 s, each open card dialog's live
    # line every 3 s): one launcher call per SNAPSHOT_SECONDS, concurrent askers wait for the one in flight.
    # Only a good answer is kept: a refusal or an unreachable launcher raises for every asker and is asked afresh next
    # time — an older snapshot never stands in for it.
    SNAPSHOT_SECONDS = 2.0
    SNAPSHOT_LOCK = Mutex.new
    @snapshot = nil # [socket path, monotonic time, answer]

    def agents_snapshot
      sock = ENV.fetch("LAUNCHER_SOCKET")
      SNAPSHOT_LOCK.synchronize do
        now = Clock.monotonic
        at, snap = @snapshot&.then { |path, t, a| path == sock ? [t, a] : nil }
        return snap if at && now - at < SNAPSHOT_SECONDS

        @snapshot = nil
        snap = agents
        @snapshot = [sock, now, snap]
        snap
      end
    end

    def forget_agents_snapshot! = SNAPSHOT_LOCK.synchronize { @snapshot = nil }
    def reap_preview = call(op: "reap_preview")
    def reap(sessions) = call(op: "reap", sessions: sessions)
    # kill this project's named sessions (operator Stop / Stop all): {"results"=>[{name, stopped, reason}]}
    def stop(path:, sessions:) = call(op: "stop", path: path, sessions: sessions)

    # {ok:true} | {ok:false, gone:|retry:|unsupported:, error:} — the notifier decides; never raises on a refusal.
    def notify(session:, socket:, text:) = raw(op: "notify", session: session, socket: socket, text: text)
    def agent_tasks(session:, socket:) = call(op: "agent_tasks", session: session, socket: socket)
    # {ok:true, dialog: SessionDialog.parse(screen) | nil} | {ok:false, gone:true, error:} — the session's screen now, parsed
    def dialog(session:, socket:) = raw(op: "dialog", session: session, socket: socket)
    # {"branch"=>, "last_commit_at"=>epoch|nil}: the git branch and newest commit time in the session's working dir
    # (the host's git)
    def git(session:, socket:) = call(op: "git", session: session, socket: socket)
    # press `key` (a digit or "esc") ONLY if the screen still shows the dialog with this hash; refused (with the reason)
    # otherwise
    def answer(session:, socket:, hash:, key:) = call(op: "answer", session: session, socket: socket, hash: hash, key: key)

    # The live terminal of a session (Busyyaks::Terminal): the launcher's `attach` stream. → [socket, hello]:
    # the open connection (JSON lines both ways from now on; the caller closes it) and the first line, parsed. A
    # refusal (not running, no agent in it, a bad name) → Refused with the launcher's reason and status, closed. A
    # launcher that does not answer within ATTACH_WAIT_S, or refuses without a status, is Unavailable (503).
    ATTACH_WAIT_S = 10 # the launcher's checks before the first line: a few tmux calls + a /proc walk

    def attach(session:, socket:)
      sock = UNIXSocket.new(ENV.fetch("LAUNCHER_SOCKET"))
      sock.puts(JSON.generate(op: "attach", session: session, socket: socket))
      line = begin
        Timeout.timeout(ATTACH_WAIT_S) { sock.gets }
      rescue Timeout::Error
        sock.close
        raise Unavailable, "the launcher did not answer the attach within #{ATTACH_WAIT_S}s"
      end
      hello = JSON.parse(line.to_s)
      return [sock, hello] if hello["ok"]

      sock.close
      raise Unavailable, "the launcher refused the attach without a status: #{hello.inspect}" unless hello["status"]

      raise AttachRefused.new(hello["error"].to_s, status: hello["status"])
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES, Errno::EPIPE, Errno::ECONNRESET, JSON::ParserError => e
      sock&.close
      raise Unavailable, "launcher not reachable at #{ENV.fetch('LAUNCHER_SOCKET')}: #{e.class}"
    end

    # an attach the launcher refused: its reason + HTTP status (404 not running, 403 no agent, 400 a bad name)
    class AttachRefused < Refused
      attr_reader :status

      def initialize(message, status:)
        super(message)
        @status = Integer(status)
      end
    end

    # The engine's LAUNCH port (AgentsKanban::Api launcher:): a free session name for the board, then the start of the
    # session the engine registered — the host renders the type's prompt ({dir} is the host's) and confirms Remote Control.
    # One per api, holding the agent settings revision {id, doc} that api's config was built from: the plan and the
    # registration are that revision's, so the start is too — bin/launcher rebuilds the engine config from it and
    # refuses a command that is not on the host allowlist (config/busyyaks.yml launch.commands).
    class LaunchPort
      def initialize(revision)
        @revision = revision
      end

      def name(project:, base:) = LauncherClient.call(op: "name", base: base)["session"]

      # lead_key: a lead's key (lead-first boards) — bin/launcher KEEPS it in its own state dir (never the tmux
      # session's environment, a log or an answer), nil otherwise · lead: the lead's tmux session a session under a lead
      # runs under (bin/launcher refuses the start unless it started that lead for this project and it runs), or nil.
      def start(session:, project:, type:, launcher:, argv:, prompt_template:, vars:, lead_key:, lead:)
        LauncherClient.call(op: "launch", path: project[:path], session: session, type: type, launcher: launcher, argv: argv,
                            prompt_template: prompt_template, vars: vars, settings: @revision, lead_key: lead_key,
                            lead: lead)
      end

      # The key bin/launcher keeps for a lead it started, while that tmux session runs (kanban_spawn / kanban_register:
      # the engine compares its digest; the agent handles no key). Refused for any other session. A guard against
      # cooperative agents, not authentication: one MCP bearer can name any tmux session.
      def lead_key(session:) = LauncherClient.call(op: "lead_key", session: session)["key"]
    end

    def call(req)
      res = raw(req)
      raise Refused, res["error"] unless res["ok"]

      res
    end

    # The launcher's answer as is (ok or not); unreachable → Unavailable.
    def raw(req)
      sock = ENV.fetch("LAUNCHER_SOCKET")
      UNIXSocket.open(sock) do |s|
        s.puts(JSON.generate(req))
        JSON.parse(s.gets.to_s)
      end
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES, JSON::ParserError => e
      raise Unavailable, "launcher not reachable at #{sock}: #{e.class}"
    end
  end
end
