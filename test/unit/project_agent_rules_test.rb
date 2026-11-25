# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "yaml"
require "rack/mock"
require "open3"
require "busyyaks/project_agent_rules_api"
require "busyyaks/mcp_server"
require_relative "../support/writer_server"
require_relative "../support/auto_loaded"

# A project's rules per agent type (the project page's Settings tab) ARE the repo's own skills layer:
# <repo>/.busyyaks/skills/agents/<type>.md. Read by the web (repos mounted read-only), written only by the writer
# service, handed to a session only by bin/launcher's staged busyyaks skill. Each case drives the API the way the web
# does (a writer on this worker's WRITER_SOCKET) and stages a launch the way bin/launcher does.
class ProjectAgentRulesTest < Minitest::Test
  include DBReset

  API = Busyyaks::ProjectAgentRulesAPI
  F = Busyyaks::AgentRuleFiles
  S = Busyyaks::Skills
  ROOT = File.expand_path("../..", __dir__)
  SKILLS = S.settings!(SKILLS_SETTINGS)
  TYPES = %w[lead worker team plain].freeze
  # what a project's agents/<type>.md may hold so a launch of the type still starts (busyyaks's own share taken off)
  BUDGET = S.project_budget(checkout: ROOT, types: TYPES, settings: SKILLS).freeze
  def db = Hanami.app["db.gateway"].connection

  def setup
    super
    @root = File.realpath(Dir.mktmpdir("rules"))
    %w[app other].each do |slug|
      FileUtils.mkdir_p(repo(slug))
      WriterServer.git_init(repo(slug))
      store.upsert_project(slug: slug, path: repo(slug), remote: nil, branch: "main", own: true, last_commit_at: 1,
                           commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    end
    @skills = SKILLS
    @sock = WriterServer.start(root: @root, skills: -> { @skills })
    @launcher = answer("loaded")
  end

  REPLACE_BUDGET = S.replace_budget(S.busyyaks!(ROOT, types: TYPES, settings: SKILLS), TYPES, SKILLS).freeze

  # bin/launcher's project_skills answer
  def answer(status, checkout: false, layers: { "lead" => { "start" => [], "on_demand" => [] } })
    { "ok" => true, "project_skills" => status, "budget" => BUDGET, "replace_budget" => REPLACE_BUDGET,
      "layers" => layers, "checkout" => checkout, }
  end

  def teardown
    WriterServer.stop(@sock)
    FileUtils.rm_rf(@root)
    super
  end

  def repo(slug) = File.join(@root, slug)
  def file(slug, type) = File.join(repo(slug), ".busyyaks/skills/agents/#{type}.md")
  # a path of the layer: an agent type key stands for its agents/<type>.md
  def path(key) = key.include?("/") ? key : "agents/#{key}.md"
  def tree(slug)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: repo(slug)).reject { _1.start_with?(".git/") || %w[. .git].include?(_1) }.sort
  end
  def error(body) = body["error"] || body[:error] # the writer's answer comes over its socket (JSON), the API's is Ruby

  def with_launcher(&) = Busyyaks::LauncherClient.stub(:project_skills, ->(**) { @launcher }, &)
  def show(slug = "app") = with_launcher { API.show(slug, db: db, skills: @skills, root: @root) }

  # the editor's Save: every file in `texts` (an agent type key = its agents/<type>.md) against the sha the page last
  # read (nil = no file)
  def save(texts, slug: "app", bases: nil)
    read = show(slug).last[:files]
    files = texts.to_h do |k, body|
      [path(k), { "base" => bases ? bases[k] || bases[path(k)] : read.dig(path(k), :sha), "body" => body }]
    end
    with_launcher { API.save(slug, { "files" => files }, by: "op", db: db, skills: @skills, root: @root) }
  end

  # One launch of `type` in project `slug`, as bin/launcher does it (Skills.plan! + stage! with the kind's delivery)
  # → [the staged entry skill `session`'s text, the receipt [name, source], project_skills]
  def launched(slug, type, delivery, trust_refusal: nil, settings: SKILLS)
    types = Busyyaks::Kanban.config(db).agent_type_keys
    sel, status = S.plan!(checkout: ROOT, repo: repo(slug), type: type, types: types, settings: settings,
                          trust_refusal: trust_refusal)
    stage = File.join(@root, "stages", "#{slug}_#{type}_#{delivery.class.name.split('::').last}")
    receipt = S.stage!(sel, stage, delivery)
    [File.read(File.join(delivery.skill_dir(stage, S::ENTRY), "SKILL.md")), receipt.map { [_1[:name], _1[:source]] }, status]
  end

  def claude = S.delivery("claude_code")
  def hermes = S.delivery("hermes")

  # --- the operator's words -----------------------------------------------------------------------------------------

  # "everything busyyaks is within our committed project, or if it's custom, within the project's .busyyaks directory"
  def test_the_projects_agent_markdown_lives_in_its_dot_busyyaks_directory_not_in_the_database
    status, body = save({ "lead" => "APP-LEAD: plan first.\n" })
    assert_equal 200, status, body.inspect
    assert_equal "APP-LEAD: plan first.\n", File.read(file("app", "lead"))
    assert_equal %w[.busyyaks .busyyaks/skills .busyyaks/skills/agents .busyyaks/skills/agents/lead.md], tree("app")
    assert_equal({ body: "APP-LEAD: plan first.\n", sha: F.sha("APP-LEAD: plan first.\n"), eol: "lf", kind: "agent",
                   type: "lead", mode: "add", }, body[:files]["agents/lead.md"])
    assert_equal ".busyyaks/skills", body[:dir]
    refute db.table_exists?(:project_agent_rules), "no table, no revisions: the file is the rule"
    # a hand edit in the repo is what the page shows next: there is no second copy to drift
    File.write(file("app", "lead"), "APP-LEAD: edited by hand.\n")
    assert_equal "APP-LEAD: edited by hand.\n", show.last[:files]["agents/lead.md"][:body]
  end

  def test_a_session_busyyaks_launches_as_a_type_gets_that_types_rules_for_this_project_and_no_other_projects
    assert_equal 200, save({ "lead" => "APP-LEAD: plan first.\n", "worker" => "APP-WORKER: run e2e.\n" }).first
    assert_equal 200, save({ "lead" => "OTHER-LEAD: never deploy.\n", "worker" => "OTHER-WORKER: ask.\n" }, slug: "other").first
    { "lead" => "APP-LEAD: plan first.", "worker" => "APP-WORKER: run e2e." }.each do |type, rule|
      entry, receipt, status = launched("app", type, claude)
      assert_equal "loaded", status
      assert_includes entry, "## Agent type #{type} (project)\n\n#{rule}"
      assert_includes receipt, ["agents/#{type}", "project"]
      assert_equal [rule[/\A[A-Z-]+/]], entry.scan(/(?:APP|OTHER)-(?:LEAD|WORKER)/), "its type's, its project's, no other"
    end
  end

  # U6, the live run: a team.md rule saved from the web (Project → Settings) is in the Sub team's staged skill only —
  # not the lead's, the worker's or a plain session's, not another project's team, for every harness busyyaks launches
  def test_a_rule_saved_for_one_agent_type_reaches_only_that_types_sessions_of_this_project
    assert_equal 200, save({ "team" => "APP-TEAM: screenshots on the card.\n" }).first
    [claude, hermes].each do |delivery|
      entry, receipt, = launched("app", "team", delivery)
      assert_includes entry, "## Agent type team (project)\n\nAPP-TEAM: screenshots on the card."
      assert_includes receipt, ["agents/team", "project"]
      (TYPES - ["team"]).each do |type|
        entry, receipt, = launched("app", type, delivery)
        refute_includes entry, "APP-TEAM", "#{type} via #{delivery.class}"
        refute(receipt.any? { _1.last == "project" }, "#{type}: no project part")
      end
      entry, receipt, = launched("other", "team", delivery)
      refute_includes entry, "APP-TEAM", "another project's team"
      refute(receipt.any? { _1.last == "project" })
    end
  end

  def test_an_agent_type_with_no_rules_in_the_project_gets_none
    save({ "lead" => "APP-LEAD: plan first.\n" })
    entry, receipt, = launched("app", "team", claude)
    refute_includes entry, "APP-LEAD"
    refute_includes receipt, ["agents/team", "project"]
  end

  def test_rules_saved_on_another_project_never_reach_this_one
    all = { "lead" => "OTHER-LEAD\n", "worker" => "OTHER-WORKER\n", "team" => "OTHER-TEAM\n", "plain" => "OTHER-PLAIN\n" }
    assert_equal 200, save(all, slug: "other").first
    assert_empty tree("app"), "nothing of it in this project's directory"
    %w[lead worker team plain].each do |type|
      [claude, hermes].each do |delivery|
        entry, receipt, status = launched("app", type, delivery)
        refute_match(/OTHER-/, entry, "#{type} via #{delivery.class}")
        assert_equal "none", status
        refute(receipt.any? { _1.last == "project" })
      end
    end
  end

  def test_a_hermes_launch_gets_the_same_rules
    save({ "worker" => "APP-WORKER: run e2e.\n" })
    for_claude, = launched("app", "worker", claude)
    for_hermes, receipt, = launched("app", "worker", hermes)
    part = /^## Agent type worker \(project\)\n\nAPP-WORKER: run e2e\.$/
    assert_match part, for_hermes
    assert_equal for_claude[part], for_hermes[part]
    assert_includes receipt, ["agents/worker", "project"]
  end

  # Codex has no engine launch kind yet (config/harnesses.yml kind: null): no delivery, so no launch at all — it can
  # never start WITHOUT the rules. The rules are a part of the selection: a kind's Delivery class is all it needs.
  def test_a_harness_with_no_delivery_is_refused_never_launched_without_the_rules
    e = assert_raises(S::Invalid) { S.delivery("codex") }
    assert_match(/launcher kind codex: busyyaks has no way to hand it skills/, e.message)
    assert_nil YAML.safe_load_file(File.join(ROOT, "config/harnesses.yml")).dig("codex", "kind")
  end

  # "bound to the project, but that does NOT mean any session in the directory reads them": the page writes only
  # .busyyaks/skills/agents/<type>.md — no file a CLI loads by itself (Claude Code, Hermes, Codex read none of
  # .busyyaks/), and none appears anywhere else in the repo — and the busyyaks MCP, which a terminal session may
  # have, says nothing of them
  def test_a_session_started_from_the_terminal_in_the_projects_directory_gets_none_of_the_projects_agent_rules
    assert_equal 200, save({ "lead" => "APP-LEAD: plan first.\n", "worker" => "APP-WORKER: run e2e.\n" }).first
    written = tree("app").select { File.file?(File.join(repo("app"), _1)) }
    assert_equal %w[.busyyaks/skills/agents/lead.md .busyyaks/skills/agents/worker.md], written
    assert_empty(AUTO_LOADED.select { File.exist?(File.join(repo("app"), _1)) }, "no file a CLI reads on its own")
    auto = AUTO_LOADED + %w[SKILL.md settings.json plugin.json]
    assert_empty(tree("app").select { |f| f.split("/").intersect?(auto) })

    mcp = Rack::MockRequest.new(Busyyaks::McpServer.new(token: "t" * 40, report_token: "r" * 40, board_token: "b" * 40,
                                                        scan_interval: -> { 60 }, store: store, config: nil,
                                                        sessions: -> { [] }))
    # a terminal session's MCP is the user-scope one (MCP_TOKEN); a launched session's is the board's (MCP_BOARD_TOKEN):
    # neither answers with the files — they reach a session only as its staged skill
    %w[t b].each do |token|
      rpc = lambda do |method, params = {}|
        mcp.post("/mcp", "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{token * 40}",
                         input: JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params)).body
      end
      said = [rpc.("initialize", { protocolVersion: "2025-06-18" }), rpc.("tools/list"),
              *[["project", { slug: "app" }], ["list_projects", {}], ["whats_new", {}], ["list_notes", { project: "app" }],
                ["kanban_board", { project: "app" }], ["kanban_workflow", { project: "app" }],]
                .map { |name, args| rpc.("tools/call", { name: name, arguments: args }) },]
      assert_includes said[2], repo("app"), "the project tool answered"
      said.each { refute_match(/APP-LEAD|APP-WORKER|agent.rules|skills\/agents/, _1) }
    end
  end

  # "keep the existing trust gate": a repo busyyaks does not trust, or skills.project deny → the files stay where
  # they are and no launch reads them; the page says so, with the launcher's own reason
  def test_a_project_whose_layer_is_left_out_of_launches_gets_none_of_it_and_the_page_says_why
    save({ "lead" => "APP-LEAD: plan first.\n" })
    why = "#{repo('app')} is not in config/busyyaks.yml launch.trusted_paths and was not made by the launcher's git init"
    entry, receipt, status = launched("app", "lead", claude, trust_refusal: why)
    assert_equal "left: #{why}", status
    refute_includes entry, "APP-LEAD"
    refute(receipt.any? { _1.last == "project" })
    deny = S.settings!(SKILLS_SETTINGS.merge("project" => "deny"))
    entry, _, status = launched("app", "lead", claude, settings: deny)
    assert_equal "left: config/busyyaks.yml skills.project is deny", status
    refute_includes entry, "APP-LEAD"

    @launcher = answer("left: #{why}")
    layers = { "lead" => { "start" => [], "on_demand" => [] } }
    assert_equal({ state: "left", reason: why, budget: BUDGET, replace_budget: REPLACE_BUDGET, layers: layers,
                   checkout: false, }, show.last[:launches])
    @launcher = answer("loaded")
    assert_equal({ state: "loaded", reason: nil, budget: BUDGET, replace_budget: REPLACE_BUDGET, layers: layers,
                   checkout: false, }, show.last[:launches])
    @launcher = answer("none")
    assert_equal %w[none], show.last[:launches].values_at(:state)
    @launcher = { "ok" => false, "status" => 422,
                  "error" => "skills: #{repo('app')}/.busyyaks/skills/x: a skills dir holds directories only", }
    assert_equal ["refused", nil], show.last[:launches].values_at(:state, :budget)
    down = ->(**) { raise Busyyaks::LauncherClient::Unavailable, "launcher not reachable at /x: Errno::ENOENT" }
    Busyyaks::LauncherClient.stub(:project_skills, down) do
      assert_equal({ state: "unknown", reason: "launcher not reachable at /x: Errno::ENOENT", budget: nil,
                     replace_budget: nil, layers: nil, checkout: nil, },
                   API.show("app", db: db, skills: SKILLS, root: @root).last[:launches])
    end
    # a launcher from before this op answers "unknown op": that says nothing about launches — unknown, restart it
    @launcher = { "ok" => false, "error" => "unknown op" }
    assert_equal ["unknown", "launcher protocol error (unknown op): restart it (deploy/install-launcher.sh)"],
                 show.last[:launches].values_at(:state, :reason)
    @launcher = { "ok" => false, "status" => 400, "error" => "settings {id, doc} are required" }
    assert_equal ["unknown", "settings {id, doc} are required"], show.last[:launches].values_at(:state, :reason)
    # busyyaks's own checkout as a project: said, so the page can warn that `yaks update` refuses uncommitted files
    @launcher = answer("loaded", checkout: true)
    assert_equal true, show.last[:launches][:checkout]
  end

  # --- override: a project's .busyyaks changes or replaces busyyaks's agent markdown for its own sessions --------------

  OWN_REVIEWER = "---\nname: reviewer\ndescription: app's own review brief\n---\nAPP-REVIEWER: check the migrations.\n"

  # ".busyyaks directory is where any user who uses busyyaks is able to define, OVERRIDE or change any agent-related
  # markdowns": a project skill named like busyyaks's reviewer IS the reviewer for this project's launches — every
  # type, every harness — and no other project's
  def test_a_project_overrides_the_reviewer_skill_for_its_own_sessions
    status, body = save({ "reviewer/SKILL.md" => OWN_REVIEWER, "reviewer/checklist.md" => "- migrations\n" })
    assert_equal 200, status, body.inspect
    assert_equal %w[reviewer/SKILL.md reviewer/checklist.md], body[:files].keys.sort
    assert_equal %w[skill skill_ref], body[:files].values_at("reviewer/SKILL.md", "reviewer/checklist.md").map { _1[:kind] }
    [claude, hermes].each do |delivery|
      TYPES.each do |type|
        sel, = S.plan!(checkout: ROOT, repo: repo("app"), type: type, types: TYPES, settings: SKILLS, trust_refusal: nil)
        reviewer = sel.skills.find { _1.name == "reviewer" }
        assert_equal ["project", "busyyaks", "APP-REVIEWER: check the migrations.\n"],
                     [reviewer.source, reviewer.replaces, reviewer.body], type
        assert_equal(1, sel.skills.count { _1.name == "reviewer" }, "one reviewer: the project's")
        entry, receipt, = launched("app", type, delivery)
        assert_includes receipt, %w[reviewer project]
        assert_match(/`#{Regexp.escape(delivery.ref('reviewer'))}` \(project, replaces busyyaks's\): app's own review brief/,
                     entry)
      end
    end
    sel, = S.plan!(checkout: ROOT, repo: repo("other"), type: "worker", types: TYPES, settings: SKILLS, trust_refusal: nil)
    assert_equal "busyyaks", sel.skills.find { _1.name == "reviewer" }.source, "another project keeps busyyaks's"
    # removing the project's skill brings busyyaks's back
    assert_equal 200, save({ "reviewer/SKILL.md" => nil, "reviewer/checklist.md" => nil }).first
    refute File.exist?(File.join(repo("app"), ".busyyaks/skills/reviewer")), "the skill dir goes with its last file"
    sel, = S.plan!(checkout: ROOT, repo: repo("app"), type: "worker", types: TYPES, settings: SKILLS, trust_refusal: nil)
    assert_equal "busyyaks", sel.skills.find { _1.name == "reviewer" }.source
  end

  # an agents file with `mode: replace` replaces busyyaks's rules of its type for this project; core stays
  def test_a_project_replaces_the_global_rules_of_a_type_with_mode_replace
    assert_equal 200, save({ "lead" => "---\nmode: replace\n---\nAPP-LEAD: our own lead rules.\n" }).first
    entry, receipt, = launched("app", "lead", claude)
    assert_includes entry, "## Agent type lead (project, replaces busyyaks)\n\nAPP-LEAD: our own lead rules."
    own = S.busyyaks!(ROOT, types: TYPES, settings: SKILLS).first
    refute_includes entry, own.agents.fetch("lead").body.strip, "busyyaks's lead.md is not staged"
    assert_includes entry, own.core.body.strip, "core always is"
    refute_includes receipt, %w[agents/lead busyyaks]
    assert_equal "replace", show.last[:files]["agents/lead.md"][:mode]
    # the launcher's per-type composition says which global file is replaced, and by whom
    comp = S.project_status(checkout: ROOT, repo: repo("app"), types: TYPES, settings: SKILLS,
                            trust_refusal: nil)[:layers]["lead"]
    assert_equal [["skills/busyyaks/agents/lead.md", "project"], [".busyyaks/skills/agents/lead.md", nil]],
                 comp[:start].select { _1[:kind] == "agent" }.map { _1.values_at(:path, :replaced_by) }
    # another type, and the same type in another project, keep busyyaks's
    entry, = launched("app", "worker", claude)
    assert_includes entry, "## Agent type worker (busyyaks)"
    entry, = launched("other", "lead", claude)
    assert_includes entry, "## Agent type lead (busyyaks)"
    # a frontmatter that is not the mode is refused with the launch's own reason, nothing written
    status, body = save({ "lead" => "---\nmode: swap\n---\nx\n" })
    assert_equal 422, status
    assert_match(/an agents file's frontmatter is exactly `mode: add` or `mode: replace`/, error(body))
  end

  # "All must be editable": the tab lists, edits, makes and removes EVERY file under the project's .busyyaks/skills —
  # agents files, skills, their reference files — what it cannot edit (a link, a nested dir) it names; a file removed
  # but still in git is said
  def test_every_file_in_a_projects_busyyaks_is_editable_in_the_web
    dir = File.join(repo("app"), ".busyyaks/skills")
    FileUtils.mkdir_p(File.join(dir, "deploy/deep"))
    File.write(File.join(dir, "deploy/SKILL.md"), "---\nname: deploy\ndescription: how we deploy\n---\nSteps.\n")
    File.write(File.join(dir, "deploy/hosts.md"), "- one\n")
    File.write(File.join(dir, "deploy/deep/x.md"), "nested\n")
    FileUtils.mkdir_p(File.join(dir, "agents"))
    File.write(File.join(dir, "agents/worker.md"), "w\n")
    body = show.last
    assert_equal %w[agents/worker.md deploy/SKILL.md deploy/hosts.md], body[:files].keys.sort
    assert_match(/deploy\/deep is not a regular file/, body[:errors]["deploy/deep"])
    assert_equal %w[agents/lead.md agents/team.md agents/plain.md], body[:creatable]
    # every one of them is edited through the page; the nested dir makes the layer invalid, so a launch — and a save —
    # is refused with the launch's reason until it is gone
    status, body = save({ "deploy/hosts.md" => "- two\n" })
    assert_equal 422, status
    assert_match(/deploy\/deep: a skill holds regular \.md files only/, error(body))
    FileUtils.rm_rf(File.join(dir, "deploy/deep"))
    status, body = save({ "deploy/hosts.md" => "- two\n", "deploy/SKILL.md" => "---\nname: deploy\ndescription: how we " \
                                                                                "deploy now\n---\nSteps v2.\n",
                          "agents/worker.md" => "w2\n", "notes/SKILL.md" => "---\nname: notes\ndescription: n\n---\nN.\n", })
    assert_equal 200, status, body.inspect
    assert_equal "- two\n", File.read(File.join(dir, "deploy/hosts.md"))
    assert_equal %w[agents/worker.md deploy/SKILL.md deploy/hosts.md notes/SKILL.md], body[:files].keys.sort
    entry, = launched("app", "worker", claude)
    assert_includes entry, "`busyyaks:notes` (project): n"
    # a skill whose name does not match its dir, or a reference file left without its SKILL.md: refused, nothing written
    assert_match(/name "other" must be its dir's notes/,
                 error(save({ "notes/SKILL.md" => "---\nname: other\ndescription: n\n---\nN.\n" }).last))
    assert_match(/deploy\/SKILL\.md missing/, error(save({ "deploy/SKILL.md" => nil }).last))
    assert File.exist?(File.join(dir, "deploy/SKILL.md"))
    # removed and committed before: git still holds it — the page says so
    git("add", ".busyyaks")
    git("commit", "-q", "-m", "skills")
    assert_equal 200, save({ "notes/SKILL.md" => nil }).first
    body = show.last
    assert_equal "deleted", body[:git]["notes/SKILL.md"]
    refute body[:files].key?("notes/SKILL.md")
    assert_equal "committed", body[:git]["deploy/hosts.md"]
  end

  # --- the editor's saves -------------------------------------------------------------------------------------------

  def test_the_page_lists_every_agent_type_and_only_the_files_that_exist
    status, body = show
    assert_equal 200, status
    assert_equal [["lead", "Team lead"], %w[worker Worker], ["team", "Sub team"], %w[plain Plain]],
                 body[:types].map { [_1[:key], _1[:label]] }
    assert_equal [{}, {}, 65_536], body.values_at(:files, :errors, :max_bytes)
    assert_equal %w[agents/lead.md agents/worker.md agents/team.md agents/plain.md], body[:creatable]
    assert_equal File.join(Busyyaks::GitRead.host_root, repo("app").delete_prefix(Busyyaks::GitRead.mount.chomp("/")),
                           ".busyyaks/skills"), body[:path] if repo("app").start_with?(Busyyaks::GitRead.mount)
    assert_empty tree("app"), "a read writes nothing"
  end

  def test_a_file_changed_on_disk_since_the_editor_read_it_is_409_and_nothing_is_written
    save({ "lead" => "one\n", "worker" => "w\n" })
    read = show.last[:files].transform_values { _1[:sha] }.transform_keys { File.basename(_1, ".md") }
    File.write(file("app", "lead"), "edited by hand\n")
    status, body = save({ "worker" => "w2\n", "lead" => "two\n" }, bases: read)
    assert_equal 409, status
    assert_match(%r{\.busyyaks/skills/agents/lead\.md changed on disk since the editor read it: nothing written}, error(body))
    assert_equal ["edited by hand\n", "w\n"], [File.read(file("app", "lead")), File.read(file("app", "worker"))]
    # made on disk where the editor saw none; removed where it saw one
    File.write(file("app", "team"), "by hand\n")
    assert_match(/team\.md was made on disk/, error(save({ "team" => "mine\n" }, bases: { "team" => nil }).last))
    FileUtils.rm(file("app", "worker"))
    assert_match(/worker\.md was removed on disk/, error(save({ "worker" => "w3\n" }, bases: read).last))
    # loaded again, the save goes through
    assert_equal 200, save({ "lead" => "two\n" }).first
    assert_equal "two\n", File.read(file("app", "lead"))
  end

  def test_a_blank_editor_removes_the_file
    save({ "lead" => "one\n", "worker" => "w\n" })
    status, body = save({ "lead" => nil })
    assert_equal 200, status
    refute File.exist?(file("app", "lead"))
    assert_equal %w[agents/worker.md], body[:files].keys
  end

  def test_refusals_name_the_file_and_the_rule_and_write_nothing
    {
      { "boss" => "x\n" } => /agents\/boss\.md: boss is not an agent type \(lead, worker, team, plain\)/,
      { "core/SKILL.md" => "x\n" } => /core is busyyaks's core skill — not a project's/,
      { "a/b/c.md" => "x\n" } => /"a\/b\/c\.md": not a file of \.busyyaks\/skills/,
      { "deploy/SKILL.md" => "no front\n" } => /deploy\/SKILL\.md: no frontmatter/,
      { "deploy/notes.md" => "a ref, no SKILL.md\n" } => /deploy\/SKILL\.md missing/,
      { "deploy/SKILL.md" => "  \n" } => /deploy\/SKILL\.md is blank: a skill file holds text — remove the file instead/,
      { "lead" => "see !`id`\n" } => %r{\.busyyaks/skills/agents/lead\.md:1: !`…` \(Claude Code runs it as a shell command\)},
      { "lead" => "  \n" } => /lead\.md is blank: remove the file instead/,
      { "lead" => "x" * 65_537 } => /lead\.md is 65537 bytes, over skills.max_bytes 65536/,
      { "lead" => 3 } => /lead\.md must be markdown text/,
      { "worker" => "fine\n", "lead" => "bad !`x`\n" } => /lead\.md:1/,
    }.each do |texts, why|
      status, body = save(texts)
      assert_equal [422, true], [status, error(body).to_s.match?(why)], "#{texts.inspect}: #{body.inspect}"
      assert_empty tree("app"), "all or nothing: #{texts.inspect}"
    end
    with_launcher do
      assert_equal 422, API.save("app", { "doc" => {} }, by: "op", db: db, skills: SKILLS).first
      assert_equal 422, API.save("app", { "files" => { "lead" => "text" } }, by: "op", db: db, skills: SKILLS).first
      assert_equal 404, API.save("nope", { "files" => {} }, by: "op", db: db, skills: SKILLS).first
      assert_equal 404, API.show("nope", db: db, skills: SKILLS).first
    end
  end

  GIT_ENV = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_AUTHOR_NAME" => "A",
              "GIT_AUTHOR_EMAIL" => "a@x.io", "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@x.io", }.freeze

  def git(*args)
    out, err, st = Open3.capture3(GIT_ENV, "git", "-C", repo("app"), *args)
    raise "git #{args.join(' ')}: #{err}" unless st.success?

    out
  end

  # the files are the repo's own (.busyyaks/skills is committed, unlike workflow.yml): the page says what git holds
  # of each, so an edit of a tracked file is seen as the uncommitted change it leaves
  def test_the_page_says_when_a_file_is_tracked_by_git_and_an_edit_leaves_an_uncommitted_change
    assert_equal [{}, nil], show.last.values_at(:git, :git_error)
    assert_equal({ "agents/lead.md" => "untracked" }, save({ "lead" => "one\n" }).last[:git])
    git("add", ".busyyaks/skills/agents/lead.md")
    assert_equal({ "agents/lead.md" => "added" }, show.last[:git])
    git("commit", "-q", "-m", "rules")
    assert_equal({ "agents/lead.md" => "committed" }, show.last[:git])
    assert_equal({ "agents/lead.md" => "modified", "agents/worker.md" => "untracked" },
save({ "lead" => "two\n", "worker" => "w\n" }).last[:git])
    assert_equal({ "agents/lead.md" => "deleted", "agents/worker.md" => "untracked" }, save({ "lead" => nil }).last[:git])
    assert_equal({ "agents/lead.md" => "committed", "agents/worker.md" => "untracked" }, save({ "lead" => "one\n" }).last[:git],
                 "the committed bytes again: no change left")
    # a committed file that is there but cannot be read here (not UTF-8, over the limit): its editor says why — it is
    # never called "deleted"
    git("add", ".busyyaks/skills/agents")
    git("commit", "-q", "-m", "worker")
    File.binwrite(file("app", "worker"), "\xff\xfe not text\n")
    body = show.last
    assert_match(/worker\.md is not UTF-8/, body[:errors]["agents/worker.md"])
    assert_equal({ "agents/lead.md" => "committed" }, body[:git], "no git state for a file that could not be read")
    File.write(file("app", "worker"), "x" * 70_000)
    body = show.last
    assert_match(/worker\.md is 70000 bytes, over skills.max_bytes/, body[:errors]["agents/worker.md"])
    assert_equal({ "agents/lead.md" => "committed" }, body[:git])
    # a save reads the whole layer as a launch would: with that file over the limit it is refused — put it right first
    status, body = save({ "team" => "t\n" })
    assert_equal 422, status
    assert_match(/worker\.md is 70000 bytes, over skills.max_bytes/, error(body))
    File.write(file("app", "worker"), "w\n")
    # a file git's ignore rules hide will not be committed: said as ignored, never "commit it"
    File.write(File.join(repo("app"), ".gitignore"), ".busyyaks/skills/agents/team.md\n")
    assert_equal "ignored", save({ "team" => "t\n" }).last[:git]["agents/team.md"]
    # git cannot be read (not a repo): said, never guessed
    FileUtils.rm_rf(File.join(repo("other"), ".git"))
    body = show("other").last
    assert_equal({}, body[:git])
    assert_match(/\S/, body[:git_error])
  end

  # a write that fails on the way leaves every file as it was — or names the ones it could not put back
  def test_a_failed_write_puts_the_files_back_or_names_the_ones_left_changed
    project = db[:projects].where(slug: "app").first
    types = TYPES
    ok = ->(_repo) {}
    change = ->(texts) { texts.to_h { |t, body|
 [path(t), { "base" => (b = F.read_bytes(project, path(t), SKILLS)) && F.sha(b), "body" => body }] } }
    F.write!(project, change.({ "lead" => "one\n", "worker" => "w\n" }), types: types, settings: SKILLS, check: ok)
    # the disk fails before anything is written (reading the current files): refused, nothing touched
    F.stub(:read_bytes, ->(*) { raise Errno::EACCES, "lead.md" }) do
      e = assert_raises(F::Refused) do
        F.write!(project, { "agents/lead.md" => { "base" => nil, "body" => "x\n" } }, types: types, settings: SKILLS,
                                                                                     check: ok)
      end
      assert_match(/\Anot written \(Permission denied.*\): every file is as it was\z/, e.message)
    end
    assert_equal "one\n", File.read(file("app", "lead"))
    # the second file fails: the first is put back
    real = F.method(:put)
    fail_worker = lambda do |pr, path, text|
      path == "agents/worker.md" && text == "w2\n" ? raise(Errno::ENOSPC, "worker.md") : real.(pr, path, text)
    end
    F.stub(:put, fail_worker) do
      e = assert_raises(F::Refused) do
        F.write!(project, change.({ "lead" => "two\n", "worker" => "w2\n" }), types: types, settings: SKILLS, check: ok)
      end
      assert_match(/No space left on device.*: every file is as it was/, e.message)
    end
    assert_equal %W[one\n w\n], [File.read(file("app", "lead")), File.read(file("app", "worker"))]
    # the restore fails too: the file left changed is named
    fail_all = ->(pr, path, text) { text == "two\n" ? real.(pr, path, text) : raise(Errno::ENOSPC, path) }
    F.stub(:put, fail_all) do
      e = assert_raises(F::Refused) do
        F.write!(project, change.({ "lead" => "two\n", "worker" => "w2\n" }), types: types, settings: SKILLS, check: ok)
      end
      assert_match(%r{and \.busyyaks/skills/agents/lead\.md could not be put back: it holds the new text}, e.message)
    end
    assert_equal "two\n", File.read(file("app", "lead"))
  end

  # a file within skills.max_bytes can still push a launch's entry skill (busyyaks's core + agents/<type>.md + the
  # project's file) over skills.max_start_bytes — every launch of that type would then be refused: the save reads the
  # layer the way that launch would, and refuses it with the launch's own reason
  def test_a_rule_that_would_make_the_launch_refuse_is_refused_on_save
    room = BUDGET.fetch("lead")
    assert_operator room, :<, SKILLS.max_bytes, "the budget is the tighter limit here"
    status, body = save({ "lead" => "x" * (room + 1) })
    assert_equal 422, status
    assert_match(%r{\Anot written: agent type lead: core \+ agents/lead\.md are \d+ bytes, over skills\.max_start_bytes 32768},
                 error(body))
    assert_empty tree("app"), "nothing written"
    assert_equal 200, save({ "lead" => "x" * room }).first, "exactly the budget fits"
    entry, = launched("app", "lead", claude)
    assert_includes entry, "x" * room
    # replacing the global lead rules, the file has more room: only core stays before it
    big = "---\nmode: replace\n---\n#{'z' * (room + 100)}"
    assert_operator REPLACE_BUDGET.fetch("lead"), :>, room + 100
    assert_equal 200, save({ "lead" => big }).first
    # put there by hand anyway: the launcher's own plan refuses that type's launch — and says so for the page
    File.write(file("app", "lead"), "y" * (room + 1))
    e = assert_raises(S::Invalid) do
      S.project_status(checkout: ROOT, repo: repo("app"), types: TYPES, settings: SKILLS, trust_refusal: nil)
    end
    assert_match(/agent type lead: core \+ agents\/lead.md are \d+ bytes, over skills.max_start_bytes 32768/, e.message)
    FileUtils.rm(file("app", "lead"))
    st = S.project_status(checkout: ROOT, repo: repo("app"), types: TYPES, settings: SKILLS, trust_refusal: nil)
    assert_equal ["loaded", BUDGET, REPLACE_BUDGET], st.values_at(:status, :budget, :replace_budget)
  end

  # while a file is being replaced (or after a killed writer) a launch reads the layer: agents/ must hold only
  # <agent type>.md, skills/ only directories — the temp file lives beside workflow.yml, in .busyyaks/
  def test_a_launch_during_a_save_is_never_refused_by_the_writers_temp_file
    save({ "lead" => "one\n" })
    seen = nil
    rename = File.method(:rename)
    spy = lambda do |tmp, path|
      seen = [tmp, Dir.children(File.dirname(path)).sort, Dir.children(File.join(repo("app"), ".busyyaks/skills")).sort,
              S.project_status(checkout: ROOT, repo: repo("app"), types: TYPES, settings: SKILLS,
                               trust_refusal: nil)[:status],]
      rename.(tmp, path)
    end
    File.stub(:rename, spy) { assert_equal 200, save({ "worker" => "w\n" }).first }
    assert_equal [File.join(repo("app"), ".busyyaks"), %w[lead.md], %w[agents], "loaded"],
                 [File.dirname(seen[0]), *seen[1..]], "the layer is launchable at every moment of the write"
    assert_equal %w[skills], Dir.children(File.join(repo("app"), ".busyyaks")), "no temp file left"
  end

  # a textarea gives LF: a file whose lines end CRLF is shown with LF, is not "changed" by that, and keeps CRLF on save
  def test_a_file_with_crlf_line_endings_keeps_them
    FileUtils.mkdir_p(File.dirname(file("app", "lead")))
    File.binwrite(file("app", "lead"), "one\r\ntwo\r\n")
    f = show.last[:files]["agents/lead.md"]
    assert_equal ["one\ntwo\n", "crlf", F.sha("one\r\ntwo\r\n")], f.values_at(:body, :eol, :sha)
    assert_equal 200, save({ "lead" => "one\ntwo\n" }).first, "what the editor shows, saved back: nothing to write"
    assert_equal "one\r\ntwo\r\n", File.binread(file("app", "lead"))
    assert_equal 200, save({ "lead" => "one\ntwo\nthree\n" }).first
    assert_equal "one\r\ntwo\r\nthree\r\n", File.binread(file("app", "lead"))
    assert_equal "lf", save({ "worker" => "a\nb\n" }).last[:files]["agents/worker.md"][:eol]
    assert_equal "a\nb\n", File.binread(file("app", "worker"))
  end

  # a link in a repo's .busyyaks would write (or read) outside the repo: never followed
  def test_a_symlink_on_the_way_is_never_written_through_or_read
    outside = File.join(@root, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(repo("app"), ".busyyaks"))
    status, body = save({ "lead" => "x\n" }, bases: { "lead" => nil })
    assert_equal 422, status
    assert_match(%r{/\.busyyaks is a symlink}, error(body))
    assert_empty Dir.children(outside)
    FileUtils.rm(File.join(repo("app"), ".busyyaks"))
    FileUtils.mkdir_p(File.dirname(file("app", "lead")))
    File.write(File.join(outside, "secret"), "SECRET\n")
    File.symlink(File.join(outside, "secret"), file("app", "lead"))
    body = show.last
    assert_match(/lead\.md is a symlink/, body[:errors]["agents/lead.md"])
    refute_includes body.inspect, "SECRET"
    assert_equal 422, save({ "lead" => "x\n" }, bases: { "lead" => nil }).first
    assert_equal "SECRET\n", File.read(File.join(outside, "secret"))
  end

  # the web mounts the repos read-only: a save exists only as the writer's — no writer, no save (503), nothing kept
  def test_only_the_writer_service_writes_and_without_it_nothing_is_saved
    WriterServer.stop(@sock)
    @sock = nil
    assert_raises(Busyyaks::WriterClient::Unavailable) do
      with_launcher {
 API.save("app", { "files" => { "agents/lead.md" => { "base" => nil, "body" => "x\n" } } }, by: "op", db: db, skills: SKILLS) }
    end
    assert_empty tree("app")
    src = File.read(File.join(ROOT, "lib/busyyaks/project_agent_rules_api.rb"))
    refute_match(/File\.(write|binwrite|open|rename)|FileUtils|AgentRuleFiles\.(write!|put)/, src, "the web side only reads")
  end
end
