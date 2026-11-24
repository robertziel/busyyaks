#!/usr/bin/env ruby
# frozen_string_literal: true

# The driver of scripts/harness-lab/board-e2e, run in the harness image beside the real Hermes, tmux,
# bin/launcher and bin/collector. Every step prints PASS <name>, or FAIL <name>: <why> and exits 1.
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "socket"
require "yaml"
require_relative "../../lib/busyyaks/clock"
require_relative "../../lib/busyyaks/hermes_board"

class StepFailed < StandardError; end

class BoardE2E
  INERT = "mcp_servers: {busyyaks: {enabled: false}}"
  SKILLS_LINE = "${BUSYYAKS_SKILLS_DIR}/busyyaks-skills"

  def initialize(base)
    @base = base
    @mock = File.join(base, "mock")
    @config = File.join(base, "home/.hermes/config.yaml")
    @env = File.readlines(File.join(base, "app/.env"), chomp: true).grep(/\A[A-Z_]+=/).to_h { |l| l.split("=", 2) }
    @web = Integer(@env.fetch("WEB_HOST_PORT"), 10) # chosen free by board-e2e at run time
    @log = File.open(File.join(base, "out/steps.log"), "a")
  end

  def run
    open_session
    refused_without_mcp_servers
    File.write(@config, user_config(mcp: true))
    @config_bytes = File.binread(@config)
    hand_started_refused
    config_identical("after_hand_started")
    flow
    left_lines
    config_identical("after_the_flow")
    secrets
  rescue StepFailed => e
    say("FAIL #{e.message}")
    snap("failed") if @worker
    pending = card.fetch("card")["pings"] || card["pings"]
    say("pings on the card: #{pending.inspect[0, 600]}") if pending
    exit 1
  end

  private

  # the user's config.yaml, byte for byte; a difference is kept in the output dir (the file holds no secret)
  def config_identical(where)
    now = File.binread(@config)
    File.binwrite(File.join(@base, "out/user-config-#{where}.yaml"), now) unless now == @config_bytes
    step("user_config_byte_identical:#{where}", "changed: see user-config-#{where}.yaml") { now == @config_bytes }
  end

  def say(line)
    puts line
    $stdout.flush
    @log.puts(line)
    @log.flush
  end

  def step(name, why = "not true")
    raise StepFailed, "#{name}: #{why}" unless yield

    say("PASS #{name}")
  end

  def wait(name, seconds = 90)
    deadline = Busyyaks::Clock.monotonic + seconds
    loop do
      value = yield
      if value
        say("PASS #{name}")
        return value
      end
      raise StepFailed, "#{name}: not within #{seconds}s" if Busyyaks::Clock.monotonic > deadline

      sleep 0.5
    end
  end

  # the scripted model's port, chosen free by board-e2e at run time (BOARD_E2E_MODEL_PORT, required)
  def model_url = "http://127.0.0.1:#{Integer(ENV.fetch('BOARD_E2E_MODEL_PORT'), 10)}/v1"

  def user_config(mcp:)
    doc = { "model" => { "default" => "lab-model", "provider" => "custom", "base_url" => model_url, "api_key" => "lab",
                         "context_length" => 200_000, },
            "approvals" => { "mode" => "manual" }, "skills" => { "external_dirs" => [SKILLS_LINE] }, }
    doc["mcp_servers"] = { "busyyaks" => { "enabled" => false } } if mcp
    YAML.dump(doc)
  end

  # ── the operator's web API ──
  def http(request)
    request["Host"] = "127.0.0.1:#{@web}"
    request["Origin"] = "http://127.0.0.1:#{@web}"
    request["Accept"] = "application/json"
    request["Cookie"] = @cookie if @cookie
    request["X-CSRF-Token"] = @csrf if @csrf
    Net::HTTP.start("127.0.0.1", @web, read_timeout: 150) { |h| h.request(request) }
  end

  def open_session
    File.write(@config, user_config(mcp: false))
    res = http(Net::HTTP::Get.new("/"))
    @cookie = res.get_fields("set-cookie").map { |c| c.split(";").first }.join("; ")
    @csrf = res.body[/csrf-token" content="([^"]+)/, 1]
    step("web_session", "no CSRF token") { @csrf }
    wait("project_scanned") { api(:get, "/api/projects/demo/board").first == 200 }
    status, body = api(:post, "/api/projects/demo/board", "title" => "E2E Hermes card", "column" => "todo")
    step("card_created", "#{status}: #{body}") { status == 201 }
    @id = body.fetch("card").fetch("id")
    File.write(File.join(@mock, "card"), @id.to_s)
  end

  def api(method, path, body = nil)
    req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(path, "Content-Type" => "application/json")
    req.body = JSON.generate(body) if body
    res = http(req)
    [res.code.to_i, JSON.parse(res.body.to_s.empty? ? "{}" : res.body)]
  end

  def card = api(:get, "/api/cards/#{@id}").last
  def face = card.fetch("card")
  def said?(word) = card.fetch("activity").any? { |a| a["body"].to_s.include?(word) }
  def comment(body) = api(:post, "/api/cards/#{@id}/comment", "body" => body).first

  # ── the box ──
  def tmux(*args) = Open3.capture2e("tmux", *args).first
  def screen(session = @worker) = tmux("capture-pane", "-p", "-t", "=#{session}:")
  def session?(name) = Open3.capture2e("tmux", "has-session", "-t", "=#{name}").last.success?

  def snap(name)
    FileUtils.mkdir_p(File.join(@base, "out/screens"))
    File.write(File.join(@base, "out/screens/#{name}.txt"), screen)
  end

  def launcher(req)
    UNIXSocket.open(File.join(@base, "run/launcher.sock")) do |s|
      s.puts(JSON.generate(req))
      JSON.parse(s.gets)
    end
  end

  def turns
    file = File.join(@mock, "turns.jsonl")
    File.exist?(file) ? File.readlines(file).map { |l| JSON.parse(l) } : []
  end

  def reached_model?(word) = turns.any? { |t| Array(t["user"]).include?(word) }
  def mock_file?(name) = File.exist?(File.join(@mock, name))

  # ── real refusals ──
  def refused_without_mcp_servers
    before = File.binread(@config)
    status, body = api(:post, "/api/launch", "slug" => "demo", "type" => "lead", "launcher" => "hermes")
    error = body["error"].to_s
    step("no_mcp_servers_refused_at_launch", "#{status}: #{error[0, 300]}") { status == 422 }
    step("refusal_names_file_and_line", error[0, 300]) { error.include?(@config) && error.include?(INERT) }
    step("refused_session_killed") { !session?("demo_teamlead") }
    step("refused_stage_removed") { !File.exist?(File.join(@base, "state/skills/demo_teamlead")) }
    step("refusal_left_user_config_unchanged") { File.binread(@config) == before }
  end

  def hand_started_refused
    Open3.capture2e("tmux", "new-session", "-d", "-s", "byhand", "-x", "100", "-y", "30",
                    "-c", File.join(@base, "projects/demo"), "hermes", "chat")
    wait("hand_started_in_snapshot") do
      snap = JSON.parse(File.read(File.join(@base, "collector/sessions.json")))
      snap["sessions"].any? { |s| s["name"] == "byhand" && s["panes"].any? { |p| p["engine"] == "hermes" } }
    end
    r = launcher("op" => "notify", "session" => "byhand", "socket" => "default", "text" => "E2E_BY_HAND")
    step("hand_started_refused_with_reason", r.to_s) do
      r["unsupported"] == true && r["error"].to_s.include?("not launched by busyyaks in queue mode")
    end
    step("hand_started_nothing_typed") { !screen("byhand").include?("E2E_BY_HAND") }
    tmux("kill-session", "-t", "=byhand")
  end

  # ── the card's flow ──
  def flow
    status, body = api(:post, "/api/launch", "slug" => "demo", "type" => "lead", "launcher" => "hermes")
    step("lead_launched", "#{status}: #{body['error'].to_s[0, 400]}") { status == 201 }
    lead = body.fetch("session")
    @worker = wait("lead_spawned_worker_owning_card", 150) { (o = face["owner_session"]) && o != lead && o }
    wait("worker_comment_through_mcp") { said?("E2E_W1") }
    sleep 3
    step("comment_posted") { comment("E2E_OP_COMMENT please") == 201 }
    wait("comment_ping_reached_worker", 60) { said?("E2E_W2") }
    wait("turn_held") { mock_file?("holding") }
    step("mid_turn_comment_posted") { comment("E2E_OP_SECOND mid-turn") == 201 }
    wait("mid_turn_ping_queued", 45) { screen.include?("Queue · 1 queued") }
    snap("queued")
    step("mid_turn_ping_kept_the_turn") { !reached_model?("E2E_OP_SECOND") && !said?("E2E_W3") }
    File.write(File.join(@mock, "release"), "1")
    wait("queued_ping_became_the_ask", 45) { face["needs_operator"] }
    step("held_answer_kept") { turns.any? { |t| Array(t["user"]).include?("E2E_OP_SECOND") && t["history_has_slow_answer"] } }
    step("answer_posted") { comment("E2E_ANSWER blue") == 201 }
    wait("answer_cleared_the_flag", 20) { !face["needs_operator"] }
    approvals
    wait("handoff_into_gate", 60) { face["handoff"] && face["column"] == "human_check" }
    wait("ping_held_through_the_dialog_arrived", 60) { reached_model?("E2E_DURING_DIALOG") }
    settle
    %w[E2E_OP_COMMENT E2E_OP_SECOND E2E_ANSWER E2E_DURING_DIALOG].each do |word|
      step("exactly_one_delivery:#{word}", "#{copies(word)} copies") { copies(word) == 1 }
    end
  end

  def approvals
    wait("approval_panel_on_screen", 45) { screen.include?("Dangerous Command") && screen.include?("denied-ran") }
    step("comment_during_dialog_posted") { comment("E2E_DURING_DIALOG while the panel is open") == 201 }
    sleep 12
    step("ping_left_the_panel_open") { screen.include?("Dangerous Command") && screen.include?("Allow once") }
    dialog = wait("dialog_became_card_question", 75) { face["needs_operator"] && face["dialog"] }
    keys = dialog.fetch("options").to_h { |o| [o["label"], o["key"]] }
    step("card_offers_the_screens_keys", keys.to_s) { keys["Deny"] == "4" && keys["Allow once"] == "1" }
    step("command_waited_for_the_answer") { !mock_file?("denied-ran") }
    step("deny_pressed_from_card") { api(:post, "/api/cards/#{@id}/dialog-answer", "key" => keys.fetch("Deny")).first == 200 }
    wait("second_panel_after_the_deny", 45) { screen.include?("Dangerous Command") && screen.include?("shell-ran") }
    step("denied_command_did_not_run") { !mock_file?("denied-ran") }
    snap("approval")
    allow = wait("second_dialog_on_card", 75) { face["needs_operator"] && face["dialog"] }
    key = allow.fetch("options").find { |o| o["label"] == "Allow once" }.fetch("key")
    step("allow_pressed_from_card") { api(:post, "/api/cards/#{@id}/dialog-answer", "key" => key).first == 200 }
    wait("allowed_command_ran", 30) { mock_file?("shell-ran") }
  end

  # ── what a ping leaves in the input ──
  # Everything through the launcher's real `notify` and the real bin/collector process. board_tmux_shim holds the
  # collector's paste until the model's dangerous command has opened its panel: a dialog between paste and Enter, every run.
  PING_A = "E2E_RACE_A first line\nsecond line\n\nfourth line"
  PING_B = "E2E_RACE_B another ping"
  PING_C = "E2E_DRAFT_PING for the draft"
  PING_D = "E2E_LATE_D renders inside the window"
  PING_E = "E2E_LATE_E renders after the window\nsecond line"
  PING_F = "E2E_LATE_F after the late line"
  DRAFT = "E2E_HALF_TYPED_DRAFT"

  # longer than two notifier passes (5 s each): a late second delivery would have landed by now
  SETTLE_SECONDS = 12
  def settle = sleep(SETTLE_SECONDS)

  def notify(text) = launcher("op" => "notify", "session" => @worker, "socket" => "default", "text" => text)
  def input_now(ping) = Busyyaks::HermesBoard.input_state(tmux("capture-pane", "-e", "-p", "-t", "=#{@worker}:"), ping)
  def copies(word) = turns.sum { |t| Array(t["user"]).count(word) }
  def idle? = Busyyaks::HermesBoard.paste_refusal(screen).nil? && !screen.include?("msg=interrupt")

  # retried as the notifier does, on what it retries
  def delivered(name, text)
    wait(name, 45) do
      r = notify(text)
      raise StepFailed, "#{name}: #{r}" unless r["ok"] || r["retry"]

      r["ok"]
    end
  end

  def paste_turn(line)
    Open3.capture2e("tmux", "load-buffer", "-b", "race", "-", stdin_data: line)
    tmux("paste-buffer", "-p", "-d", "-b", "race", "-t", "=#{@worker}:")
    sleep 0.4 # as the collector: the paste lands before the Enter
    tmux("send-keys", "-t", "=#{@worker}:", "Enter")
  end

  def restart_collector
    pid = Open3.capture2("pgrep", "-f", "^ruby bin/collector").first.split.first.to_i
    step("collector_found", "no bin/collector process") { pid.positive? }
    Process.kill("TERM", pid)
    wait("collector_stopped", 15) { !File.exist?("/proc/#{pid}") }
    snapshot = File.join(@base, "collector/sessions.json")
    before = File.mtime(snapshot)
    env = { "PATH" => "#{@base}/shim:#{ENV.fetch('PATH')}", "BOARD_E2E_MOCK" => @mock }
    Process.detach(Process.spawn(env, "ruby", "bin/collector", chdir: File.join(@base, "app"), pgroup: true,
                                                               %i[out err] => [File.join(@base, "collector.log"), "a"]))
    wait("collector_restarted", 30) { File.mtime(snapshot) > before && File.socket?(File.join(@base, "collector/read.sock")) }
  end

  def left_lines
    wait("left_worker_idle", 45) { idle? }
    paste_turn("E2E_RACE_TURN")
    wait("left_turn_held", 30) { mock_file?("race-holding") }
    File.write(File.join(@mock, "race-arm"), "1")
    first = notify(PING_A)
    step("refused_after_paste_retryable", first.to_s) {
 first["retry"] == true && first["error"].to_s.include?("waits in its input") }
    step("enter_did_not_answer_the_panel") { !mock_file?("race-ran") && screen.include?("Dangerous Command") }
    snap("left-line")
    restart_collector
    wait("retry_after_restart_held_by_the_panel", 30) do
      r = notify(PING_A)
      r["retry"] == true && r["error"].to_s.include?("dialog")
    end
    tmux("send-keys", "-t", "=#{@worker}:", "4")
    wait("panel_denied_line_still_in_input", 45) { idle? && input_now(PING_A)[:state] == :ours }
    step("denied_panel_command_never_ran") { !mock_file?("race-ran") }
    other = notify(PING_B)
    step("different_ping_refused_not_glued", other.to_s) do
      other["retry"] == true && other["error"].to_s.include?("a pasted block that is not this ping")
    end
    step("left_line_untouched_by_it") {
 input_now(PING_A)[:state] == :ours && copies("E2E_RACE_A").zero? && copies("E2E_RACE_B").zero? }
    delivered("left_ping_delivered_after_restart", PING_A)
    wait("left_ping_reached_model", 45) { copies("E2E_RACE_A") == 1 }
    wait("input_empty_after_it", 30) { idle? && input_now(PING_B)[:state] == :empty }
    delivered("different_ping_delivered", PING_B)
    wait("different_ping_reached_model", 45) { copies("E2E_RACE_B") == 1 }
    settle
    step("exactly_one_copy_of_the_left_ping", copies("E2E_RACE_A").to_s) { copies("E2E_RACE_A") == 1 }
    step("exactly_one_copy_of_the_different_ping", copies("E2E_RACE_B").to_s) { copies("E2E_RACE_B") == 1 }
    glued = turns.any? { |t| Array(t["user"]).include?("E2E_RACE_A") && Array(t["user"]).include?("E2E_RACE_B") }
    step("the_two_pings_never_glued") { !glued }
    late_paste
    draft_kept
  end

  # the paste lands late (board_tmux_shim): inside the read-back window it is entered once; past it the ping fails for
  # good, and the line that then appears is never pasted a second time
  def late_paste
    wait("late_worker_idle", 45) { idle? && input_now(PING_D)[:state] == :empty }
    File.write(File.join(@mock, "race-late"), "0.6")
    within = notify(PING_D)
    step("late_paste_within_the_window_sent", within.to_s) { within["ok"] == true }
    wait("late_paste_reached_model", 45) { copies("E2E_LATE_D") == 1 }
    wait("late_past_worker_idle", 45) { idle? && input_now(PING_E)[:state] == :empty }
    File.write(File.join(@mock, "race-late"), "3")
    past = notify(PING_E)
    step("paste_never_seen_fails_for_good", past.to_s) do
      past["unsupported"] == true && past["error"].to_s.include?("still shows nothing") &&
        past["error"].to_s.include?("not pasted again")
    end
    wait("late_line_appears_once", 15) { input_now(PING_E)[:state] == :ours }
    other = notify(PING_F)
    step("late_line_refuses_another_ping", other.to_s) do
      other["retry"] == true && other["error"].to_s.include?("a pasted block that is not this ping")
    end
    step("late_line_not_sent_by_itself") { copies("E2E_LATE_E").zero? && copies("E2E_LATE_F").zero? }
    delivered("late_line_entered_never_repasted", PING_E)
    wait("late_line_reached_model", 45) { copies("E2E_LATE_E") == 1 }
    wait("late_input_free", 30) { idle? && input_now(PING_F)[:state] == :empty }
    delivered("ping_after_the_late_line_delivered", PING_F)
    wait("ping_after_the_late_line_reached_model", 45) { copies("E2E_LATE_F") == 1 }
    settle
    %w[E2E_LATE_D E2E_LATE_E E2E_LATE_F].each do |word|
      step("exactly_one_delivery:#{word}", "#{copies(word)} copies") { copies(word) == 1 }
    end
  end

  def draft_kept
    wait("draft_worker_idle", 45) { idle? && input_now(PING_C)[:state] == :empty }
    tmux("send-keys", "-t", "=#{@worker}:", "-l", DRAFT)
    wait("draft_on_screen", 10) { input_now(PING_C) == { state: :other, why: "typed text (#{DRAFT.length} chars)" } }
    r = notify(PING_C)
    step("draft_refuses_the_ping_retryable", r.to_s) { r["retry"] == true && r["error"].to_s.include?("typed text") }
    step("refusal_does_not_quote_the_draft") { !r["error"].to_s.include?(DRAFT) }
    step("draft_not_overwritten") { Busyyaks::HermesBoard.input(tmux("capture-pane", "-e", "-p", "-t", "=#{@worker}:")) == { state: :text, text: DRAFT } }
    step("draft_not_sent") { copies("E2E_HALF_TYPED_DRAFT").zero? && copies("E2E_DRAFT_PING").zero? }
    tmux("send-keys", "-t", "=#{@worker}:", "C-u")
    wait("draft_cleared_by_the_person", 10) { input_now(PING_C)[:state] == :empty }
    delivered("ping_delivered_once_the_input_is_free", PING_C)
    wait("ping_after_draft_reached_model", 45) { copies("E2E_DRAFT_PING") == 1 }
    settle
    step("exactly_one_delivery:E2E_DRAFT_PING", "#{copies('E2E_DRAFT_PING')} copies") { copies("E2E_DRAFT_PING") == 1 }
    step("draft_never_reached_the_model") { copies("E2E_HALF_TYPED_DRAFT").zero? }
  end

  # ── the token ──
  def secrets
    token = @env.fetch("MCP_TOKEN")
    step("token_is_real") { token.length >= 32 }
    argv = Dir.glob("/proc/[0-9]*/cmdline").filter_map { |f| File.binread(f) rescue nil }
    step("token_not_on_any_argv") { argv.none? { |a| a.include?(token) } }
    %w[launcher.log collector.log mock.log mock/turns.jsonl].each do |name|
      step("token_not_in:#{name}") { !File.binread(File.join(@base, name)).include?(token) }
    end
    files = Dir.glob(File.join(@base, "home/.hermes/**/*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }
    step("token_not_under_hermes_home", "#{files.size} files") { files.any? && files.none? { |f|
 File.binread(f).include?(token) } }
    managed = File.join(@base, "state/skills", @worker, "hermes-managed")
    step("overlay_private") do
      File.stat(managed).mode & 0o777 == 0o700 && File.stat(File.join(managed, "config.yaml")).mode & 0o777 == 0o600
    end
  end
end

def configure(base)
  path = File.join(base, "app/config/busyyaks.yml")
  doc = YAML.safe_load_file(path)
  doc["agents"]["collector"].merge!("snapshot" => File.join(base, "collector/sessions.json"),
                                    "read_socket" => File.join(base, "collector/read.sock"))
  doc["launch"]["scopes"] = nil
  doc["launch"]["start_seconds"] = 90
  doc["launch"]["commands"] << { "kind" => "hermes", "command" => "hermes", "args" => ["chat"], "via_shell" => false }
  File.write(path, YAML.dump(doc))
end

# the throwaway database's agent settings: every type on the hermes launcher, its prompt a marker the mock reads
def settings(base)
  doc = YAML.safe_load_file(File.join(base, "settings.yml"))
  doc["launchers"] = [{ "key" => "hermes", "label" => "hermes", "kind" => "hermes", "command" => "hermes", "args" => ["chat"],
                        "via_shell" => false, }]
  marks = { "lead" => "E2E_LEAD", "worker" => "E2E_WORKER", "team" => "E2E_TEAM" }
  doc["agent_types"].each do |t|
    t["launchers"] = ["hermes"]
    t["model"] = nil
    t["prompt"] = "#{marks[t['key']]} session={session} agent={agent} {cards}" if marks[t["key"]]
  end
  File.write(File.join(base, "settings-hermes.yml"), YAML.dump(doc))
end

def await_file(path)
  300.times do
    return if File.exist?(path)

    sleep 0.2
  end
  abort "FAILED: #{path} did not appear"
end

case ARGV[0]
when "configure" then configure(ARGV.fetch(1))
when "settings" then settings(ARGV.fetch(1))
when "await-file" then await_file(ARGV.fetch(1))
when "run" then BoardE2E.new(ARGV.fetch(1)).run
else abort "usage: board_e2e.rb configure|settings|await-file|run …"
end
