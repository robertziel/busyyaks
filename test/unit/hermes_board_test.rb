# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "busyyaks/hermes_board"
require "busyyaks/agent_activity"
require "busyyaks/agent_screen"
require "busyyaks/engines"

# Hermes as a board agent: the per-launch overlay, the proof it holds, when a line may be typed. The screens
# are frames from a real Hermes pane (baef00bf; paths replaced).
class HermesBoardTest < Minitest::Test
  H = Busyyaks::HermesBoard
  URL = "http://127.0.0.1:8081/mcp"
  GOOD = H::PINNED.merge("mcp_servers.busyyaks.url" => URL).freeze
  USER = "model: {default: m}\nmcp_servers: {busyyaks: {enabled: false}}\n"

  def screen(name) = File.read(File.expand_path("../fixtures/screens/#{name}.txt", __dir__))
  def refusal(user: USER, values: GOOD)
    H.refusal(path: "/h/config.yaml", user_config: user, url: URL, get: values.method(:[]))
  end

  def test_mcp_comes_from_env_and_fails_loudly
    env = { "MCP_HOST" => "127.0.0.1", "MCP_HOST_PORT" => "8081", "MCP_TOKEN" => "t" * 32 }
    assert_equal({ url: URL, token: "t" * 32 }, H.mcp!(env))
    %w[MCP_HOST MCP_HOST_PORT MCP_TOKEN].each do |k|
      assert_match(/#{k} missing in \.env/, assert_raises(H::Invalid) { H.mcp!(env.except(k)) }.message)
    end
    assert_match(/MCP_TOKEN is empty/, assert_raises(H::Invalid) { H.mcp!(env.merge("MCP_TOKEN" => "")) }.message)
  end

  def test_the_overlay_is_private_and_holds_the_settings
    Dir.mktmpdir do |stage|
      dir = H.stage!(stage, { url: URL, token: "secret-token" })
      assert_equal 0o700, File.stat(dir).mode & 0o777
      file = File.join(dir, "config.yaml")
      assert_equal 0o600, File.stat(file).mode & 0o777
      doc = YAML.safe_load_file(file)
      assert_equal "queue", doc.dig("display", "busy_input_mode")
      assert_equal false, doc.dig("tools", "tool_search", "enabled")
      assert_equal({ "busy_input_prompt" => true, "tool_progress_prompt" => true }, doc.dig("onboarding", "seen"),
                   "Hermes would write these tips into the user's config.yaml")
      assert_equal "Bearer secret-token", doc.dig("mcp_servers", "busyyaks", "headers", "Authorization")
      assert_equal({ "HERMES_MANAGED_DIR" => dir, "HERMES_LANGUAGE" => "en" }, H.env(dir))
      refute_includes H.env(dir).values.join, "secret-token"
    end
  end

  def test_a_proven_session
    assert_nil refusal
  end

  def test_no_mcp_servers_is_refused_naming_the_inert_line
    ["model: {default: m}\n", "mcp_servers: {}\n", "- a\n"].each do |user|
      why = refusal(user: user)
      assert_includes why, "/h/config.yaml has no mcp_servers"
      assert_includes why, H::INERT
    end
    assert_includes refusal(user: nil), H::INERT
    assert_match(/not valid YAML/, refusal(user: "a: [\n"))
  end

  def test_a_setting_that_does_not_hold_is_refused
    assert_match(/busy_input_mode = "interrupt", not "queue"/,
refusal(values: GOOD.merge("display.busy_input_mode" => "interrupt")))
    assert_match(/url/, refusal(values: GOOD.merge("mcp_servers.busyyaks.url" => "http://other/mcp")))
    assert_match(/config get display.skin failed/, refusal(values: GOOD.merge("display.skin" => nil)))
  end

  def test_a_line_may_be_typed_at_the_plain_prompt_and_mid_turn
    %w[hermes_idle hermes_model_wait hermes_queued hermes_tool_running].each { |n| assert_nil H.paste_refusal(screen(n)), n }
  end

  def test_no_line_while_a_prompt_waits
    assert_match(/Enter to confirm/, H.paste_refusal(screen("hermes_approval_five")))
    base = "x\n#{'─' * 40}\n%s\n#{'─' * 40}\n"
    ["🔐 ❯", "🔑 ❯", "? ❯", "✎ ❯", "⚙ ❯", "⚠ ❯"].each { |row| assert_match(/asking/, H.paste_refusal(format(base, row)), row) }
    ["  password hidden · Enter to skip", "  type your answer and press Enter",
"  ↑/↓ to select, Enter to lock, Tab next question",].each do |hint|
      assert_match(/waiting/, H.paste_refusal("#{hint}\n status\n#{'─' * 40}\n\n#{'─' * 40}\n"), hint)
    end
    assert_match(/not on the screen/, H.paste_refusal("nothing here\n"))
  end

  def test_a_composer_holding_a_pasted_line_still_counts
    assert_nil H.paste_refusal("status\n#{'─' * 40}\n\nfirst line\nsecond\n#{'─' * 40}\n")
  end

  # frames of a real Hermes pane (`capture-pane -e`): its hint is italic, typed text never is
  def test_the_input_read_from_real_frames
    %w[idle cleared running].each { |n| assert_equal({ state: :empty }, H.input(File.read(input_path(n))), n) }
    assert_equal({ state: :text, text: "my draft" }, H.input(File.read(input_path("draft"))))
    assert_equal({ state: :text, text: "my draft" }, H.input(File.read(input_path("draft-home"))), "cursor at its start")
    assert_equal({ state: :text, text: "typed while running" }, H.input(File.read(input_path("running-draft"))))
    assert_match(/\A\[Pasted text #1: 4 lines → .*paste_1_\d+\.txt\]\z/, H.input(File.read(input_path("pasted")))[:text])
    assert_match(/\A\[Pasted text #3: 2 lines/, H.input(File.read(input_path("running-pasted")))[:text])
    assert_equal :unreadable, H.input("no composer\n")[:state]
  end

  def input_path(name) = File.expand_path("../fixtures/screens/hermes_input_#{name}.ansi", __dir__)

  def composer(body) = "status\n#{'─' * 40}\n#{body}\n#{'─' * 40}\n"

  def test_this_ping_is_known_by_the_bytes_of_its_paste_file
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "pastes"))
      file = File.join(dir, "pastes/paste_1_060019.txt")
      File.write(file, "line one\n\nline three")
      held = composer("❯ [Pasted text #1: 3 lines → #{file}]")
      assert_equal({ state: :ours }, H.input_state(held, "line one\n\nline three"))
      assert_equal :other, H.input_state(held, "line one\n\nline 3")[:state]
      cut = file.length / 2
      wrapped = composer("❯ [Pasted text #1: 3 lines → #{file[0...cut]}\n  #{file[cut..]}]")
      assert_equal({ state: :ours }, H.input_state(wrapped, "line one\n\nline three"), "a wrapped path")
      File.delete(file)
      assert_equal :unreadable, H.input_state(held, "line one")[:state], "never guessed"
    end
  end

  def test_a_paste_reference_outside_a_paste_file_is_never_read
    Dir.mktmpdir do |dir|
      other = File.join(dir, "secret.txt")
      File.write(other, "ping")
      assert_equal :unreadable, H.input_state(composer("❯ [Pasted text #1: 1 lines → #{other}]"), "ping")[:state]
    end
  end

  def test_a_draft_is_named_by_its_length_only
    r = H.input_state(File.read(input_path("draft")), "ping")
    assert_equal({ state: :other, why: "typed text (8 chars)" }, r)
  end

  def test_italic_is_tracked_through_colours
    assert_equal ["ab", false], H.upright("a\e[38;5;3mb", false), "the 3 of a colour is no italic"
    assert_equal ["a", true], H.upright("a\e[3;38;5;136mb", false)
    assert_equal ["b", false], H.upright("a\e[0mb", true)
    assert_equal ["b", false], H.upright("a\e[23mb", true)
    assert_equal ["b", false], H.upright("a\e[mb", true)
  end

  def test_records_prove_that_process_only
    Dir.mktmpdir do |dir|
      r = H::Records.new(dir)
      r.record(session: "s", pid: 5, start_ticks: 50, alive: ->(_) { true })
      assert_equal({ "pid" => 5, "start_ticks" => 50 }, H::Records.new(dir).proof("s", 5, 50), "survives a launcher restart")
      assert_nil r.proof("s", 5, 51), "a reused pid"
      assert_nil r.proof("s", 6, 50)
      assert_nil r.proof("other", 5, 50)
      r.record(session: "t", pid: 7, start_ticks: 70, alive: ->(n) { n != "s" })
      assert_nil r.proof("s", 5, 50), "a session gone is pruned"
      File.write(File.join(dir, "hermes-board.json"), "{")
      assert_raises(H::Invalid) { H::Records.new(dir) }
      File.write(File.join(dir, "hermes-board.json"), '[{"session":"s"}]')
      assert_raises(H::Invalid) { H::Records.new(dir) }
    end
  end

  def test_screen_states_from_real_panes
    rules = Busyyaks::AgentScreen::HERMES
    assert_equal "blocked", Busyyaks::AgentScreen.detect(rules, screen("hermes_approval_five"))[:state]
    assert_equal "idle", Busyyaks::AgentScreen.detect(rules, screen("hermes_idle"))[:state]
    %w[hermes_model_wait hermes_queued hermes_tool_running].each do |n|
      assert_equal "working", Busyyaks::AgentScreen.detect(rules, screen(n))[:state], n
    end
  end

  def test_phase_only_where_the_screen_says
    a = Busyyaks::AgentActivity.hermes(screen("hermes_tool_running"))
    assert_equal ["tool", 38, "↓ 41"], a.values_at(:phase, :elapsed_s, :tokens)
    assert_nil Busyyaks::AgentActivity.hermes(screen("hermes_model_wait")), "a random verb says neither thinking nor writing"
    assert_nil Busyyaks::AgentActivity.hermes(screen("hermes_idle"))
    assert_nil Busyyaks::AgentActivity.hermes("no status bar")
  end
end
