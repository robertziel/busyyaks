# frozen_string_literal: true

require "fileutils"
require "json"
require "monitor"
require "net/http"
require "openssl"
require "securerandom"
require "socket"
require "uri"
require "yaml"

module Busyyaks
  module CLI
    # `yaks desktop open`: the desktop app's server chooser — what the app-menu entry `yaks desktop install`
    # writes starts. A page of its own on http://127.0.0.1:<a free port>, opened in the browser's app window:
    #   Local (this checkout's DashboardUrl.origin) first, the default — then every saved server (Remote.saved), each
    #   with its state; Open · Disconnect · Remove per row, Add server below. The dashboard itself is unchanged.
    #   Open Local → a window on the local origin. Open a server → its forward (`ssh -N -L`, Remote.forward_argv: the
    #   server's own port, as `yaks remote connect`) is started here, held while the chooser runs, and once its /up
    #   answers 200 a window on it opens. A taken port is refused naming it, never another port.
    # One chooser per user: the running one holds an exclusive flock on desktop.lock for its whole life; a second `open`
    # cannot take it, reads the first one's state file and only opens another window on it.
    # It ends when no chooser window has been open for GRACE seconds (the page holds an event stream; closing its last
    # window drops it), and ending stops every forward it started: closing the chooser disconnects every server.
    #
    # Guards (any web page can reach 127.0.0.1): Host must be exactly 127.0.0.1:<port> (421 — DNS rebinding); the page
    # and its API need the session cookie (HttpOnly, SameSite=Strict), handed out only for a one-time launch code that
    # `open` mints from the state file's secret (0600, a 0700 dir: this user only); every POST also needs Origin =
    # its own origin (403). Saved-server edits go through Remote.add! / remove! (the target shape: never an ssh option).
    module Chooser
      GRACE = 10          # seconds with no chooser window before it ends
      FIRST_WINDOW = 60   # seconds the first window has to arrive
      READY = 15          # seconds a forward has to answer /up 200
      TICK = 2            # seconds between state pushes
      CODE_TTL = 60       # seconds a launch code is good for
      MAX_HEAD = 8192
      MAX_BODY = 4096
      PAGE_DIR = File.join(__dir__, "chooser")
      PUBLIC = "../../public/static"
      # what the page loads: path → [file under this dir, content type]
      ASSETS = {
        "/chooser.css" => ["chooser/chooser.css", "text/css; charset=utf-8"],
        "/chooser.js" => ["chooser/chooser.js", "text/javascript; charset=utf-8"],
        "/logo-light.svg" => ["#{PUBLIC}/logo-light.svg", "image/svg+xml"],
        "/logo-dark.svg" => ["#{PUBLIC}/logo-dark.svg", "image/svg+xml"],
        "/icon.svg" => ["#{PUBLIC}/icon.svg", "image/svg+xml"],
        "/fonts/Inter-400.woff2" => ["#{PUBLIC}/fonts/Inter-400.woff2", "font/woff2"],
        "/fonts/Inter-600.woff2" => ["#{PUBLIC}/fonts/Inter-600.woff2", "font/woff2"],
        "/fonts/FragmentMono-Regular.woff2" => ["#{PUBLIC}/fonts/FragmentMono-Regular.woff2", "font/woff2"],
      }.freeze
      CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; " \
            "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
      COOKIE = "yaks_chooser"

      module_function

      def state_dir(ctx)
        base = ctx.env["XDG_STATE_HOME"].to_s
        if base.empty?
          home = ctx.env["HOME"].to_s
          raise Refused, "HOME is not set (the chooser keeps its state in $XDG_STATE_HOME or ~/.local/state)" if home.empty?

          base = File.join(home, ".local/state")
        end
        dir = File.join(base, "busyyaks")
        FileUtils.mkdir_p(dir, mode: 0o700)
        st = File.lstat(dir)
        raise Refused, "#{dir} is not this user's directory" unless st.directory? && st.uid == Process.uid
        raise Refused, "#{dir} is open to others (mode #{format('%o', st.mode & 0o777)}): chmod 700 it" \
          unless (st.mode & 0o077).zero?

        dir
      end

      # → the running chooser's {pid, port, secret} once it has recorded them and answers on its port, or nil
      def recorded(dir)
        doc = JSON.parse(File.read(File.join(dir, "desktop.json")))
        return unless doc.is_a?(Hash) && doc["pid"].is_a?(Integer) && doc["port"].is_a?(Integer) &&
                      doc["secret"].is_a?(String)

        TCPSocket.new(DashboardUrl::LOOPBACK, doc["port"]).close
        doc
      rescue Errno::ENOENT, Errno::ECONNREFUSED, JSON::ParserError
        nil
      end

      # the lock is held by a chooser that is starting or running: its record, within `wait` seconds, or Refused
      def running!(dir, wait)
        deadline = Time.now + wait
        loop do
          live = recorded(dir)
          return live if live
          raise Refused, "a chooser holds #{dir}/desktop.lock but answers on no recorded port after #{wait} s" \
            if Time.now > deadline

          sleep 0.1
        end
      end

      # a one-time launch code: <time>.<nonce>.<hmac of both under the chooser's secret>
      def code(secret, now = Time.now.to_i)
        nonce = "#{now}.#{SecureRandom.hex(16)}"
        "#{nonce}.#{OpenSSL::HMAC.hexdigest('SHA256', secret, nonce)}"
      end

      # the lock decides who serves: taken → this process is the chooser (held until it ends); held elsewhere → a window
      # on that one. `opts` go to Server (tests: short timings); the block, if any, gets the Server before it runs.
      def open(ctx, browser, wait: 5, **opts)
        dir = state_dir(ctx)
        lock = File.open(File.join(dir, "desktop.lock"), File::RDWR | File::CREAT, 0o600)
        if lock.flock(File::LOCK_EX | File::LOCK_NB)
          server = Server.new(ctx, browser, dir, **opts)
          yield server if block_given?
          return server.run
        end
        live = running!(dir, wait)
        url = "http://#{DashboardUrl::LOOPBACK}:#{live['port']}/?code=#{code(live['secret'])}"
        Process.detach(ctx.runner.spawn(browser, "--app=#{url}"))
        ctx.out.puts "the chooser runs already (pid #{live['pid']}): opened another window on it"
        0
      ensure
        lock&.close
      end

      # One saved server's forward: the ssh child, its state, ssh's last words
      Forward = Struct.new(:target, :state, :detail, :host, :url, :pid, keyword_init: true) do
        def to_h = { target: target, state: state, detail: detail, host: host, url: url }
      end

      class Server
        attr_reader :port

        def initialize(ctx, browser, dir, grace: GRACE, first_window: FIRST_WINDOW, ready: READY, tick: TICK)
          @ctx = ctx
          @browser = browser
          @dir = dir
          @grace = grace
          @first_window = first_window
          @ready = ready
          @tick = tick
          @secret = SecureRandom.hex(32)
          @session = SecureRandom.hex(32)
          @used = {}
          @forwards = {}
          @clients = 0
          @seen = nil
          @lock = Monitor.new
          @local = { url: nil, state: "checking", detail: nil }
        end

        # binds, records itself, opens the first window, serves until no window has been open for the grace
        def run
          @tcp = TCPServer.new(DashboardUrl::LOOPBACK, 0)
          @port = @tcp.addr[1]
          @origin = "http://#{DashboardUrl::LOOPBACK}:#{@port}"
          record!
          window("#{@origin}/?code=#{Chooser.code(@secret)}")
          @ctx.out.puts "chooser on #{@origin} (pid #{Process.pid}); it ends #{@grace} s after its last window closes"
          @ctx.out.flush
          threads = [Thread.new { accept_loop }, Thread.new { local_loop }]
          wait_for_windows
          0
        ensure
          threads&.each(&:kill)
          shutdown
        end

        def stop! = @stop = true

        private

        def record!
          path = File.join(@dir, "desktop.json")
          tmp = "#{path}.new-#{Process.pid}"
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
            f.write(JSON.generate(pid: Process.pid, port: @port, secret: @secret))
          end
          File.rename(tmp, path)
        ensure
          FileUtils.rm_f(tmp) if tmp
        end

        # @seen = when a window's event stream last opened or closed (set by the stream itself: a window that comes and
        # goes between two checks still counts)
        def wait_for_windows
          started = Time.now
          until @stop
            sleep 0.1
            clients, seen = @lock.synchronize { [@clients, @seen] }
            next if clients.positive?
            break if seen ? Time.now - seen > @grace : Time.now - started > @first_window
          end
        end

        def shutdown
          @tcp&.close
          @lock.synchronize { @forwards.each_value { stop_forward(_1) } }
          forget!
        end

        # the state file goes only while it is still this process's (a newer chooser may have replaced it)
        def forget!
          path = File.join(@dir, "desktop.json")
          FileUtils.rm_f(path) if JSON.parse(File.read(path))["pid"] == Process.pid
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        def window(url) = Process.detach(@ctx.runner.spawn(@browser, "--app=#{url}"))

        # --- local: this checkout's dashboard ----------------------------------------------------------------------

        def local_loop
          loop do
            set_local(*local_health)
            sleep(@tick * 2)
          end
        end

        def local_health
          url = DashboardUrl.origin(@ctx.dotenv)
          [url, Chooser.up?(url) ? "up" : "down", nil]
        rescue Refused, DashboardUrl::Invalid => e
          [nil, "none", e.message]
        end

        def set_local(url, state, detail) = @lock.synchronize { @local = { url: url, state: state, detail: detail } }

        # --- the saved servers' forwards ---------------------------------------------------------------------------

        def state
          @lock.synchronize do
            saved = Remote.saved(@ctx)
            servers = saved.map { (@forwards[_1] || Forward.new(target: _1, state: "idle")).to_h }
            { local: @local, servers: servers, error: nil }
          end
        rescue Refused => e
          { local: @local, servers: [], error: e.message }
        end

        def open_server(target)
          return open_local if target == "local"

          Remote.known!(@ctx, target)
          fwd = @lock.synchronize do
            current = @forwards[target]
            return window(current.url) if current&.state == "connected"
            raise Refused, "#{target} is connecting already" if current&.state == "connecting"

            @forwards[target] = Forward.new(target: target, state: "connecting", detail: "asking #{target} its ports")
          end
          Thread.new { connect(fwd) }
        end

        def open_local
          local = @lock.synchronize { @local.dup }
          raise Refused, "no local busyyaks here: #{local[:detail]}" unless local[:url]

          window(local[:url])
        end

        # Disconnect may land at any step: the spawn, the pid and the connected state are each decided under the lock,
        # and only while this forward is still the current, connecting one — a disconnected one starts nothing
        def connect(fwd)
          ports = probe(fwd)
          return unless ports

          Remote.free!(ports["web_port"], "the dashboard")
          r, w = IO.pipe
          pid = @lock.synchronize do
            next unless current?(fwd)

            @ctx.runner.spawn(*Remote.forward_argv(fwd.target, ports, batch: true), err: w).tap do |child|
              fwd.pid = child
              fwd.host = ports["host"]
              fwd.url = Remote.dashboard_url(ports)
              fwd.detail = "ssh started"
            end
          end
          w.close
          return unless pid

          watch(fwd, pid, r)
          r = nil # the watcher closes it
          return unless ready?(fwd, ports["web_port"], pid)

          opened = @lock.synchronize do
            next false unless current?(fwd)

            fwd.state = "connected"
            fwd.detail = nil
            true
          end
          window(fwd.url) if opened
        rescue Refused => e
          fail_forward(fwd, e.message)
        rescue StandardError => e # an Errno from spawn, a pipe: the row says what, never stays on connecting
          fail_forward(fwd, "#{e.class}: #{e.message}")
        ensure
          w&.close unless w&.closed?
          r&.close unless r&.closed?
        end

        # `yaks env --ports` over ssh as a child of this forward (its pid in fwd.pid while it runs): Disconnect and the
        # chooser's end kill it like the forward itself, never an ssh left waiting on an unreachable host
        # → the ports, or nil once the forward is no longer the current connecting one
        def probe(fwd)
          out_r, out_w = IO.pipe
          err_r, err_w = IO.pipe
          pid = @lock.synchronize do
            next unless current?(fwd)

            @ctx.runner.spawn(*Remote.ports_argv(fwd.target), out: out_w, err: err_w).tap { fwd.pid = _1 }
          end
          [out_w, err_w].each(&:close)
          return unless pid

          err_reader = Thread.new { err_r.read }
          out = out_r.read
          err = err_reader.value
          _, status = Process.wait2(pid)
          still = @lock.synchronize do
            fwd.pid = nil if fwd.pid == pid
            current?(fwd)
          end
          still ? Remote.parse_ports!(fwd.target, out, err, status.exitstatus || 1) : nil
        ensure
          [out_r, out_w, err_r, err_w].each { _1&.close unless _1&.closed? }
        end

        def current?(fwd) = @forwards[fwd.target].equal?(fwd) && fwd.state == "connecting"

        def fail_forward(fwd, why)
          @lock.synchronize do
            next unless current?(fwd)

            fwd.state = "failed"
            fwd.detail = why
          end
        end

        # ssh's end, with its last stderr line: a forward that ends is never shown connected
        def watch(fwd, pid, err)
          Thread.new do
            words = err.read.to_s.lines.map(&:strip).reject(&:empty?).last(2).join(" · ")
            _, status = Process.wait2(pid)
            if @lock.synchronize { fwd.pid == pid && fwd.state != "stopped" }
              how = status.exitstatus ? "exit #{status.exitstatus}" : "signal #{status.termsig}"
              update(fwd, state: "failed", pid: nil, detail: "ssh ended (#{how})#{": #{words}" unless words.empty?}")
            end
          rescue Errno::ECHILD
            nil
          ensure
            err.close
          end
        end

        def ready?(fwd, port, pid)
          deadline = Time.now + @ready
          url = "http://#{DashboardUrl::LOOPBACK}:#{port}"
          while Time.now < deadline
            return true if Chooser.up?(url)
            return false unless alive?(pid)

            sleep 0.3
          end
          fail_forward(fwd, "#{url}/up did not answer 200 within #{@ready} s through the forward: stopped it")
          @lock.synchronize { fwd.pid = nil }
          kill(pid)
          false
        end

        def alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH
          false
        end

        def kill(pid)
          Process.kill("TERM", -pid) # its process group (Runner#spawn): ssh and anything it started
        rescue Errno::ESRCH
          nil
        end

        def update(fwd, **fields) = @lock.synchronize { fields.each { |k, v| fwd[k] = v } }

        def disconnect(target)
          fwd = @lock.synchronize { @forwards.delete(target) }
          raise Refused, "#{target} is not connected" unless fwd

          stop_forward(fwd)
        end

        def stop_forward(fwd)
          fwd.state = "stopped"
          kill(fwd.pid) if fwd.pid
        end

        # --- HTTP --------------------------------------------------------------------------------------------------

        def accept_loop
          loop do
            sock = @tcp.accept
            Thread.new(sock) { serve(_1) }
          end
        rescue IOError, SystemCallError
          nil
        end

        def serve(sock)
          req = Chooser.read_request(sock)
          return reply(sock, 400, "text/plain", "bad request") unless req
          return reply(sock, 421, "text/plain", "wrong host") unless req[:headers]["host"] == "#{DashboardUrl::LOOPBACK}:#{@port}"

          route(sock, req)
        rescue Refused => e
          reply(sock, 500, "text/plain", e.message)
        rescue IOError, SystemCallError
          nil
        ensure
          sock.close unless sock.closed?
        end

        def route(sock, req)
          path, query = req[:target].split("?", 2)
          return asset(sock, path) if req[:method] == "GET" && ASSETS.key?(path)
          return reply(sock, 200, "text/css; charset=utf-8", Chooser.skin_css(@ctx.home)) \
            if req[:method] == "GET" && path == "/skin.css"
          return launch(sock, query) if req[:method] == "GET" && path == "/" && query.to_s.start_with?("code=")
          return reply(sock, 403, "text/plain", "open the chooser from the app menu (yaks desktop open)") unless signed?(req)

          case [req[:method], path]
          when ["GET", "/"] then page(sock)
          when ["GET", "/events"] then events(sock)
          when ["POST", "/api/open"], ["POST", "/api/disconnect"], ["POST", "/api/add"], ["POST", "/api/remove"]
            post(sock, req, path)
          else reply(sock, 404, "text/plain", "not found")
          end
        end

        def signed?(req)
          cookie = req[:headers]["cookie"].to_s.split(/;\s*/).map { _1.split("=", 2) }.to_h[COOKIE]
          cookie.to_s.bytesize == @session.bytesize && OpenSSL.fixed_length_secure_compare(cookie, @session)
        end

        def launch(sock, query)
          given = URI.decode_www_form(query).to_h["code"].to_s
          return reply(sock, 403, "text/plain", "this launch link is used or expired: open busyyaks again") \
            unless use_code(given)

          reply(sock, 303, "text/plain", "", "location" => "/",
                                             "set-cookie" => "#{COOKIE}=#{@session}; HttpOnly; SameSite=Strict; Path=/")
        end

        def use_code(given)
          time, nonce, mac = given.split(".", 3)
          return false unless time && nonce && mac && time.match?(/\A\d+\z/) &&
                              (Time.now.to_i - time.to_i).between?(-5, CODE_TTL)

          want = OpenSSL::HMAC.hexdigest("SHA256", @secret, "#{time}.#{nonce}")
          return false unless want.bytesize == mac.bytesize && OpenSSL.fixed_length_secure_compare(want, mac)

          @lock.synchronize { @used.key?(nonce) ? false : (@used[nonce] = true) }
        end

        def page(sock) = reply(sock, 200, "text/html; charset=utf-8", File.read(File.join(PAGE_DIR, "index.html")))

        def asset(sock, path)
          file, type = ASSETS.fetch(path)
          reply(sock, 200, type, File.binread(File.expand_path(file, __dir__)), "cache-control" => "no-cache")
        end

        def events(sock)
          sock.write("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-store\r\n" \
                     "x-content-type-options: nosniff\r\n\r\n")
          @lock.synchronize do
            @clients += 1
            @seen = Time.now
          end
          begin
            loop do
              sock.write("data: #{JSON.generate(state)}\n\n")
              sock.flush
              sleep @tick
            end
          ensure
            @lock.synchronize do
              @clients -= 1
              @seen = Time.now
            end
          end
        end

        def post(sock, req, path)
          return reply(sock, 403, "text/plain", "cross-origin request refused") unless req[:headers]["origin"] == @origin

          body = JSON.parse(req[:body].to_s)
          target = body.is_a?(Hash) ? body["server"].to_s : ""
          case path
          when "/api/open" then open_server(target)
          when "/api/disconnect" then disconnect(Remote.target!(target))
          when "/api/add" then Remote.add!(@ctx, Remote.target!(target))
          when "/api/remove"
            Remote.remove!(@ctx, Remote.target!(target))
            disconnect(target) if @lock.synchronize { @forwards.key?(target) }
          end
          json(sock, 200, state)
        rescue Refused => e
          json(sock, 422, { error: e.message })
        rescue JSON::ParserError
          json(sock, 400, { error: "the body is not JSON" })
        end

        def json(sock, code, doc) = reply(sock, code, "application/json", JSON.generate(doc))

        REASONS = { 200 => "OK", 303 => "See Other", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
                    421 => "Misdirected Request", 422 => "Unprocessable Content", 500 => "Internal Server Error", }.freeze

        def reply(sock, code, type, body, extra = {})
          head = { "content-type" => type, "content-length" => body.bytesize.to_s, "connection" => "close",
                   "cache-control" => "no-store", "x-content-type-options" => "nosniff",
                   "content-security-policy" => CSP, "referrer-policy" => "no-referrer", }.merge(extra)
          sock.write("HTTP/1.1 #{code} #{REASONS.fetch(code)}\r\n#{head.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n")
          sock.write(body)
        end
      end

      # one HTTP/1.1 request off the socket → {method, target, headers (lower-case names), body}; nil when malformed
      # or over the limits
      def read_request(sock)
        head = +""
        until head.end_with?("\r\n\r\n")
          chunk = sock.readpartial(1)
          head << chunk
          return if head.bytesize > MAX_HEAD
        end
        line, *fields = head.split("\r\n")
        method, target, version = line.to_s.split(" ", 3)
        return unless %w[GET POST].include?(method) && target.to_s.start_with?("/") && version.to_s.start_with?("HTTP/1.")

        headers = fields.to_h { |f| k, v = f.split(":", 2); [k.to_s.strip.downcase, v.to_s.strip] }
        length = Integer(headers.fetch("content-length", "0"), exception: false)
        return unless length&.between?(0, MAX_BODY)

        body = length.zero? ? "" : sock.read(length)
        { method: method, target: target, headers: headers, body: body }
      rescue EOFError
        nil
      end

      # the two base skins' tokens (the checkout's skins/light.yml, dark.yml: one place per colour), light on :root and
      # dark under the system's dark scheme; a value that is not a colour → Refused (never written into CSS)
      COLOUR = /\A(?:#\h{3,8}|rgba?\([\d.,\s]+\))\z/
      TOKEN = /\A--[a-z0-9-]+\z/

      def skin_css(home)
        light, dark = %w[light dark].map do |base|
          path = File.join(home, "skins/#{base}.yml")
          tokens = YAML.safe_load_file(path).fetch("tokens")
          tokens.map do |k, v|
            raise Refused, "#{path}: #{k}: #{v.inspect} is not a colour" unless k.match?(TOKEN) && v.to_s.match?(COLOUR)

            "  #{k}: #{v};"
          end.join("\n")
        end
        ":root {\n  color-scheme: light;\n#{light}\n}\n@media (prefers-color-scheme: dark) {\n  :root {\n    " \
          "color-scheme: dark;\n#{dark.gsub(/^/, '  ')}\n  }\n}\n"
      end

      # GET <url>/up → 200 within 2 s
      def up?(url)
        uri = URI("#{url}/up")
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 2) do |h|
          h.get(uri.path).code == "200"
        end
      rescue SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
        false
      end
    end
  end
end
