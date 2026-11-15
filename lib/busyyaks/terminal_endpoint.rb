# frozen_string_literal: true

require "json"
require "rack"
require_relative "auth"
require_relative "kanban"
require_relative "launcher_client"
require_relative "terminal"
require_relative "web_socket"

module Busyyaks
  # GET /api/terminal?session=&socket= — an agent session's live terminal as a WebSocket: the launcher's
  # `attach` stream (Busyyaks::Terminal) relayed both ways. Behind HostGuard (Host) like every route; on top, before the
  # upgrade, every one of these or no terminal:
  #   signed in (the auth provider asked, Auth.identify)                                             else 401
  #   an Origin, equal to its Host's own origin (a page elsewhere cannot open one: no CSRF token here) else 403
  #   through PUBLIC_HOST only with config terminal.public_host: allow                                else 403
  #   a WebSocket upgrade, a session + socket name                                                    else 400
  #   a session with an OPEN registration on the board (busyyaks started or registered it)            else 404
  #   fewer than terminal.max_open open                                                               else 503
  #   the launcher attaches (the session runs, an agent in its pane)                         else its status / 503
  # The MCP server never routes here (its own rack app, bearer only). Each open and each take / release of control is
  # a `terminal` event by the operator on every card the session owns (Store#terminal_event) + a launcher log line.
  # Input is relayed only while in control — the control state the LAUNCHER confirmed; otherwise refused here and
  # again there. Puma's thread is handed back at once (a full hijack): one thread per open terminal relays the stream.
  class TerminalEndpoint
    PATH = "/api/terminal"

    def initialize(origins:, settings:, public_host:, store: -> { Kanban.default }, launcher: LauncherClient)
      @origins = origins
      @settings = settings
      @public_host = public_host.to_s.downcase
      @store = store
      @launcher = launcher
      @open = 0
      @lock = Mutex.new
    end

    def open_count = @lock.synchronize { @open }

    def call(env)
      # no rack.session = the session middleware is off: a KeyError (500), never an empty session
      email = Auth.identify(env.fetch("rack.session"))
      return refuse(401, "not signed in") unless email

      host = env["HTTP_HOST"].to_s.downcase
      origin = env["HTTP_ORIGIN"]
      return refuse(403, "a terminal opens only from this app's own page (no Origin)") if origin.nil?
      allowed = @origins.call[host]
      return refuse(403, "origin not allowed: a terminal opens only from this app's own page") \
        unless allowed && origin.downcase == allowed
      if !@public_host.empty? && host == @public_host && !@settings.public_allowed?
        return refuse(403, "terminals are not offered through #{@public_host} (config/busyyaks.yml terminal.public_host: deny)")
      end

      key = WebSocket.key(env)
      return refuse(400, "a terminal is a WebSocket (GET with Upgrade: websocket, version 13)") unless key

      q = Rack::Utils.parse_query(env["QUERY_STRING"].to_s)
      session, socket = Terminal.session!(q["session"], q["socket"] || "default")
      store = @store.call
      reg = store.open_session(session)
      unless reg && reg[:socket] == socket
        return refuse(404, "session #{session} has no open registration on any board: busyyaks shows terminals only " \
                           "of the sessions it registered")
      end

      open(env, key, email, session, socket, store)
    rescue Terminal::Invalid => e
      refuse(400, e.message)
    end

    private

    def open(env, key, email, session, socket, store)
      unless take_slot
        return refuse(503, "#{@settings.max_open} terminals are open (config terminal.max_open): close one first")
      end

      begin
        conn, hello = @launcher.attach(session: session, socket: socket)
      rescue LauncherClient::AttachRefused => e
        release_slot
        return refuse(e.status, e.message)
      rescue LauncherClient::Unavailable => e
        release_slot
        return refuse(503, e.message)
      end
      # the registration may have ended while the launcher attached: asked again before the upgrade (a 404 still)
      unless store.open_session(session)
        conn.close
        release_slot
        return refuse(404, "session #{session}'s registration ended: no terminal")
      end
      begin
        io = env["rack.hijack"].call
        io.write(WebSocket.handshake(key))
      rescue StandardError
        conn.close
        io&.close
        release_slot
        raise
      end
      # logged only once the socket is upgraded; past the hijack a refusal is a close frame, never a Rack response
      ws = WebSocket.new(io, max: Terminal::MAX_LINE)
      begin
        store.terminal_event(session: session, socket: socket, by: email, text: "opened the terminal (read-only)")
      rescue AgentsKanban::Denied => e # the registration ended in the last moment
        return abandon(ws, conn, 1008, e.message)
      rescue StandardError => e # the store failed (a lock timeout, the DB down): no unlogged terminal
        return abandon(ws, conn, 1011, "the open could not be logged: #{e.class}")
      end
      Thread.new { relay(ws, conn, hello, Ctx.new(email, session, socket, store)) }
      [200, {}, []] # ignored after the full hijack
    end

    Ctx = Struct.new(:email, :session, :socket, :store)

    # an upgraded socket refused before any relay: its close frame, the launcher stream closed, the slot freed
    def abandon(ws, conn, code, why)
      conn.close
      ws.close(code, why)
      release_slot
      [200, {}, []] # ignored after the full hijack
    end

    # the control state the launcher last confirmed (read by the browser side, set by the launcher side)
    class Control
      def initialize
        @on = false
        @lock = Mutex.new
      end

      def on? = @lock.synchronize { @on }
      def set(v) = @lock.synchronize { @on = v }
    end

    def relay(ws, conn, hello, ctx)
      control = Control.new
      ws.text(JSON.generate(hello))
      out = Thread.new { from_launcher(ws, conn, control, ctx) }
      from_browser(ws, conn, control)
    rescue WebSocket::Closed, IOError, SystemCallError
      nil
    ensure
      conn.close unless conn.closed?
      ws.close(1000, "terminal closed")
      out&.join(5)
      release_slot
    end

    def from_launcher(ws, conn, control, ctx)
      loop do
        line = conn.gets or break
        f = JSON.parse(line)
        raise JSON::ParserError, "a launcher frame is a JSON object" unless f.is_a?(Hash)

        if f.key?("control") && control.on? != f["control"]
          control.set(f["control"])
          ctx.store.terminal_event(session: ctx.session, socket: ctx.socket, by: ctx.email,
                                   text: f["control"] ? "took control of the terminal" : "released control of the terminal")
        end
        ws.text(line.chomp)
      end
      ws.close(1000, "the session's terminal ended")
    rescue WebSocket::Closed, IOError, SystemCallError, JSON::ParserError
      ws.close(1011, "the launcher stream broke")
    end

    def from_browser(ws, conn, control)
      loop do
        msg = ws.read or break
        begin
          kind, = Terminal.client_frame(msg)
        rescue Terminal::Invalid => e
          ws.text(JSON.generate(refused: e.message))
          next
        end
        next ws.text(JSON.generate(refused: Terminal::NOT_IN_CONTROL)) if kind == :input && !control.on?

        conn.write("#{msg}\n")
      end
    end

    def take_slot
      @lock.synchronize do
        next false if @open >= @settings.max_open

        @open += 1
      end
    end

    def release_slot = @lock.synchronize { @open -= 1 }

    def refuse(status, message)
      [status, { "content-type" => "application/json", "cache-control" => "no-store" }, [JSON.dump(error: message)]]
    end
  end
end
