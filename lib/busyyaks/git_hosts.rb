# frozen_string_literal: true

require "json"
require "socket"
require "fileutils"
require "securerandom"
require_relative "clock"
require_relative "github_network"
require_relative "github_prs"
# (CiChecks and PrStates — Github#poll's — require this file to ask the connection: the github service loads them)

module Busyyaks
  # The git host busyyaks reads: GitHub today, GitLab "coming soon". Optional — nothing is connected on a
  # fresh install, and every surface that needs a host says so ("GitHub not connected — Settings → Git hosts"), never
  # a guess. Once .env GITHUB_LOGIN / GITHUB_TOKEN, required by compose.
  #
  # Two halves, kept apart:
  #   the connection (not secret)  table git_host_connections, one row per change (newest = current, every earlier one
  #                                kept): {provider | null, login, token_hint, author, created_at}. Read by web, mcp and
  #                                the notifier in place of ENV["GITHUB_LOGIN"].
  #   the token (secret)           a file <secrets dir>/<provider>.token (0600) in a directory bind-mounted ONLY into
  #                                the github service, written only by it (Store). The web hands a token over through
  #                                that service's socket (GIT_HOSTS_SOCKET, Server / Client), never keeps it.
  #
  # A provider is a class of its own; a new host is a new class in PROVIDERS, never an `if provider ==` branch in a
  # caller. What the github service does with a host goes through its provider: identify (connect), collect (the
  # account's network, feed and merged PRs, every github_interval_seconds) and poll (the PR states and CI checks the
  # board asks for, every github_ci_interval_seconds). The GitHub classes behind them (GithubNetwork, GithubFeed,
  # GithubPrs, PrStates, CiChecks) are the github provider's own; the webhook (GithubHook) is GitHub's inbound and
  # only marks their rows dirty.
  module GitHosts
    TABLE = :git_host_connections

    class Error < StandardError; end
    # the request is refused: unknown provider, a provider not available yet, an empty or rejected token
    class Refused < Error; end
    # the host could not be asked (unreachable, 5xx, rate limited): nothing is known about the token — 503, never
    # "refused"
    class Unreachable < Error; end

    class Provider
      def key = raise(NotImplementedError)
      def label = raise(NotImplementedError)
      def available? = true
      def note = nil
      # the token's own account → its login (Refused when the host rejects it, Unreachable when it cannot be asked)
      def identify(_token) = raise(NotImplementedError)
      # one collection of the account (network, feed, merged PRs) → the log line
      def collect(db:, login:, token:, since:) = raise(NotImplementedError)
      # one poll of what the board asked (PR states, CI checks) → {polled: n, failed: ["what: Class: message"]}; each
      # part runs whatever the other did; dirty: only the rows a webhook marked
      def poll(db:, token:, gate:, interval:, ci:, dirty: false) = raise(NotImplementedError)

      def to_h = { key: key, label: label, available: available?, note: note }
    end

    class Github < Provider
      def initialize(http: GithubNetwork::Http.new) = (@http = http)
      def key = "github"
      def label = "GitHub"

      def identify(token)
        raise Refused, "the GitHub token is empty" if token.to_s.strip.empty?

        login = client(token.strip).get("/user").body["login"].to_s
        raise Refused, "GitHub answered /user without a login" unless login.match?(GithubNetwork::LOGIN)

        login
      rescue GithubNetwork::Rejected => e
        raise Refused, "GitHub refused the token: #{e.message}"
      rescue GithubNetwork::Error => e # unreachable, 5xx, rate limited, a 403/404 at /user: the token is unknown
        raise Unreachable, "GitHub could not check the token: #{e.message}"
      end

      def client(token) = GithubNetwork::Client.new(token: token, http: @http)

      def collect(db:, login:, token:, since:)
        c = client(token)
        r = GithubNetwork::Collector.new(login: login, client: c, data: GithubNetwork::Data.new(db)).run
        pr = GithubPrs.collect(db: db, client: c, login: login, since: since)
        { network: r, prs: pr }
      end

      def poll(db:, token:, gate:, interval:, ci:, dirty: false)
        c = client(token) # one per poll: its counters are the poll's cost (GithubPollers)
        pollers = {
          "ci checks" => lambda {
            CiChecks::Poller.new(db: db, client: c, gate: gate, wanted_for: CiChecks.wanted_for(interval), ci: ci)
          },
          "pr states" => -> { PrStates::Poller.new(db: db, client: c, gate: gate, wanted_for: PrStates.wanted_for(interval)) },
        }
        out = { polled: 0, failed: [] }
        # one failing part never blanks the other, and the tick's cost is always recorded (the pause accounting)
        pollers.each do |what, poller|
          out[:polled] += poller.call.run(dirty: dirty)
        rescue StandardError => e
          out[:failed] << "#{what}: #{e.class}: #{e.message}"
        end
        out
      ensure
        gate.finished(c) if c
      end
    end

    # listed so the page shows where hosts go next; connecting it is refused
    class Gitlab < Provider
      def key = "gitlab"
      def label = "GitLab"
      def available? = false
      def note = "coming soon"
      def identify(_token) = raise(Refused, "GitLab is coming soon: it cannot be connected yet")
      def collect(**) = raise(Refused, "GitLab is coming soon: nothing is collected")
      def poll(**) = raise(Refused, "GitLab is coming soon: nothing is polled")
    end

    PROVIDERS = [Github, Gitlab].freeze

    module_function

    def providers(http: GithubNetwork::Http.new) = PROVIDERS.map { _1 == Github ? _1.new(http: http) : _1.new }
    def listing = providers.map(&:to_h)

    def provider!(key, http: GithubNetwork::Http.new)
      providers(http: http).find { _1.key == key } or
        raise Refused, "unknown git host #{key.inspect} (known: #{PROVIDERS.map { _1.new.key }.join(', ')})"
    end

    # → {id, provider, login, token_hint, author, at} of the connected host, or nil (none ever, or disconnected)
    def current(db)
      row = db[TABLE].order(Sequel.desc(:id)).first
      return nil unless row && row[:provider]

      { id: row[:id], provider: row[:provider], label: provider!(row[:provider]).label, login: row[:login],
        token_hint: row[:token_hint], author: row[:author], at: row[:created_at], }
    end

    # the GitHub account busyyaks reads, or nil when GitHub is not the connected host
    def github_login(db)
      cur = current(db)
      cur && cur[:provider] == "github" ? cur[:login] : nil
    end

    # what a surface says when it needs GitHub and none is connected
    def not_connected(label = "GitHub") = "#{label} not connected — Settings → Git hosts"

    def record!(db, provider:, login:, token_hint:, author:)
      db[TABLE].insert(provider: provider, login: login, token_hint: token_hint, author: author,
                       created_at: Clock.epoch)
    end

    def hint(token) = "…#{token.strip[-4..]}"

    # The token files, in the github service's own directory (compose: ./secrets/git-hosts, mounted only there).
    class Store
      def initialize(dir) = (@dir = dir)

      def path(provider) = File.join(@dir, "#{provider}.token")

      # → the token, or nil when there is no file
      def token(provider)
        t = File.read(path(provider)).strip
        t.empty? ? nil : t
      rescue Errno::ENOENT
        nil
      end

      # atomic, 0600 from the moment it exists; the temp name is this write's own (random), so a failure removes only it
      def write!(provider, token)
        FileUtils.mkdir_p(@dir, mode: 0o700)
        tmp = "#{path(provider)}.#{SecureRandom.hex(8)}.tmp"
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { _1.write("#{token.strip}\n") }
        File.rename(tmp, path(provider))
        tmp = nil
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      def remove!(provider) = FileUtils.rm_f(path(provider))
    end

    # connect: the token checked by its host first (its login), then the file, then the row — a refused token
    # changes nothing
    def connect!(db:, store:, provider:, token:, author:, http: GithubNetwork::Http.new)
      p = provider!(provider, http: http)
      login = p.identify(token)
      before = store.token(p.key)
      store.write!(p.key, token)
      begin
        record!(db, provider: p.key, login: login, token_hint: hint(token), author: author)
      rescue StandardError
        # the row is what says "connected": without it, the file goes back to what it was
        before ? store.write!(p.key, before) : store.remove!(p.key)
        raise
      end
      current(db)
    end

    # Test connection: the STORED token asked again (nothing written) → {ok: true, login, same: the login still the
    # connected one}; Refused / Unreachable as connect
    def test!(db:, store:, http: GithubNetwork::Http.new)
      cur = current(db) or raise Refused, not_connected("A git host")
      token = store.token(cur[:provider]) or raise Refused, "#{cur[:label]}'s token file is missing: connect it again"
      login = provider!(cur[:provider], http: http).identify(token)
      { ok: true, login: login, same: login == cur[:login] }
    end

    def disconnect!(db:, store:, author:)
      cur = current(db)
      PROVIDERS.each { store.remove!(_1.new.key) }
      record!(db, provider: nil, login: nil, token_hint: nil, author: author) if cur
      nil
    end

    # The github service's socket (bin/github): one JSON line in, one out ({status, body}), as the writer's.
    class Server
      def initialize(db:, store:, socket:, http: GithubNetwork::Http.new, log: ->(_) {})
        @db = db
        @store = store
        @socket = socket
        @http = http
        @log = log
      end

      def start
        Thread.new do
          loop do
            client = @socket.accept
            Thread.new(client) { |c| serve(c) }
          end
        rescue IOError, Errno::EBADF
          nil
        end
      end

      READ_TIMEOUT = 5 # s for the whole request line: a peer that sends nothing, or half a line, does not hold a thread
      MAX_LINE = 65_536 # bytes: a request is a provider, a token and who acts

      def serve(client)
        line = read_line(client) or return
        client.puts(handle(line))
      ensure
        client.close
      end

      # the request line against ONE deadline (each wait gets only the time left), at most MAX_LINE bytes → nil past
      # either
      def read_line(client, timeout: READ_TIMEOUT)
        deadline = Clock.monotonic + timeout
        buf = +""
        until buf.include?("\n")
          left = deadline - Clock.monotonic
          return nil if left <= 0 || buf.bytesize > MAX_LINE || !client.wait_readable(left)

          chunk = client.read_nonblock(4096, exception: false)
          return nil if chunk.nil? # closed before a whole line
          next if chunk == :wait_readable

          buf << chunk
        end
        buf.split("\n", 2).first
      end

      def handle(line)
        req = JSON.parse(line)
        status, body = req.is_a?(Hash) ? answer(req) : [400, { error: "the request is not an object" }]
        JSON.generate(status: status, body: body)
      rescue JSON::ParserError => e
        JSON.generate(status: 400, body: { error: "not JSON: #{e.message}" })
      rescue StandardError => e
        @log.call("git hosts: request failed: #{e.class}: #{e.message}")
        JSON.generate(status: 500, body: { error: "github service: #{e.class}: #{e.message}" })
      end

      private

      def answer(req)
        by = req["by"].to_s
        return [400, { error: "by (who acts) is required" }] if by.empty?

        case req["op"]
        when "connect"
          cur = GitHosts.connect!(db: @db, store: @store, provider: req["provider"].to_s, token: req["token"].to_s,
                                  author: by, http: @http)
          @log.call("git hosts: #{cur[:provider]} connected as #{cur[:login]} by #{by}")
          [200, { current: cur }]
        when "test" then [200, GitHosts.test!(db: @db, store: @store, http: @http)]
        when "disconnect"
          GitHosts.disconnect!(db: @db, store: @store, author: by)
          @log.call("git hosts: disconnected by #{by}")
          [200, { current: nil }]
        else [400, { error: "unknown op #{req['op'].inspect}" }]
        end
      rescue Refused => e
        [422, { error: e.message }]
      rescue Unreachable => e
        [503, { error: e.message }]
      end
    end

    # The web's line to that socket. No socket = Unavailable (503: the github service is down, nothing changed); sent
    # but unanswered = NoAnswer (504: it may still apply).
    module Client
      class Unavailable < StandardError; end
      class NoAnswer < StandardError; end

      TIMEOUT = 30 # s: a connect waits for GitHub's /user

      module_function

      def connect(provider, token, by:) = call({ op: "connect", provider: provider, token: token, by: by })
      def disconnect(by:) = call({ op: "disconnect", by: by })
      def test(by:) = call({ op: "test", by: by })

      def call(req, timeout: TIMEOUT)
        sock = ENV.fetch("GIT_HOSTS_SOCKET") # unset: KeyError naming it, never "no answer"
        begin
          UNIXSocket.open(sock) do |s|
            s.puts(JSON.generate(req))
            raise NoAnswer, "the github service did not answer within #{timeout} s" unless s.wait_readable(timeout)

            answer(s.gets.to_s)
          end
        rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES, Errno::EPIPE => e
          why = e.is_a?(Errno::ENOENT) ? "missing" : "refused"
          raise Unavailable, "the github service is not running (#{sock} #{why}): start it — docker compose up -d github"
        rescue IOError => e
          raise NoAnswer, "the github service gave no answer (#{e.class}): the change may still apply — reload"
        end
      end

      def answer(line)
        res = JSON.parse(line)
        [Integer(res.fetch("status")), res.fetch("body")]
      rescue JSON::ParserError, KeyError, TypeError => e
        raise NoAnswer, "the github service gave no answer (#{e.class}): the change may still apply — reload"
      end
    end
  end
end
