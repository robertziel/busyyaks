# frozen_string_literal: true

require "test_helper"
require "socket"
require "base64"
require "timeout"
require "busyyaks/terminal_endpoint"

# GET /api/terminal: every refusal before the upgrade, then the relay both ways over a hijacked socket —
# the launcher's frames to the browser, the browser's keys to the launcher only while the launcher confirmed control,
# and the audit events of who opened / took / released it.
class TerminalEndpointTest < Minitest::Test
  E = Busyyaks::TerminalEndpoint
  ORIGINS = { "127.0.0.1:4100" => "http://127.0.0.1:4100", "busy.example.com" => "https://busy.example.com" }.freeze
  KEY = Base64.strict_encode64("the sample nonce") # RFC 6455 § 1.3's example key
  ME = "owner@example.com"

  # the engine's side: open registrations by session, and the events written
  class FakeStore
    attr_reader :events

    def initialize(regs)
      @regs = regs
      @events = []
    end

    def open_session(name) = @regs[name]

    def terminal_event(session:, socket:, by:, text:)
      raise AgentsKanban::Denied, "gone" if @regs[session].nil?

      @events << [session, socket, by, text]
      [7]
    end
  end

  # the launcher's side: hands out one end of a socket pair (the test holds the other) or refuses
  class FakeLauncher
    attr_reader :far, :calls

    def initialize(refuse: nil)
      @refuse = refuse
      @calls = []
    end


    def attach(session:, socket:)
      @calls << [session, socket]
      raise @refuse if @refuse

      near, @far = UNIXSocket.pair
      [near, { "ok" => true, "session" => session, "cols" => 80, "rows" => 24, "screen" => "" }]
    end
  end

  def setup
    @store = FakeStore.new("agent_s" => { socket: "default" })
    @launcher = FakeLauncher.new
  end

  def endpoint(public_host: "deny", max_open: 2, launcher: @launcher)
    E.new(origins: -> { ORIGINS }, settings: Busyyaks::Terminal::Settings.new(public_host: public_host, max_open: max_open),
          public_host: "busy.example.com", store: -> { @store }, launcher: launcher)
  end

  def env(host: "127.0.0.1:4100", origin: "http://127.0.0.1:4100", session: { email: ME }, query: "session=agent_s",
          upgrade: true)
    @browser, server = UNIXSocket.pair
    e = { "REQUEST_METHOD" => "GET", "PATH_INFO" => E::PATH, "QUERY_STRING" => query, "HTTP_HOST" => host,
          "rack.session" => session, "rack.hijack" => -> { server }, }
    e["HTTP_ORIGIN"] = origin if origin
    if upgrade
      e.merge!("HTTP_UPGRADE" => "websocket", "HTTP_CONNECTION" => "keep-alive, Upgrade",
               "HTTP_SEC_WEBSOCKET_VERSION" => "13", "HTTP_SEC_WEBSOCKET_KEY" => KEY)
    end
    e
  end

  def refused(app, e)
    st, _h, body = app.call(e)
    [st, JSON.parse(body.join)["error"]]
  end

  # ── the browser's half of RFC 6455 (masked frames out, plain frames in) ──
  def send_text(str, op: 1, fin: true, mask: true)
    data = str.b
    bit = mask ? 0x80 : 0
    head = [(fin ? 0x80 : 0) | op].pack("C")
    head << if data.bytesize < 126
              [bit | data.bytesize].pack("C")
            else
              [bit | 126, data.bytesize].pack("Cn")
            end
    m = [1, 2, 3, 4]
    body = mask ? data.bytes.each_with_index.map { |b, i| b ^ m[i % 4] }.pack("C*") : data
    @browser.write(head, mask ? m.pack("C*") : "", body)
  end

  def recv
    Timeout.timeout(5) do
      b0, b1 = @browser.read(2).unpack("CC")
      len = b1 & 0x7f
      len = @browser.read(2).unpack1("n") if len == 126
      data = @browser.read(len)
      [b0 & 0x0f, data]
    end
  end

  def recv_json = JSON.parse(recv.last)

  # the 101 response exactly, up to its blank line: the first frame may already follow it in the socket
  def handshake
    Timeout.timeout(5) do
      head = +""
      head << @browser.read(1) until head.end_with?("\r\n\r\n")
      head
    end
  end

  def open!(app = endpoint)
    st, = app.call(env)
    assert_equal 200, st
    head = handshake
    assert_match(/\AHTTP\/1.1 101 Switching Protocols\r\n/, head)
    assert_includes head, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
    assert_equal({ "ok" => true, "session" => "agent_s", "cols" => 80, "rows" => 24, "screen" => "" }, recv_json)
    app
  end

  def test_refusals_before_the_upgrade
    app = endpoint
    assert_equal [401, "not signed in"], refused(app, env(session: {}))
    assert_equal [401, "not signed in"], refused(app, env(session: { email: "stranger@example.com" }))
    assert_equal 403, refused(app, env(origin: nil)).first
    assert_match(/no Origin/, refused(app, env(origin: nil)).last)
    assert_equal 403, refused(app, env(origin: "http://evil.example")).first
    assert_equal 403, refused(app, env(origin: "https://busy.example.com")).first, "another allowed host's origin"
    st, why = refused(app, env(host: "busy.example.com", origin: "https://busy.example.com"))
    assert_equal [403, true], [st, why.include?("terminal.public_host: deny")]
    assert_equal 400, refused(app, env(upgrade: false)).first
    assert_equal 400, refused(app, env(query: "session=a%20b")).first
    st, why = refused(app, env(query: "session=nobody_s"))
    assert_equal [404, true], [st, why.include?("no open registration")]
    assert_equal 404, refused(app, env(query: "session=agent_s&socket=other")).first, "registered on another socket"
    assert_empty @launcher.calls, "nothing refused reached the launcher"
    assert_empty @store.events
  end

  def test_public_host_allow_opens_there
    st, = endpoint(public_host: "allow").call(env(host: "busy.example.com", origin: "https://busy.example.com"))
    assert_equal 200, st
  end

  def test_launcher_refusal_and_outage_keep_their_status_and_free_the_slot
    no = FakeLauncher.new(refuse: Busyyaks::LauncherClient::AttachRefused.new("session agent_s is not running", status: 404))
    app = endpoint(launcher: no, max_open: 1)
    assert_equal [404, "session agent_s is not running"], refused(app, env)
    down = endpoint(launcher: FakeLauncher.new(refuse: Busyyaks::LauncherClient::Unavailable.new("launcher down")), max_open: 1)
    assert_equal [503, "launcher down"], refused(down, env)
    assert_equal [0, 0], [app.open_count, down.open_count]
    assert_empty @store.events
  end

  def test_relay_input_only_in_control_and_the_audit
    app = open!
    assert_equal [["agent_s", "default", ME, "opened the terminal (read-only)"]], @store.events
    far = @launcher.far
    far.puts(JSON.generate(o: "aGk="))
    assert_equal({ "o" => "aGk=" }, recv_json)

    send_text(JSON.generate(i: "eA=="))
    assert_equal({ "refused" => Busyyaks::Terminal::NOT_IN_CONTROL }, recv_json)
    send_text(JSON.generate(control: true))
    assert_equal({ "control" => true }, JSON.parse(far.gets), "control asked of the launcher")
    far.puts(JSON.generate(control: true)) # the launcher confirms
    assert_equal({ "control" => true }, recv_json)
    send_text(JSON.generate(i: "eA=="))
    assert_equal({ "i" => "eA==" }, JSON.parse(far.gets), "keys relayed once in control")
    send_text("nonsense")
    assert_match(/bad frame/, recv_json["refused"])
    far.puts(JSON.generate(control: false))
    assert_equal({ "control" => false }, recv_json)
    send_text(JSON.generate(i: "eA=="))
    assert_equal({ "refused" => Busyyaks::Terminal::NOT_IN_CONTROL }, recv_json)
    assert_equal ["opened the terminal (read-only)", "took control of the terminal", "released control of the terminal"],
                 @store.events.map(&:last)

    far.puts(JSON.generate(exit: "the tmux client ended"))
    assert_equal({ "exit" => "the tmux client ended" }, recv_json)
    far.close
    op, data = recv
    assert_equal [8, 1000], [op, data.unpack1("n")]
    Timeout.timeout(5) { sleep 0.05 until app.open_count.zero? }
  end

  def test_the_browser_closing_ends_the_launcher_stream_and_the_cap_holds
    app = endpoint(max_open: 1)
    open!(app)
    far = @launcher.far
    first = @browser
    st, why = refused(app, env)
    assert_equal [503, true], [st, why.include?("terminal.max_open")]
    @browser = first
    send_text([1000].pack("n"), op: 8)
    Timeout.timeout(5) { assert_nil far.gets, "the launcher's connection closed" }
    Timeout.timeout(5) { sleep 0.05 until app.open_count.zero? }
  end

  def test_ping_pong_and_protocol_refusals
    open!
    send_text("p", op: 9)
    assert_equal [10, "p"], recv
    send_text("x", op: 2)
    op, data = recv
    assert_equal [8, 1003], [op, data.unpack1("n")]
  end

  def test_unmasked_and_fragmented_frames_close
    open!
    send_text("{}", fin: false)
    op, data = recv
    assert_equal [8, 1003], [op, data.unpack1("n")]
    @store = FakeStore.new("agent_s" => { socket: "default" })
    @launcher = FakeLauncher.new
    open!
    send_text("{}", mask: false)
    op, data = recv
    assert_equal [8, 1002], [op, data.unpack1("n")]
  end

  def test_the_registration_ending_meanwhile_is_a_404_before_the_upgrade
    store = FakeStore.new("agent_s" => { socket: "default" })
    asked = 0
    store.define_singleton_method(:open_session) { |n| (asked += 1) == 1 ? @regs[n] : nil }
    @store = store
    app = endpoint
    st, why = refused(app, env)
    assert_equal [404, true], [st, why.include?("registration ended")]
    assert_nil @launcher.far.gets, "the launcher connection was closed"
    assert_equal [0, []], [app.open_count, store.events]
  end

  # past the upgrade a refusal is a close frame: nothing is logged as opened, the launcher stream is closed
  def test_the_registration_ending_after_the_upgrade_closes_1008
    store = FakeStore.new("agent_s" => { socket: "default" })
    def store.terminal_event(**) = raise(AgentsKanban::Denied, "session agent_s (socket default) has no open registration")
    @store = store
    app = endpoint
    st, = app.call(env)
    assert_equal 200, st
    assert_match(/\AHTTP\/1.1 101 /, handshake)
    op, data = recv
    assert_equal [8, 1008], [op, data.unpack1("n")]
    assert_includes data, "no open registration"
    assert_nil @launcher.far.gets, "the launcher connection was closed"
    assert_equal 0, app.open_count
  end

  # the store failing after the upgrade (a lock timeout): a 1011 close, the launcher stream closed, the slot freed
  def test_a_store_error_after_the_upgrade_closes_1011_and_frees_the_slot
    store = FakeStore.new("agent_s" => { socket: "default" })
    def store.terminal_event(**) = raise("lock timeout")
    @store = store
    app = endpoint(max_open: 1)
    st, = app.call(env)
    assert_equal 200, st
    assert_match(/\AHTTP\/1.1 101 /, handshake)
    op, data = recv
    assert_equal [8, 1011], [op, data.unpack1("n")]
    assert_includes data, "could not be logged: RuntimeError"
    assert_nil @launcher.far.gets, "the launcher connection was closed"
    assert_equal 0, app.open_count
  end

  def test_a_launcher_line_that_is_not_an_object_closes_1011
    app = open!
    @launcher.far.puts("1")
    op, data = recv
    assert_equal [8, 1011], [op, data.unpack1("n")]
    Timeout.timeout(5) { sleep 0.05 until app.open_count.zero? }
  end

  # RFC 6455 § 5.2 / 5.5 / 8.1: what no extension was negotiated for, a control frame that is fragmented or too long,
  # a 64-bit length with its top bit set (1002), text that is not UTF-8 (1007)
  def test_frames_the_rfc_forbids_close
    {
      -> { @browser.write([0xC1, 0x80].pack("CC"), "\x01\x02\x03\x04") } => 1002, # RSV1 on a text frame
      -> { send_text("p" * 126, op: 9) } => 1002,                                 # a 126-byte ping
      -> { send_text("p", op: 9, fin: false) } => 1002,                           # a fragmented ping
      -> { @browser.write([0x81, 0x80 | 127].pack("CC"), [2**63].pack("Q>"), "\x01\x02\x03\x04") } => 1002,
      -> { send_text("\xFF\xFE".b) } => 1007,                                     # not UTF-8
      -> { send_text("x", op: 3) } => 1002,                                       # a reserved data opcode
      -> { send_text("x", op: 0xB) } => 1002,                                     # a reserved control opcode
    }.each do |frame, code|
      @store = FakeStore.new("agent_s" => { socket: "default" })
      @launcher = FakeLauncher.new
      open!
      instance_exec(&frame)
      op, data = recv
      assert_equal [8, code], [op, data.unpack1("n")], data
    end
  end

  # the word-wise unmask: every tail length (0..3 bytes past a 4-byte word), bytes above 0x7f
  def test_masked_text_of_every_tail_length_reads_back
    open!
    far = @launcher.far
    send_text(JSON.generate(control: true))
    far.gets
    far.puts(JSON.generate(control: true))
    recv_json
    ["é", "ab", "abc", "abcd", "zażółć gęślą jaźń ✓"].each do |keys|
      frame = JSON.generate(i: Base64.strict_encode64(keys))
      send_text(frame)
      assert_equal frame, far.gets.chomp
    end
  end

  def test_websocket_key_and_accept
    ws = Busyyaks::WebSocket
    assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", ws.accept(KEY) # RFC 6455 § 1.3's example
    base = env
    assert_equal KEY, ws.key(base)
    assert_nil ws.key(base.merge("HTTP_SEC_WEBSOCKET_VERSION" => "8"))
    assert_nil ws.key(base.merge("HTTP_SEC_WEBSOCKET_KEY" => "short"))
    assert_nil ws.key(base.merge("HTTP_SEC_WEBSOCKET_KEY" => "!!!"))
    assert_nil ws.key(base.merge("HTTP_CONNECTION" => "keep-alive"))
    assert_nil ws.key(base.merge("REQUEST_METHOD" => "POST"))
  end

  def test_client_frames
    t = Busyyaks::Terminal
    assert_equal [:input, "x"], t.client_frame('{"i":"eA=="}')
    assert_equal [:control, false], t.client_frame('{"control":false}')
    { '{"control":"yes"}' => /true or false/, '{"i":"eA==","control":true}' => /a JSON object/, "[]" => /a JSON object/,
      '{"i":"***"}' => /bad frame/, '{"q":1}' => /unknown frame "q"/,
      JSON.generate(i: ["x" * (t::MAX_INPUT + 1)].pack("m0")) => /over 65536 bytes/,
      "x" * (t::MAX_LINE + 1) => /too long/, }.each do |line, msg|
      assert_match msg, assert_raises(t::Invalid) { t.client_frame(line) }.message
    end
    assert_raises(t::Invalid) { t.session!("a b", "default") }
    assert_raises(t::Invalid) { t.session!("a", "x/y") }
  end
end
