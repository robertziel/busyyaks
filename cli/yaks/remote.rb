# frozen_string_literal: true

require "etc"
require "fileutils"
require "io/console"
require "json"
require "optparse"
require "socket"
require "yaml"

# base64 through pack("m0") / unpack1("m"), never the base64 library: Ruby 3.4 moved it to a bundled gem that a distro's
# ruby may not carry (Alpine's: scripts/ci/host-distros), and yaks is stdlib only

module Busyyaks
  module CLI
    # `yaks remote …`: this machine reaches a busyyaks server on another one through the operator's own ssh
    # (keys, ssh-agent, ~/.ssh/config aliases, bastions — ssh's, never ours). No TCP listener or TLS of busyyaks's: the
    # dashboard comes through `ssh -L`, a terminal through `ssh <target> yaks remote --stdio`.
    #
    #   remote add TARGET          save a server (an ~/.ssh/config Host alias or user@host); connects to nothing
    #   remote list                the saved servers; connects to nothing
    #   remote remove TARGET       forget one
    #   remote connect TARGET [--mcp]
    #                              asks the server its ports (`ssh TARGET yaks env --ports`), then
    #                              `ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:P:127.0.0.1:P` (P = the server's
    #                              WEB_HOST_PORT: HostGuard answers exactly that Host, so the local end is the same port —
    #                              taken here → refused, never another one); --mcp also forwards the MCP port and prints the
    #                              `claude mcp add` line with the token as a $MCP_TOKEN placeholder (the bearer stays on the
    #                              server: never read, printed or carried by yaks)
    #   remote attach TARGET SESSION [--socket S]
    #                              an agent's terminal here, over `ssh TARGET yaks remote --stdio` (Ctrl-] Ctrl-T takes or
    #                              releases control, Ctrl-] q detaches)
    #   (the desktop app: `yaks desktop open`, Chooser — the saved servers in a window of their own)
    #   remote --stdio             (server side, what ssh runs) bridges stdin/stdout to the launcher socket for one op of
    #                              STDIO_OPS; the socket must be this user's
    #
    # The saved servers: the per-user file remotes_path (XDG config dir), mode 0600, never in a checkout.
    module Remote
      # a Host alias or user@host: what ssh takes as a destination, never an option (no leading -)
      TARGET = /\A(?:[A-Za-z0-9._][A-Za-z0-9._-]{0,63}@)?[A-Za-z0-9_][A-Za-z0-9._-]{0,252}\z/
      # the launcher ops `--stdio` carries: the terminal stream, nothing else
      STDIO_OPS = %w[attach].freeze
      SESSION = /\A[A-Za-z0-9._-]{1,100}\z/
      SOCKET = /\A[\w.-]{1,64}\z/
      MAX_LINE = 256 * 1024
      # ssh: fail fast on a dead link, so the page (and attach) say down within seconds, not minutes
      ALIVE = ["-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2"].freeze
      PREFIX = "\x1d" # Ctrl-]
      SSH_NOT_FOUND = 127
      # ssh gives up on a host that never answers after this long (else the OS TCP timeout, ~2 min, before its reason)
      CONNECT = ["-o", "ConnectTimeout=10"].freeze
      # the desktop chooser's own row: a saved server by that name could never be told apart from it
      RESERVED = %w[local].freeze

      module_function

      def run(ctx, args)
        return stdio(ctx, args.drop(1)) if args.first == "--stdio"

        case (sub = args.shift)
        when "add" then add(ctx, one_target!(args, "add"))
        when "list" then list(ctx, args)
        when "remove" then remove(ctx, one_target!(args, "remove"))
        when "connect" then connect(ctx, args)
        when "attach" then attach(ctx, args)
        else raise Usage, "remote needs add, list, remove, connect, attach or --stdio#{" (got #{sub.inspect})" if sub}"
        end
      end

      # --- the saved servers -------------------------------------------------------------------------------------------

      def remotes_path(ctx)
        base = ctx.env["XDG_CONFIG_HOME"].to_s
        if base.empty?
          home = ctx.env["HOME"].to_s
          raise Refused, "HOME is not set (the saved servers live in $XDG_CONFIG_HOME or ~/.config)" if home.empty?

          base = File.join(home, ".config")
        end
        File.join(base, "busyyaks", "remotes.yml")
      end

      def target!(value)
        raise Refused, "#{value.inspect} is reserved (the desktop chooser's Local row): use another ~/.ssh/config Host alias" \
          if RESERVED.include?(value)
        return value if value.to_s.match?(TARGET)

        raise Refused, "#{value.inspect} is not an ssh target: a ~/.ssh/config Host alias or user@host (letters, " \
                       "digits, . _ -; never starting with -)"
      end

      def one_target!(args, sub)
        raise Usage, "remote #{sub} needs one TARGET" unless args.size == 1

        target!(args.first)
      end

      # → [targets]; no file = none saved; a malformed file → Refused naming it (never rewritten)
      def saved(ctx)
        path = remotes_path(ctx)
        return [] unless File.exist?(path)

        doc = YAML.safe_load_file(path)
        list = doc.is_a?(Hash) && doc.keys == ["remotes"] ? doc["remotes"] : nil
        unless list.is_a?(Array) && list.all? { _1.is_a?(Hash) && _1.keys == ["target"] && _1["target"].to_s.match?(TARGET) &&
                                   !RESERVED.include?(_1["target"]) }
          raise Refused, "#{path}: not a remotes file ({remotes: [{target: …}]}); fix or remove it"
        end

        list.map { _1["target"] }
      rescue Psych::Exception => e
        raise Refused, "#{path}: #{e.message}"
      end

      def save(ctx, targets)
        path = remotes_path(ctx)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        tmp = "#{path}.new-#{Process.pid}"
        begin
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
            f.write(YAML.dump("remotes" => targets.map { { "target" => _1 } }))
          end
          File.rename(tmp, path)
        ensure
          FileUtils.rm_f(tmp)
        end
      end

      # add! / remove!: the one writer of the saved servers (the CLI below and the desktop chooser's Add / Remove)
      def add!(ctx, target)
        targets = saved(ctx)
        raise Refused, "#{target} is already saved" if targets.include?(target)

        save(ctx, targets + [target])
      end

      def remove!(ctx, target)
        targets = saved(ctx)
        raise Refused, "#{target} is not saved (yaks remote list)" unless targets.include?(target)

        save(ctx, targets - [target])
      end

      def add(ctx, target)
        add!(ctx, target)
        ctx.out.puts "saved #{target} (nothing connected: yaks remote connect #{target})"
        0
      end

      def list(ctx, args)
        CLI.no_more!(args)
        targets = saved(ctx)
        ctx.out.puts(targets.empty? ? "no remote servers saved (yaks remote add TARGET)" : targets)
        0
      end

      def remove(ctx, target)
        remove!(ctx, target)
        ctx.out.puts "removed #{target}"
        0
      end

      def known!(ctx, target)
        target!(target)
        return target if saved(ctx).include?(target)

        raise Refused, "#{target} is not a saved server: yaks remote add #{target} first (yaks remote list)"
      end

      # --- connect -----------------------------------------------------------------------------------------------------

      # The server's own answer to `yaks env --ports` → {host, web_port, mcp_host, mcp_port}; ssh failing, no yaks
      # there or a malformed answer → Refused with ssh's / the server's reason
      def ports!(ctx, target) = parse_ports!(target, *ctx.runner.capture_all(*ports_argv(target)))

      def ports_argv(target) = ["ssh", "-T", "-o", "BatchMode=yes", *CONNECT, target, "--", "yaks", "env", "--ports"]

      # ssh's stdout, stderr and exit status of ports_argv → the ports, or Refused with ssh's / the server's reason
      def parse_ports!(target, out, err, status)
        if status == SSH_NOT_FOUND
          raise Refused, "#{target} has no busyyaks: `yaks` is not on its PATH for ssh commands (#{err.strip})"
        end
        raise Refused, "ssh #{target} failed (exit #{status}): #{err.strip.empty? ? 'no reason given' : err.strip}" \
          unless status.zero?

        ports = JSON.parse(out)
        ok = ports.is_a?(Hash) && ports.keys.sort == %w[host mcp_host mcp_port web_port] &&
             ports["host"].to_s.match?(/\A[A-Za-z0-9._-]{1,253}\z/) &&
             %w[web_port mcp_port].all? { DeployTemplate::PORT.call(ports[_1].to_s) } &&
             ports["mcp_host"].to_s.match?(/\A127(?:\.\d{1,3}){3}\z/)
        raise Refused, "#{target}: yaks env --ports answered #{out.strip[0, 200].inspect}, not its ports" unless ok

        ports
      rescue JSON::ParserError
        raise Refused, "#{target}: yaks env --ports answered #{out.to_s.strip[0, 200].inspect}, not JSON"
      end

      # the local end of a forward must be free here: the dashboard's Host is 127.0.0.1:<the server's port>
      def free!(port, what)
        TCPServer.new(DashboardUrl::LOOPBACK, Integer(port)).close
      rescue Errno::EADDRINUSE
        raise Refused, "#{DashboardUrl::LOOPBACK}:#{port} is taken on this machine (#{what} forwards to the same port: " \
                       "the server answers only Host 127.0.0.1:#{port}); stop what listens there (another busyyaks, " \
                       "another connect) and connect again"
      end

      def dashboard_url(ports) = "http://#{DashboardUrl::LOOPBACK}:#{ports['web_port']}/?remote=#{ports['host']}"

      def connect(ctx, args)
        mcp = false
        CLI.parse!(OptionParser.new { |o| o.on("--mcp") { mcp = true } }, args)
        raise Usage, "remote connect needs one TARGET" unless args.size == 1

        target = known!(ctx, args.first)
        ports = ports!(ctx, target)
        free!(ports["web_port"], "the dashboard")
        free!(ports["mcp_port"], "the MCP") if mcp
        loop = DashboardUrl::LOOPBACK
        ctx.out.puts "#{ports['host']} (#{target}): #{dashboard_url(ports)}"
        if mcp
          ctx.out.puts "MCP: claude mcp add --transport http --scope local busyyaks-#{ports['host']} " \
                       "\"http://#{loop}:#{ports['mcp_port']}/mcp\" --header \"Authorization: Bearer $MCP_TOKEN\"",
                       "     MCP_TOKEN = #{ports['host']}'s .env MCP_TOKEN: copy it yourself, yaks never reads or sends it"
        end
        ctx.out.puts "forwarding until ssh ends (Ctrl-C)"
        ctx.out.flush
        ctx.runner.exec(*forward_argv(target, ports, mcp: mcp))
        0
      end

      # the forward: the server's web port (and with mcp its MCP port) on the same port here, until ssh ends; batch
      # (the desktop chooser: no terminal to ask on) → ssh never prompts, a key it cannot use fails with ssh's reason
      def forward_argv(target, ports, mcp: false, batch: false)
        loop = DashboardUrl::LOOPBACK
        forwards = ["-L", "#{loop}:#{ports['web_port']}:#{loop}:#{ports['web_port']}"]
        forwards += ["-L", "#{loop}:#{ports['mcp_port']}:#{ports['mcp_host']}:#{ports['mcp_port']}"] if mcp
        ["ssh", "-N", "-o", "ExitOnForwardFailure=yes", *(batch ? ["-o", "BatchMode=yes", *CONNECT] : []), *ALIVE, *forwards,
         target,]
      end

      # --- the server side: ssh's stdin/stdout ↔ the launcher socket ---------------------------------------------------

      def stdio(ctx, args)
        CLI.no_more!(args)
        Host.stack!(ctx)
        line = ctx.stdin.gets("\n", MAX_LINE)
        request!(line)
        sock = File.join(ctx.dotenv_values("LAUNCHER_RUN_DIR").fetch("LAUNCHER_RUN_DIR"), "launcher.sock")
        owner!(sock)
        UNIXSocket.open(sock) do |s|
          s.write(line.end_with?("\n") ? line : "#{line}\n")
          pump(ctx.stdin, s, ctx.out)
        end
        0
      rescue Refused => e
        ctx.out.write("#{JSON.generate(ok: false, error: e.message)}\n")
        ctx.out.flush
        raise
      rescue Errno::ENOENT, Errno::ECONNREFUSED => e
        raise Refused, "the launcher socket is down (#{e.class.name.split('::').last}): systemctl --user status " \
                       "busyyaks-launcher"
      end

      def request!(line)
        raise Refused, "no request on stdin" if line.nil? || line.strip.empty?
        raise Refused, "request over #{MAX_LINE} bytes" unless line.end_with?("\n") || line.bytesize < MAX_LINE

        req = JSON.parse(line)
        raise Refused, "a request is a JSON object" unless req.is_a?(Hash)
        unless STDIO_OPS.include?(req["op"])
          raise Refused, "op #{req['op'].inspect} is not carried over ssh (only #{STDIO_OPS.join(', ')})"
        end
        raise Refused, "#{req['session'].inspect} is not a tmux session name" unless name?(req["session"], SESSION)
        raise Refused, "#{req['socket'].inspect} is not a tmux socket name" unless name?(req["socket"], SOCKET)

        req
      rescue JSON::ParserError => e
        raise Refused, "the request is not JSON: #{e.message}"
      end

      def name?(value, pattern) = value.is_a?(String) && value.match?(pattern)

      # owner-only: the socket (and so the launcher) must be this user's — never a bridge into another account's
      def owner!(sock)
        st = File.lstat(sock)
        raise Refused, "#{sock} is not a socket" unless st.socket?
        raise Refused, "#{sock} belongs to uid #{st.uid}, not this user (#{Process.uid})" unless st.uid == Process.uid
      rescue Errno::ENOENT
        raise Refused, "no launcher socket at #{sock}: systemctl --user status busyyaks-launcher"
      end

      # both ways until the launcher ends the stream; stdin's EOF (ssh gone) closes our half so the launcher ends it
      def pump(inp, sock, out)
        up = Thread.new do
          loop { sock.write(inp.readpartial(16_384)) } # readpartial: the bytes gets already buffered come first
        rescue EOFError
          nil
        rescue IOError, SystemCallError
          nil
        ensure
          half_close(sock)
        end
        loop do
          out.write(sock.readpartial(16_384))
          out.flush
        end
      rescue EOFError, IOError, SystemCallError
        nil
      ensure
        up&.kill
      end

      def half_close(sock)
        sock.close_write
      rescue IOError, SystemCallError
        nil
      end

      # --- attach: an agent's terminal here, over ssh ------------------------------------------------------------------

      def attach(ctx, args)
        socket = "default"
        CLI.parse!(OptionParser.new { |o| o.on("--socket NAME") { socket = _1 } }, args)
        raise Usage, "remote attach needs TARGET SESSION" unless args.size == 2

        target = known!(ctx, args[0])
        session = args[1]
        raise Refused, "#{session.inspect} is not a tmux session name (A-Z a-z 0-9 . _ -)" unless session.match?(SESSION)
        raise Refused, "#{socket.inspect} is not a tmux socket name" unless socket.match?(SOCKET)

        code = nil
        ctx.runner.stream("ssh", "-T", *ALIVE, target, "--", "yaks", "remote", "--stdio") do |w, r|
          w.write("#{JSON.generate(op: 'attach', session: session, socket: socket)}\n")
          w.flush
          code = Attach.new(ctx, w, r, target).run
        end
        code || 1
      end

      # The client end of the terminal stream (the frames of Busyyaks::Terminal), on this terminal: read-only
      # first; PREFIX then t flips control (the launcher confirms), PREFIX then q detaches. Keys are sent only in control.
      class Attach
        def initialize(ctx, w, r, target)
          @ctx = ctx
          @w = w
          @r = r
          @target = target
          @control = false
        end

        def run
          first = @r.gets("\n", MAX_LINE)
          raise Refused, "#{@target}: the stream ended before an answer (is busyyaks there?)" unless first

          hello = JSON.parse(first)
          raise Refused, "#{@target}: #{hello['error']}" unless hello["ok"]

          note("attached to #{hello['session']} on #{@target}, read-only — Ctrl-] t: take control · Ctrl-] q: detach")
          @ctx.out.write(hello["screen"].to_s.unpack1("m"))
          raw { loop_frames }
          0
        rescue JSON::ParserError
          raise Refused, "#{@target}: the stream did not answer JSON"
        end

        def note(text) = @ctx.err.puts("\r\n[yaks] #{text}\r")

        def raw(&)
          @ctx.stdin.tty? ? @ctx.stdin.raw(&) : yield
        end

        def loop_frames
          keys = Thread.new { read_keys }
          loop do
            line = @r.gets("\n", MAX_LINE)
            break unless line && frame(JSON.parse(line))
          end
        rescue JSON::ParserError
          note("the stream sent something that is not JSON: detached")
        ensure
          keys&.kill
        end

        # → false when the stream ends
        def frame(f)
          if f.key?("o") then @ctx.out.write(f["o"].to_s.unpack1("m"))
          elsif f.key?("control")
            @control = f["control"] == true
            note(@control ? "control taken: your keys reach the agent" : "control released: read-only")
          elsif f.key?("refused") then note("refused: #{f['refused']}")
          elsif f.key?("exit")
            note("ended: #{f['exit']}")
            return false
          end
          @ctx.out.flush
          true
        end

        def read_keys
          prefix = false
          loop do
            @ctx.stdin.readpartial(4096).each_char do |c|
              if prefix
                prefix = false
                next put(control: !@control) if c == "t"
                return detach if c == "q"

                key(PREFIX + c)
              elsif c == PREFIX then prefix = true
              else key(c)
              end
            end
          end
        rescue EOFError, IOError
          detach
        end

        def key(bytes)
          return note("read-only: Ctrl-] t takes control first") unless @control

          put(i: [bytes].pack("m0"))
        end

        def put(frame)
          @w.write("#{JSON.generate(frame)}\n")
          @w.flush
        end

        def detach
          note("detached")
          @w.close
        rescue IOError
          nil
        end
      end
    end
  end
end
