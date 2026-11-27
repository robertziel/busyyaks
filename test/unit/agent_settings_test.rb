# frozen_string_literal: true

require "test_helper"
require "open3"
require "busyyaks/agent_settings_api"

# the launchers + agent types are revisions in the database, edited on Settings → Agents & launchers; every
# launcher's command must be on the host allowlist (config/busyyaks.yml launch.commands).
class AgentSettingsTest < Minitest::Test
  include DBReset

  S = Busyyaks::AgentSettings
  API = Busyyaks::AgentSettingsAPI
  ALLOW = YAML.safe_load_file(File.expand_path("../fixtures/busyyaks.yml", __dir__)).dig("launch", "commands").freeze

  def db = Hanami.app["db.gateway"].connection
  def doc = JSON.parse(JSON.generate(AgentSettingsFixture::DOC))
  def base = S.current_id(db)
  def save(d, base: self.base, commands: ALLOW) = API.save({ "base" => base, "doc" => d }, by: "op", db: db, commands: commands)

  def test_the_config_file_may_not_carry_the_agent_keys
    raw = YAML.safe_load_file(Busyyaks::Kanban::CONFIG_PATH)
    assert_empty raw.keys & S::KEYS, "launchers / agent_types are database revisions"
    Dir.mktmpdir do |d|
      f = File.join(d, "k.yml")
      File.write(f, YAML.dump(raw.merge("launchers" => [])))
      e = assert_raises(S::Error) { S.file_hash(f) }
      assert_match(/launchers moved to the database/, e.message)
    end
  end

  # the audit: "show the real argv a launch adds" — the commands table is the argv bin/launcher runs, with the skills
  # stage, the board MCP and the prompt behind /busyyaks:session busyyaks adds, never the bare launcher command
  def test_show_answers_the_current_revision_the_allowlist_and_the_real_argv_a_launch_runs
    status, body = API.show(db: db, commands: ALLOW)
    assert_equal 200, status
    assert_equal %w[fullclaude localclaude], body[:doc]["launchers"].map { |l| l["key"] }
    assert_equal ALLOW, body[:commands]
    assert_nil body[:error]
    stage = "$LAUNCHER_STATE_DIR/skills/SESSION"
    lead = body[:preview].find { |p| p[:type] == "lead" && p[:launcher] == "fullclaude" }
    assert_equal %w[claude --permission-mode bypassPermissions], lead[:argv].first(3)
    assert_equal %w[--remote-control SESSION], lead[:argv].last(2), "--remote-control stays LAST"
    pairs = lead[:argv].each_cons(2).to_a
    assert_includes pairs, ["--plugin-dir", stage]
    assert_includes pairs, ["--mcp-config", Busyyaks::BoardMcp.claude_path(stage)]
    assert_includes lead[:argv], "/busyyaks:session <the type's prompt>"
    plain = body[:preview].find { |p| p[:type] == "plain" && p[:launcher] == "fullclaude" }
    assert_includes plain[:argv], "/busyyaks:session", "a type with no prompt still starts on the entry skill"
    local = body[:preview].find { |p| p[:type] == "worker" && p[:launcher] == "localclaude" }
    assert_equal ["bash", "-ic"], local[:argv].first(2)
    assert_match(/\Alocalclaude --mcp-config .* --plugin-dir .* --remote-control SESSION\z/, local[:argv].last)
  end

  def test_a_save_writes_a_new_revision_that_the_engine_config_runs_at_once
    before = Busyyaks::Kanban.config.agent_type("lead").label
    d = doc
    d["agent_types"].find { |t| t["key"] == "lead" }["label"] = "Lead it"
    status, body = save(d)
    assert_equal 200, status, body.inspect
    assert_equal "op", body[:revision][:author]
    assert_equal 2, body[:history].size, "the earlier revision stays as history"
    refute_equal before, "Lead it"
    assert_equal "Lead it", Busyyaks::Kanban.config.agent_type("lead").label, "rebuilt from the newest revision"
    assert_equal body[:revision][:id], Busyyaks::Kanban.config_revision[:id]
  end

  # a launch is planned and registered on the api's config: its start carries THAT revision, even when a newer one was
  # saved in between (the launcher never runs a revision the registration was not made for)
  def test_a_launch_starts_with_the_revision_its_api_was_built_on
    planned = Busyyaks::Kanban.config_revision
    api = Busyyaks::Kanban.api
    d = doc
    d["agent_types"].find { |t| t["key"] == "lead" }["label"] = "Lead it"
    assert_equal 200, save(d).first
    sent = []
    client = Busyyaks::LauncherClient.singleton_class
    client.alias_method(:call_unstubbed, :call)
    client.define_method(:call) { |req| sent << req and { "ok" => true } }
    begin
      api.instance_variable_get(:@launcher).start(session: "s", project: { path: "/p" }, type: "lead", launcher: "fullclaude",
                                                  argv: [], prompt_template: nil, vars: {}, lead_key: nil, lead: nil)
    ensure
      client.alias_method(:call, :call_unstubbed)
      client.remove_method(:call_unstubbed)
    end
    assert_equal planned, sent.first[:settings]
    refute_equal planned[:id], Busyyaks::Kanban.config_revision[:id], "a newer revision is current"
    assert_raises(ArgumentError) { Busyyaks::Kanban.revision_of(Object.new) }
  end

  def test_a_save_on_a_stale_base_is_a_conflict_and_writes_nothing
    old = base
    assert_equal 200, save(doc).first
    status, body = save(doc, base: old)
    assert_equal 409, status
    assert_match(/revision #{old} is not the newest/, body[:error])
    assert_equal 2, db[:agent_settings].count
  end

  # review round 1 (blocker): a revision with a worker / sub team under no lead is refused when saved, and a stored one
  # (written before the check, or by hand) when loaded — every caller of Kanban.config, the MCP tools included
  def test_a_revision_with_a_type_under_no_lead_is_refused_on_save_and_on_load
    d = doc
    w = d["agent_types"].find { |t| t["key"] == "worker" }
    %w[under launchable].each { w.delete(_1) }
    n = db[:agent_settings].count
    status, body = save(d)
    assert_equal 422, status
    assert_match(/agent_types\[worker\] runs without a lead: give it `under: <lead type>`/, body[:error])
    assert_equal n, db[:agent_settings].count, "nothing written"
    db[:agent_settings].insert(doc: JSON.generate(d), author: "by hand", created_at: 1)
    e = assert_raises(Busyyaks::Kanban::Unrunnable) { Busyyaks::Kanban.config }
    assert_match(/agent settings revision \d+ does not run: agent_types\[worker\] runs without a lead/, e.message)
    assert_raises(Busyyaks::Kanban::Unrunnable) { Busyyaks::Kanban.tools }
  ensure
    AgentSettingsFixture.install!(db)
  end

  def test_a_command_off_the_allowlist_or_a_value_the_engine_refuses_is_422_and_writes_nothing
    d = doc
    d["launchers"][0]["command"] = "bash"
    status, body = save(d)
    assert_equal 422, status
    assert_includes body[:error], "launcher fullclaude (claude_code: bash --permission-mode bypassPermissions): not an " \
                                  "invocation on this host's allowlist"
    # the command allowlisted, an argument the host did not list: refused the same way (a --settings
    # with hooks, an --mcp-config, a permission mode would otherwise reach the host through an allowed command)
    d = doc
    d["launchers"][0]["args"] += ["--settings", "{}"]
    status, body = save(d)
    assert_equal 422, status
    assert_includes body[:error], "launcher fullclaude (claude_code: claude --permission-mode bypassPermissions " \
                                  "--settings {}): not an invocation"
    d = doc
    d["launchers"][1]["via_shell"] = false
    assert_equal 422, save(d).first, "via_shell is part of the invocation"
    d = doc
    d["agent_types"][0]["launchers"] = ["nope"]
    status, body = save(d)
    assert_equal 422, status
    assert_match(/agent_types\[lead\].launchers must be a non-empty list of launcher keys/, body[:error])
    # a prompt is one argv word: one starting with "-" would be an option of the allowlisted command
    d = doc
    d["agent_types"][0]["prompt"] = "--settings={\"hooks\":{}} {slug}"
    status, body = save(d)
    assert_equal 422, status
    assert_match(/agent_types\[lead\].prompt must not start with "-"/, body[:error])
    assert_equal 422, save(doc.merge("extra" => 1)).first
    assert_equal 422, API.save({ "doc" => doc }, by: "op", db: db, commands: ALLOW).first, "base is required"
    assert_equal 1, db[:agent_settings].count
  end

  # the host allowlist shrank after a revision was saved: the page says why it does not run, nothing is repaired
  def test_show_reports_a_current_revision_the_allowlist_no_longer_runs
    _, body = API.show(db: db, commands: ALLOW.first(1))
    assert_match(/launcher localclaude \(claude_code: localclaude \(via shell\)\): not an invocation on this host's allowlist/,
                 body[:error])
    assert_empty body[:preview]
  end

  def test_the_migration_seeds_the_repo_template
    assert_equal %w[claude], S.template["launchers"].map { |l| l["command"] }
    assert_equal %w[lead worker team], S.template["agent_types"].map { |t| t["key"] }
  end

  # the worker's PR subagents (QA + Reviewer) run on haiku, never on the worker's own model — said once, in the
  # worker's part of the skills busyyaks hands every worker session (skills/busyyaks/agents/worker.md)
  def test_the_worker_prompt_runs_its_qa_and_reviewer_subagents_on_haiku
    author = File.read(File.expand_path("../../skills/busyyaks/agents/worker.md", __dir__))
    # the worker names each subagent's skill; each brief, its own file, says the subagent runs on haiku
    %w[qa reviewer critic].each do |s|
      assert_match(/dispatch the on-demand `#{s}` skill's/, author, s)
      brief = File.read(File.expand_path("../../skills/busyyaks/#{s}/SKILL.md", __dir__))
      assert_match(/Dispatch a fresh subagent with `model: "haiku"`/, brief, s)
    end
  end

  # ONE reviewer per card, spawned once and continued with SendMessage every round: said in the worker's rules AND
  # in the reviewer brief it hands over
  def test_one_reviewer_per_card_continued_with_send_message
    root = File.expand_path("../..", __dir__)
    author = File.read(File.join(root, "skills/busyyaks/agents/worker.md"))
    assert_match(/spawn ONE reviewer per card, once/, author)
    assert_match(/CONTINUES that same\s+reviewer with `SendMessage`/, author)
    assert_match(/never a\s+second\s+`Agent`\s+call/, author)
    assert_match(/post on the card `reviewer spawned: reviewer-<card id> by <your tmux session>, round <n>`/, author)
    brief = File.read(File.join(root, "skills/busyyaks/reviewer/SKILL.md"))
    assert_match(/^dispatch: the worker, once per card on every board — one subagent, continued with `SendMessage`/,
                 brief)
    assert_match(/ONCE per card \(`name: "reviewer-<card id>"`\)/, brief)
    assert_match(/Each later round = `SendMessage` to that\s+reviewer: .* never a new reviewer/m, brief)
    assert_match(/You stay this card's reviewer for every round/, brief)
  end

  # each PR subagent loads its own skill: the worker's spawn prompt starts with the load line and never carries the
  # brief; each brief says it was loaded by the subagent itself and to stop when it reached it any other way
  def test_each_pr_subagent_loads_its_own_brief
    root = File.expand_path("../..", __dir__)
    author = File.read(File.join(root, "skills/busyyaks/agents/worker.md"))
    assert_match(/spawn prompt's FIRST line is `Load the <name> skill with your skill\s+tool and follow the brief/, author)
    assert_match(/follow the brief quoted in it\.` \(<name> = that skill's name in the "Load when needed" list\)/, author)
    assert_match(/Never paste,\s+paraphrase or shorten a brief into the prompt/, author)
    assert_match(/with several such lines the LATEST one decides/, author)
    assert_match(/A subagent that cannot load its skill \(no skill tool, the name not\s+found\) reports that and stops/,
                 author)
    assert_match(/never a pasted brief instead/, author)
    %w[qa reviewer critic].each do |s|
      brief = File.read(File.join(root, "skills/busyyaks/#{s}/SKILL.md"))
      # the load line names the skill by its frontmatter name: each of the three is a skill under that name
      assert_equal s, YAML.safe_load(brief[/\A---\n(.*?)\n---\n/m, 1])["name"], s
      assert_match(/Its prompt = the load\s+line of your rules \(it reads this file\s+itself\)/, brief, s)
      assert_match(/never this\s+brief/, brief, s)
      assert_match(/If you are the subagent that loaded this file: skip to the quoted brief/, brief, s)
      assert_match(/^> You loaded this brief yourself with your skill tool\. If it reached you any other way/, brief, s)
    end
  end

  # the operator: "remove ones we don't use like plain!" — no agent type nobody uses: every type the shipped template
  # defines is started by something (the Launch bar, or its lead's kanban_spawn as the lead's rules say) and has its
  # rules file; no rules file, face colour or launcher is left for a type or command no type runs
  def test_no_agent_type_nobody_uses
    root = File.expand_path("../..", __dir__)
    types = S.template["agent_types"]
    keys = types.map { _1["key"] }
    lead = File.read(File.join(root, "skills/busyyaks/agents/lead.md"))
    types.each do |t|
      started = t.fetch("launchable", true) || lead.include?("kanban_spawn(id, \"#{t['key']}\"")
      assert started, "#{t['key']}: nothing starts it"
      assert File.exist?(File.join(root, "skills/busyyaks/agents/#{t['key']}.md")), "#{t['key']}: no rules"
    end
    # a preset type ships its brief before any deployment adds it; every preset has one
    presets = Busyyaks::AgentPresets.keys
    assert_empty Dir[File.join(root, "skills/busyyaks/agents/*.md")].map { File.basename(_1, ".md") } - keys - presets
    presets.each { |k| assert File.exist?(File.join(root, "skills/busyyaks/agents/#{k}.md")), "preset #{k}: no rules" }
    assert_empty S.template["launchers"].map { _1["key"] } - types.flat_map { _1["launchers"] }, "a launcher no type runs"
    example = YAML.safe_load_file(File.join(root, "config/kanban.example.yml"))
    faces = example["theme"].keys.grep(/\A--ak-face-type-/).map { _1.delete_prefix("--ak-face-type-") }
    assert_empty faces - keys - example["face_roles"].keys, "a face colour for a type nobody is"
    refute_includes keys, "plain"
  end

  # "the critic and the QA brief are editable files like the reviewer": each subagent a session dispatches is its
  # own on-demand skill of busyyaks's layer, with the one line that says who dispatches it and when
  # the presets (config/agent_presets.yml) are offered by the page and save as they are once the lead's
  # launchers are filled in; `opt_in: true` is busyyaks's key — checked, taken out before the engine reads the revision
  def test_a_preset_adds_an_opt_in_type_and_opt_in_needs_a_spawn_only_type_under_a_lead
    status, body = API.show(db: db, commands: ALLOW)
    assert_equal 200, status
    assert_equal %w[copywriter researcher], body[:presets].map { _1["key"] }
    assert(body[:presets].all? { _1["opt_in"] == true && _1["launchable"] == false && _1["under"] == "lead" })
    d = doc
    lead = d["agent_types"].find { |t| t["key"] == "lead" }
    body[:presets].each { |p| d["agent_types"] << Busyyaks::AgentPresets.type(p, launchers: lead["launchers"]) }
    status, out = save(d)
    assert_equal 200, status, out.inspect
    assert_equal %w[copywriter researcher], S.opt_in(out[:doc])
    cfg = Busyyaks::Kanban.config
    assert_equal "lead", cfg.agent_type("copywriter").under
    refute cfg.agent_type("copywriter").respond_to?(:opt_in), "the engine never sees opt_in"
    bad = ->(over) { d.merge("agent_types" => d["agent_types"].map { |t| t["key"] == "copywriter" ? t.merge(over) : t }) }
    status, out = save(bad.({ "launchable" => true }), base: base)
    assert_equal 422, status
    assert_match(/agent type copywriter: opt_in: true needs `under: <lead type>` and `launchable: false`/, out[:error])
    status, out = save(bad.({ "opt_in" => "yes" }), base: base)
    assert_equal [422, "agent type copywriter: opt_in must be true or false"], [status, out[:error]]
  end

  # `color` is busyyaks's key — one name of the palette (skin tokens), checked and
  # taken out before the engine reads the revision, and put into the theme as the type's face token over the file's
  def test_a_type_color_is_a_palette_name_that_becomes_its_face_token
    status, body = API.show(db: db, commands: ALLOW)
    assert_equal 200, status
    assert_equal S::COLORS, body[:colors]
    assert_equal "var(--vivid-blue)", body[:face_theme]["lead"], "the file's theme colour of a type with none of its own"
    d = doc
    over = ->(c) { d.merge("agent_types" => d["agent_types"].map { |t| t["key"] == "worker" ? t.merge("color" => c) : t }) }
    status, out = save(over.("pink"))
    assert_equal 200, status, out.inspect
    assert_equal "pink", out[:doc]["agent_types"].find { _1["key"] == "worker" }["color"]
    cfg = Busyyaks::Kanban.config
    assert_equal "var(--vivid-pink)", cfg.theme["--ak-face-type-worker"], "over the file's gold"
    assert_equal "var(--vivid-blue)", cfg.theme["--ak-face-type-lead"], "a type with no colour keeps the file's"
    refute cfg.agent_type("worker").respond_to?(:color), "the engine never sees color"
    status, out = save(over.("#ff0000"), base: base)
    assert_equal 422, status
    assert_equal "agent type worker: color must be one of #{S::COLORS.keys.join(', ')} (got \"#ff0000\")", out[:error]
  end

  def test_a_color_needs_no_theme_entry_and_a_file_with_no_theme_is_left_to_the_engine
    types = [{ "key" => "x", "color" => "teal" }, { "key" => "y" }, "not a hash"]
    assert_equal({ "--ak-face-type-x" => "var(--vivid-teal)" }, S.face_tokens(types))
    file = { "theme" => { "--ak-ink" => "var(--ink)" } }
    assert_equal({ "--ak-ink" => "var(--ink)", "--ak-face-type-x" => "var(--vivid-teal)" }, S.themed(file, types)["theme"])
    assert_same file, S.themed(file, [{ "key" => "y" }]), "no colour: the file as is"
    bad = { "theme" => "nope" }
    assert_same bad, S.themed(bad, types), "a theme that is no mapping: the engine's refusal"
  end

  def test_the_critic_and_the_qa_brief_are_editable_files_like_the_reviewer
    root = File.expand_path("../..", __dir__)
    layer = Busyyaks::Skills.busyyaks!(root, types: S.template["agent_types"].map { _1["key"] },
                                             settings: Busyyaks::Skills.settings!(SKILLS_SETTINGS)).first
    briefs = layer.skills.to_h { [_1.name, _1] }
    assert_equal %w[critic design qa reviewer security], briefs.keys.sort
    briefs.each_value { |b| assert_match(/\A(the worker|the worker, )/, b.dispatch, b.name) }
    assert_match(/input-isolated|ONLY the card's requirement/, briefs["critic"].body)
    assert_match(/BLOCKER.*MAJOR.*MINOR/m, briefs["critic"].body)
    assert_match(/break the code it names .* a test that still passes proves nothing/m, briefs["critic"].body)
    assert_match(/start, stop or kill a session, container or (?:process|PID) you did not start/i,
                 briefs["critic"].body)
    worker = File.read(File.join(root, "skills/busyyaks/agents/worker.md"))
    refute_match(/attaches screenshots|PASS \/ FAIL on the card/, worker, "the QA brief lives in qa/SKILL.md only")
  end

  # A template prompt says who the session is; the workflow is the skills', never repeated here
  def test_the_template_prompts_carry_no_workflow_text
    S.template["agent_types"].each do |t|
      p = t["prompt"].to_s
      ["kanban_ask", "kanban_handoff", "kanban_block", "severity", "skill", "reviewer agent", "conflict"].each do |w|
        refute_includes p.downcase, w, "#{t['key']}: #{w}"
      end
    end
  end

  # the move off config/kanban.yml: an old file's launchers + agent_types become a revision, the rest is ignored
  def test_bin_agent_settings_imports_an_old_kanban_yml_and_shows_the_current_revision
    root = File.expand_path("../..", __dir__)
    d = doc
    d["launchers"][1]["label"] = "local (imported)"
    old = YAML.safe_load_file(Busyyaks::Kanban::CONFIG_PATH).merge(d)
    out, err, st = Open3.capture3(File.join(root, "bin/agent-settings"), "import", stdin_data: YAML.dump(old), chdir: root)
    assert st.success?, err
    assert_match(/\Arevision \d+: fullclaude, localclaude · lead, worker, team, plain\n\z/, out)
    assert_equal "bin/agent-settings import", S.current(db)[:author]
    out, err, st = Open3.capture3(File.join(root, "bin/agent-settings"), "show", chdir: root)
    assert st.success?, err
    assert_equal "local (imported)", YAML.safe_load(out)["launchers"][1]["label"]
    bad = old.merge("launchers" => old["launchers"].map { |l| l.merge("command" => "sh") })
    _, err, st = Open3.capture3(File.join(root, "bin/agent-settings"), "import", stdin_data: YAML.dump(bad), chdir: root)
    refute st.success?
    assert_includes err, "launcher localclaude (claude_code: sh (via shell)): not an invocation"
    assert_match(/422: launcher fullclaude \(claude_code: sh /, err)
  end

  # a revision written before lead-first boards, in today's shape — what migration 20261207463000 writes
  def test_lead_first_converts_a_pre_463_revision_and_leaves_a_new_one_alone
    old = { "launchers" => [], "agent_types" => [
      { "key" => "lead", "takes" => ["gate"], "spawn_launcher" => "fullclaude" },
      { "key" => "worker", "takes" => [], "launcher_follows" => "lead", "spawn_launcher" => "fullclaude",
        "spawns_for" => %w[queued working review gate], },
      { "key" => "team", "takes" => [], "launcher_follows" => "lead", "spawn_launcher" => "fullclaude" },
      { "key" => "plain", "takes" => [], "spawn_launcher" => "fullclaude" },
    ], }
    out = Busyyaks::AgentSettings.lead_first(old)["agent_types"]
    assert_equal [%w[gate queued working review], [], [], []], out.map { |t| t["takes"] }
    assert_equal [nil, "lead", "lead", nil], out.map { |t| t["under"] }
    assert_equal [nil, nil, nil, true], out.map { |t| t["standalone"] }, "plain runs without a lead: standalone"
    assert(out.none? { |t| t.keys.intersect?(Busyyaks::AgentSettings::PRE_LEAD_FIRST) })
    assert_nil Busyyaks::AgentSettings.lead_first({ "launchers" => [], "agent_types" => out }), "already lead-first"
    assert_nil Busyyaks::AgentSettings.lead_first(AgentSettingsFixture::DOC), "the suite's revision is lead-first"
    leaderless = { "launchers" => [], "agent_types" => [{ "key" => "w", "takes" => [], "spawns_for" => ["queued"] }] }
    e = assert_raises(Busyyaks::AgentSettings::Error) { Busyyaks::AgentSettings.lead_first(leaderless) }
    assert_match(/cannot convert to lead-first boards — 0 followed types/, e.message)
    two = { "launchers" => [], "agent_types" => [{ "key" => "a", "takes" => [], "launcher_follows" => "x" },
                                                 { "key" => "b", "takes" => [], "launcher_follows" => "y" },], }
    assert_raises(Busyyaks::AgentSettings::Error) { Busyyaks::AgentSettings.lead_first(two) }
    only_spawn_launcher = { "launchers" => [], "agent_types" => [{ "key" => "p", "takes" => [], "spawn_launcher" => "c" }] }
    assert_equal [{ "key" => "p", "takes" => [], "standalone" => true }],
                 Busyyaks::AgentSettings.lead_first(only_spawn_launcher)["agent_types"]
    reviewer = { "key" => "r", "takes" => [], "prompt" => "review", "spawn_launcher" => "c" }
    told = { "launchers" => [], "agent_types" => [reviewer] }
    e = assert_raises(Busyyaks::AgentSettings::Error) { Busyyaks::AgentSettings.lead_first(told) }
    assert_match(/agent type r would run under no lead/, e.message)
  end

  # the live deployment's revision (stored before lead-first boards) converts to one the engine accepts with the suite's file
  def test_the_converted_revision_loads_on_the_engine
    raw = YAML.safe_load_file(File.expand_path("../fixtures/agents.yml", __dir__))
    old = raw.merge("agent_types" => raw["agent_types"].map do |t|
      case t["key"]
      when "lead" then t.merge("takes" => ["gate"])
      when "worker" then t.except("under").merge("launcher_follows" => "lead", "spawn_launcher" => "fullclaude",
                                                 "spawns_for" => %w[queued working review gate])
      when "team" then t.except("under").merge("launcher_follows" => "lead")
      else t
      end
    end)
    doc = Busyyaks::AgentSettings.lead_first(old)
    cfg = Busyyaks::AgentSettings.host(Busyyaks::AgentSettings.file_hash(ENV.fetch("KANBAN_CONFIG")), doc)
    assert_equal %w[gate queued working review], cfg.agent_type("lead").takes
    assert_equal %w[lead lead], [cfg.agent_type("worker").under, cfg.agent_type("team").under]
  end
end
