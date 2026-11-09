# frozen_string_literal: true

require "socket"
require "json"
require_relative "../../vendor/agents_kanban/ruby/lib/agents_kanban/errors"

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
    def session_names = sessions.map { |s| s["name"] }
    def create(root:, name:, url:) = call(op: "create", root: root, name: name, url: url)
    def jobs = call(op: "jobs")["jobs"]
    def agents = call(op: "agents")
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

    # The engine's LAUNCH port (AgentsKanban::Api launcher:): a free session name for the board, then the start of the
    # session the engine registered — the host renders the type's prompt ({dir} is the host's) and confirms Remote Control.
    module LaunchPort
      module_function

      def name(project:, base:) = LauncherClient.call(op: "name", base: base)["session"]

      def start(session:, project:, type:, launcher:, argv:, prompt_template:, vars:)
        LauncherClient.call(op: "launch", path: project[:path], session: session, type: type, launcher: launcher, argv: argv,
                            prompt_template: prompt_template, vars: vars)
      end
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
