# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require_relative "../../lib/busyyaks/skills"

# The skills bin/launcher hands each session (lib/busyyaks/skills.rb) — the layer shape
# (core · agents/<type>.md · on-demand dirs) and every refusal, the selection per agent type, the three layers, the
# trust rule, the stage per CLI kind. Host-side code: no app.
class SkillsTest < Minitest::Test
  S = Busyyaks::Skills
  ROOT = File.expand_path("../..", __dir__)
  TYPES = %w[lead worker team plain].freeze
  SET = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil)

  def setup
    @tmp = Dir.mktmpdir("skills")
    @co = File.join(@tmp, "checkout")
    @repo = File.join(@tmp, "repo")
    FileUtils.mkdir_p([@co, @repo])
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def skill(dir, name, body = "Body of #{name}.\n", front: { "name" => name, "description" => "about #{name}" })
    FileUtils.mkdir_p(File.join(dir, name))
    File.write(File.join(dir, name, "SKILL.md"), "#{front.to_yaml}---\n#{body}")
  end

  def agent(dir, type, body = "Do the #{type} things.\n")
    FileUtils.mkdir_p(File.join(dir, "agents"))
    File.write(File.join(dir, "agents", "#{type}.md"), body)
  end

  # busyyaks's layer: core + agents/<types>.md + on-demand skills
  def own(agents: %w[lead worker], skills: %w[reviewer])
    dir = File.join(@co, "skills/busyyaks")
    skill(dir, "core")
    agents.each { |t| agent(dir, t) }
    skills.each { |n| skill(dir, n) }
    dir
  end

  def refused(pattern, &)
    e = assert_raises(S::Invalid, &)
    assert_match(pattern, e.message)
  end

  def load_own(settings = SET) = S.busyyaks!(@co, types: TYPES, settings: settings)

  # --- the repo's own skills --------------------------------------------------------------------------------------

  # every template type launches: core for all, agents/<type>.md where busyyaks has one, reviewer on demand
  def test_the_repos_skills_load_for_every_template_type
    layers = S.busyyaks!(ROOT, types: TYPES, settings: SET)
    assert_equal %w[busyyaks], layers.map(&:source)
    own = layers.first
    assert_equal "core", own.core.name
    # + the preset types' briefs (config/agent_presets.yml), staged once a deployment adds the type
    assert_equal %w[copywriter lead researcher team worker], own.agents.keys.sort
    assert_equal %w[critic design qa reviewer security], own.skills.map(&:name)
    TYPES.each { |t| S.check_selection!(S.select(layers, t), SET) }
    assert_empty S.select(layers, "plain").parts, "plain = core alone"
  end

  # card 612: the lead skill carries the rule — never a card's assignee; each card waiting for a worker goes to an
  # idle worker (kanban_assign_worker) or a new one (kanban_spawn); Backlog is not the lead's to hand out
  def test_the_lead_skill_says_the_lead_is_never_an_assignee_and_how_it_dispatches
    lead = File.read(File.join(ROOT, "skills/busyyaks/agents/lead.md"))
    assert_includes lead, "**You are never a card's assignee** (card 612)"
    assert_match(/IDLE worker of the board first — `mcp__busyyaks__kanban_assign_worker\(id,\s+worker_session/, lead)
    assert_match(/else a new one with\s+`mcp__busyyaks__kanban_spawn\(id, type "worker"/, lead)
    assert_includes lead, "`dispatch.idle_workers`"
    assert_match(/Backlog cards are never yours to hand\s+out: only the operator moves them on/, lead)
    refute_match(/never owns or works a card itself/, lead, "the old wording (it owns, for routing) is gone")
  end

  # busyyaks's own repo layer (.busyyaks/skills, committed): only additions for agent types, nothing replaced
  def test_the_repos_own_project_layer_loads
    sel, status = S.plan!(checkout: ROOT, repo: ROOT, type: "worker", types: TYPES, settings: SET, trust_refusal: nil)
    assert_equal "loaded", status
    assert_equal [%w[worker busyyaks], %w[worker project]], sel.parts.map { [_1.type, _1.source] }
  end

  # --- settings ----------------------------------------------------------------------------------------------------

  def test_settings_are_required_and_checked
    ok = { "max_bytes" => 1, "max_start_bytes" => 1, "project" => "deny", "local_dir" => "skills-local" }
    assert_equal "skills-local", S.settings!(ok).local_dir
    [nil, ok.except("project"), ok.merge("x" => 1), ok.merge("max_bytes" => 0), ok.merge("max_start_bytes" => "1"),
     ok.merge("project" => "yes"), ok.merge("local_dir" => "/abs"), ok.merge("local_dir" => "../out"),
     ok.merge("local_dir" => "skills/x"),].each do |bad|
      assert_raises(S::Invalid, bad.inspect) { S.settings!(bad) }
    end
  end

  # --- layer refusals ------------------------------------------------------------------------------------------------

  def test_core_is_required_in_busyyaks_layer
    dir = own
    FileUtils.rm_rf(File.join(dir, "core"))
    refused(%r{skills/busyyaks/core/SKILL.md missing \(every session starts with it\)}) { load_own }
    FileUtils.rm_rf(@co)
    refused(%r{skills/busyyaks missing}) { load_own }
  end

  def test_every_layer_shape_refusal
    dir = own
    File.write(File.join(dir, "README.md"), "x")
    refused(/holds directories only/) { load_own }
    FileUtils.rm_f(File.join(dir, "README.md"))
    skill(dir, "Bad_Name")
    refused(/skill name "Bad_Name" must match/) { load_own }
    FileUtils.rm_rf(File.join(dir, "Bad_Name"))
    skill(dir, "session")
    refused(/session is the generated entry skill's name/) { load_own }
  end

  def test_agents_files_are_type_named_md_only
    dir = own
    agent(dir, "boss")
    refused(%r{agents/boss.md: boss is not an agent type \(copywriter, researcher, lead, worker, team, plain\)}) { load_own }
    FileUtils.rm_f(File.join(dir, "agents/boss.md"))
    File.write(File.join(dir, "agents/notes.txt"), "x")
    refused(%r{agents/notes.txt: agents/ holds <agent type>.md files only}) { load_own }
    FileUtils.rm_f(File.join(dir, "agents/notes.txt"))
    FileUtils.mkdir_p(File.join(dir, "agents/team.md"))
    refused(/agents\/ holds <agent type>.md files only/) { load_own }
    FileUtils.rm_rf(File.join(dir, "agents/team.md"))
    File.symlink(File.join(dir, "agents/lead.md"), File.join(dir, "agents/team.md"))
    refused(/agents\/ holds <agent type>.md files only/) { load_own }
    FileUtils.rm_f(File.join(dir, "agents/team.md"))
    File.binwrite(File.join(dir, "agents/team.md"), "\xff\n")
    refused(/team.md is not UTF-8/) { load_own }
  end

  def test_a_skill_holds_regular_md_files_with_exact_frontmatter
    dir = own
    sk = File.join(dir, "reviewer")
    File.write(File.join(sk, "run.sh"), "x")
    refused(/regular .md files only/) { load_own }
    FileUtils.rm_f(File.join(sk, "run.sh"))
    File.symlink(File.join(sk, "SKILL.md"), File.join(sk, "more.md"))
    refused(/regular .md files only/) { load_own }
    FileUtils.rm_f(File.join(sk, "more.md"))
    FileUtils.mkdir_p(File.join(sk, "sub"))
    refused(/regular .md files only/) { load_own }
    FileUtils.rm_rf(File.join(sk, "sub"))
    skill(dir, "reviewer", front: { "name" => "reviewer", "description" => "d", "allowed-tools" => "Bash" })
    refused(/frontmatter must be exactly name \+ description/) { load_own }
    skill(dir, "reviewer", front: { "name" => "other", "description" => "d" })
    refused(/name "other" must be its dir's reviewer/) { load_own }
    File.write(File.join(sk, "SKILL.md"), "no frontmatter\n")
    refused(/no frontmatter/) { load_own }
    File.binwrite(File.join(sk, "SKILL.md"), "---\nname: reviewer\ndescription: \xff\n---\n")
    refused(/not UTF-8/) { load_own }
  end

  def test_size_limits
    dir = own
    small = S.settings!("max_bytes" => 50, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil)
    refused(/over skills.max_bytes 50/) { load_own(small) }
    FileUtils.rm_rf(File.join(dir, "reviewer"))
    FileUtils.rm_rf(File.join(dir, "core"))
    skill(dir, "core", "c\n", front: { "name" => "core", "description" => "d" })
    agent(dir, "lead", "x" * 60)
    refused(%r{agents/lead.md is 60 bytes, over skills.max_bytes 50}) { load_own(small) }
    tight = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 30, "project" => "allow", "local_dir" => nil)
    layers = load_own(tight)
    S.check_selection!(S.select(layers, "plain"), tight) # core alone fits
    refused(%r{agent type lead: core \+ agents/lead.md are 62 bytes, over skills.max_start_bytes 30}) do
      S.check_selection!(S.select(layers, "lead"), tight)
    end
  end

  # --- the deployment's layer ----------------------------------------------------------------------------------------

  def local_set = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow",
                              "local_dir" => "skills-local")

  def test_the_deployments_local_dir_adds_agents_and_skills_and_replaces_by_the_same_rule
    own
    local = File.join(@co, "skills-local")
    skill(local, "local-repo")
    agent(local, "worker", "deployment worker rule\n")
    layers = S.busyyaks!(@co, types: TYPES, settings: local_set)
    assert_equal %w[busyyaks deployment], layers.map(&:source)
    sel = S.select(layers, "worker")
    assert_equal [%w[worker busyyaks], %w[worker deployment]], sel.parts.map { [_1.type, _1.source] }
    assert_equal [%w[reviewer busyyaks], %w[local-repo deployment]], sel.skills.map { [_1.name, _1.source] }
    # the override rule is one for every later layer: a deployment skill of a busyyaks name replaces it
    skill(local, "reviewer", "the deployment's review brief\n")
    sel = S.select(S.busyyaks!(@co, types: TYPES, settings: local_set), "worker")
    assert_equal [%w[reviewer deployment busyyaks], %w[local-repo deployment] + [nil]],
                 sel.skills.map { [_1.name, _1.source, _1.replaces] }
    assert_equal [{ kind: "skill", path: "skills/busyyaks/reviewer", source: "busyyaks", by: "deployment" }], sel.replaced
    FileUtils.rm_rf(File.join(local, "reviewer"))
    skill(local, "core")
    refused(/core is busyyaks's core skill, not replaceable by a layer — edit it for every session/) do
      S.busyyaks!(@co, types: TYPES, settings: local_set)
    end
  end

  # --- the override rule (Skills.select) ---------------------------------------------------------------------------

  def test_an_agents_file_adds_by_default_and_replaces_with_mode_replace
    own
    agent(pdir, "lead", "project lead rule\n")
    sel, = plan
    assert_equal [%w[busyyaks add], %w[project add]], sel.parts.map { [_1.source, _1.mode] }
    assert_empty sel.replaced
    agent(pdir, "lead", "---\nmode: add\n---\nproject lead rule\n")
    sel, = plan
    assert_equal [%w[busyyaks add], %w[project add]], sel.parts.map { [_1.source, _1.mode] }
    assert_equal "project lead rule\n", sel.parts.last.body, "the frontmatter is not part of the rule"
    agent(pdir, "lead", "---\nmode: replace\n---\nONLY the project's lead rule\n")
    sel, = plan
    assert_equal [["project", "replace", ["busyyaks"]]], sel.parts.map { [_1.source, _1.mode, _1.replaces] }
    assert_equal [{ kind: "agent", path: "skills/busyyaks/agents/lead.md", source: "busyyaks", by: "project" }],
                 sel.replaced
    entry = S.entry_body(sel, S::ClaudeCode.new)
    assert_includes entry, "## Agent type lead (project, replaces busyyaks)\n\nONLY the project's lead rule"
    refute_includes entry, "Do the lead things.", "busyyaks's lead.md is not staged"
    assert_includes entry, "Body of core.", "core is never replaced"
    sel, = plan(type: "worker")
    assert_equal %w[busyyaks], sel.parts.map(&:source), "another type keeps busyyaks's rules"
    # replacing with nothing is a file: the type then starts with core alone
    agent(pdir, "lead", "---\nmode: replace\n---\n")
    assert_equal [""], plan.first.parts.map(&:body)
  end

  def test_an_agents_files_frontmatter_is_mode_or_nothing_and_busyyaks_own_layer_replaces_nothing
    own
    agent(pdir, "lead", "---\nmode: swap\n---\nx\n")
    refused(/agents\/lead.md: an agents file's frontmatter is exactly `mode: add` or `mode: replace`/) { plan }
    agent(pdir, "lead", "---\nname: lead\n---\nx\n")
    refused(/frontmatter is exactly `mode: add`/) { plan }
    FileUtils.rm_rf(pdir)
    agent(File.join(@co, "skills/busyyaks"), "lead", "---\nmode: replace\n---\nx\n")
    refused(/mode: replace in busyyaks's own layer — there is no earlier layer to replace/) { plan }
  end

  def test_a_project_skill_of_a_busyyaks_name_replaces_it_and_a_chain_is_said_layer_by_layer
    own
    local = File.join(@co, "skills-local")
    skill(local, "reviewer", "deployment's\n")
    agent(local, "lead", "---\nmode: replace\n---\ndeployment lead\n")
    skill(pdir, "reviewer", "project's\n")
    agent(pdir, "lead", "---\nmode: replace\n---\nproject lead\n")
    sel, = S.plan!(checkout: @co, repo: @repo, type: "lead", types: TYPES, settings: local_set, trust_refusal: nil)
    assert_equal [%w[reviewer project deployment]], sel.skills.map { [_1.name, _1.source, _1.replaces] }
    assert_equal "project's\n", sel.skills.first.body
    assert_equal [%w[project deployment]], sel.parts.map { [_1.source, *_1.replaces] }
    assert_equal [%w[agent busyyaks deployment], %w[skill busyyaks deployment], %w[agent deployment project],
                  %w[skill deployment project],], sel.replaced.map { _1.values_at(:kind, :source, :by) }
    layers = S.busyyaks!(@co, types: TYPES, settings: local_set) + [S.project(@repo, types: TYPES, settings: local_set)]
    comp = S.composition(layers, "lead")
    assert_equal [["skills/busyyaks/core/SKILL.md", nil], ["skills/busyyaks/agents/lead.md", "deployment"],
                  ["skills-local/agents/lead.md", "project"], [".busyyaks/skills/agents/lead.md", nil],],
                 comp[:start].map { _1.values_at(:path, :replaced_by) }
    assert_equal [["busyyaks", "deployment", nil], ["deployment", "project", nil], ["project", nil, "deployment"]],
                 comp[:on_demand].map { _1.values_at(:source, :replaced_by, :replaces) }
    entry = S.entry_body(sel, S::ClaudeCode.new)
    assert_includes entry, "- `busyyaks:reviewer` (project, replaces deployment's): about reviewer"
  end

  # --- the project layer + trust -----------------------------------------------------------------------------------

  def pdir = File.join(@repo, ".busyyaks/skills")

  def plan(trust_refusal: nil, settings: SET, type: "lead")
    S.plan!(checkout: @co, repo: @repo, type: type, types: TYPES, settings: settings, trust_refusal: trust_refusal)
  end

  def test_no_project_skills_dir_means_only_busyyaks_skills
    own
    FileUtils.mkdir_p(File.join(@repo, ".busyyaks")) # workflow.yml's dir alone: no skills
    File.write(File.join(@repo, ".busyyaks/workflow.yml"), "columns: []\n")
    sel, status = plan(trust_refusal: "not trusted")
    assert_equal "none", status, "a repo with only its workflow file has no skills to leave"
    assert_equal %w[lead], sel.parts.map(&:type)
  end

  def test_a_trusted_projects_agent_files_and_skills_load_after_busyyaks
    own
    agent(pdir, "lead", "project lead rule\n")
    agent(pdir, "team", "project team rule\n")
    skill(pdir, "deploy-notes")
    sel, status = plan
    assert_equal "loaded", status
    assert_equal [%w[lead busyyaks], %w[lead project]], sel.parts.map { [_1.type, _1.source] }
    assert_equal [%w[reviewer busyyaks], %w[deploy-notes project]], sel.skills.map { [_1.name, _1.source] }
    sel, = plan(type: "team")
    assert_equal [%w[team project]], sel.parts.map { [_1.type, _1.source] }, "busyyaks has no team.md in this fixture"
  end

  # a repo still on the manifest layout (.busyyaks/skills.yml) is never half-read: its skills are left, named
  def test_a_repo_on_the_old_manifest_layout_is_left_with_the_reason
    own
    FileUtils.mkdir_p(File.join(@repo, ".busyyaks/skills/deploy"))
    File.write(File.join(@repo, ".busyyaks/skills.yml"), "version: 1\nskills: {deploy: {types: [lead], load: start}}\n")
    File.write(File.join(@repo, ".busyyaks/skills/deploy/SKILL.md"), "---\nname: deploy\ndescription: d\n---\nx\n")
    sel, status = plan(trust_refusal: nil)
    assert_match(%r{\Aleft: .*/\.busyyaks/skills\.yml is the old manifest layout: no manifests now}, status)
    assert_equal %w[busyyaks], sel.parts.map(&:source).uniq, "nothing of the repo's layer loaded"
    assert_empty sel.skills.select { _1.source == "project" }
    FileUtils.rm_rf(File.join(@repo, ".busyyaks/skills"))
    _, status = plan(trust_refusal: nil)
    assert_match(/\Aleft: .*old manifest layout/, status, "the manifest alone is named too, never \"none\"")
  end

  def test_an_untrusted_or_denied_project_is_left_unread
    own
    FileUtils.mkdir_p(File.join(pdir, "agents"))
    File.write(File.join(pdir, "agents/boss.md"), "x") # never read: no refusal
    sel, status = plan(trust_refusal: "repo is not trusted")
    assert_equal "left: repo is not trusted", status
    assert_equal %w[busyyaks], sel.parts.map(&:source)
    deny = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "deny", "local_dir" => nil)
    assert_equal "left: config/busyyaks.yml skills.project is deny", plan(settings: deny)[1]
  end

  def test_a_trusted_projects_bad_skills_refuse_the_launch
    own
    skill(pdir, "core")
    refused(/core is busyyaks's core skill, not replaceable by a layer/) { plan }
    FileUtils.rm_rf(File.join(pdir, "core"))
    agent(pdir, "boss")
    refused(/boss is not an agent type/) { plan }
    FileUtils.rm_rf(pdir)
    File.write(pdir, "not a dir")
    refused(%r{\.busyyaks/skills is not a directory}) { plan }
  end

  # --- the stage per kind ------------------------------------------------------------------------------------------

  def staged(delivery, type: "worker")
    dir = own
    File.write(File.join(dir, "core/links.md"), "Link rules.\n")
    agent(pdir, "worker", "project worker rule\n")
    sel, = plan(type: type)
    dest = File.join(@tmp, "stage/s1")
    [dest, S.stage!(sel, dest, delivery)]
  end

  # a project ROLE (the repo's .busyyaks/agents.yml roles) = its type's parts + the role's brief, the project
  # layer's agents/<role>.md, after them; only from a loaded layer, never as a replacement
  def test_a_role_launch_gets_its_types_parts_then_the_roles_brief
    own = File.join(@co, "skills/busyyaks")
    skill(own, "core")
    agent(own, "worker")
    pdir = File.join(@repo, ".busyyaks/skills")
    FileUtils.mkdir_p(pdir)
    File.write(File.join(@repo, ".busyyaks/agents.yml"), "roles:\n  changelog: {label: Changelog writer, like: worker}\n")
    agent(pdir, "changelog", "Write one changelog entry.\n")
    sel, status = S.plan!(checkout: @co, repo: @repo, type: "worker", types: TYPES, settings: SET, trust_refusal: nil,
                          role: "changelog")
    assert_equal "loaded", status
    assert_equal [%w[worker busyyaks], %w[changelog project]], sel.parts.map { [_1.type, _1.source] }
    entry = S.entry_body(sel, S::ClaudeCode.new)
    assert_includes entry, "## Agent role changelog (project)\n\nWrite one changelog entry."
    # over the entry skill's limit: the refusal names the role's brief too (QA round 4)
    tight = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 40, "project" => "allow", "local_dir" => nil)
    e = assert_raises(S::Invalid) { S.check_selection!(sel, tight) }
    assert_match(%r{agent type worker with role changelog: core \+ agents/worker\.md \+ agents/changelog\.md are \d+ bytes},
e.message)
    plain, = S.plan!(checkout: @co, repo: @repo, type: "worker", types: TYPES, settings: SET, trust_refusal: nil)
    assert_equal %w[worker], plain.parts.map(&:type), "a worker with no role does not get the role's brief"
    e = assert_raises(S::Invalid) do
      S.plan!(checkout: @co, repo: @repo, type: "worker", types: TYPES, settings: SET, trust_refusal: "not trusted",
              role: "changelog")
    end
    assert_match(/role changelog: the repo's .busyyaks\/skills is left: not trusted — its brief cannot load/, e.message)
    agent(pdir, "changelog", "---\nmode: replace\n---\nOnly this.\n")
    e = assert_raises(S::Invalid) do
      S.plan!(checkout: @co, repo: @repo, type: "worker", types: TYPES, settings: SET, trust_refusal: nil, role: "changelog")
    end
    assert_match(/a role's brief follows its type's parts — mode: replace is for an agent type's file/, e.message)
    FileUtils.rm_f(File.join(@repo, ".busyyaks/agents.yml"))
    e = assert_raises(S::Invalid) { S.project(@repo, types: TYPES, settings: SET) }
    assert_match(/changelog is not an agent type/, e.message, "a brief whose role the file no longer has refuses the layer")
  end

  def test_the_claude_code_stage_is_a_plugin_with_the_entry_skill
    d = S::ClaudeCode.new
    dest, receipt = staged(d)
    assert_equal [%w[core busyyaks start], %w[agents/worker busyyaks start], %w[agents/worker project start],
                  %w[reviewer busyyaks on_demand], %w[session busyyaks start],],
                 receipt.map { [_1[:name], _1[:source], _1[:load]] }
    assert(receipt.all? { _1[:sha].match?(/\A\h{64}\z/) })
    assert_equal 0o700, File.stat(dest).mode & 0o777
    assert_equal({ "name" => "busyyaks" }, JSON.parse(File.read(File.join(dest, ".claude-plugin/plugin.json"))))
    entry = File.read(File.join(dest, "skills/session/SKILL.md"))
    assert_match(/\A---\nname: session\ndescription: /, entry)
    assert_includes entry, "# busyyaks session (agent type worker)"
    assert_includes entry, "Body of core."
    assert_includes entry, "Reference files beside this skill: `links.md`."
    assert_equal "Link rules.\n", File.read(File.join(dest, "skills/session/links.md"))
    core = entry.index("Body of core.")
    own_part = entry.index("## Agent type worker (busyyaks)\n\nDo the worker things.")
    project_part = entry.index("## Agent type worker (project)\n\nproject worker rule")
    assert core < own_part && own_part < project_part, "core, then busyyaks's agent file, then the project's"
    assert_includes entry, "load each by the name given here"
    assert_includes entry, "- `busyyaks:reviewer` (busyyaks): about reviewer"
    refute File.exist?(File.join(dest, "skills/core")), "core is the entry skill itself, not a second skill"
    assert_match(/\A---\nname: reviewer\n/, File.read(File.join(dest, "skills/reviewer/SKILL.md")))
    # --mcp-config first (variadic), --plugin-dir ends it before the prompt
    assert_equal ["--mcp-config", File.join(dest, "mcp.json"), "--plugin-dir", dest], d.extra(dest)
    assert_equal "/busyyaks:session hi", d.prompt("hi")
    assert_equal "/busyyaks:session", d.prompt(nil)
    assert_empty d.env(dest)
  end

  def test_a_plain_session_gets_core_alone
    _dest, receipt = staged(S::ClaudeCode.new, type: "plain")
    assert_equal %w[core reviewer session], receipt.map { _1[:name] }
  end

  LAUNCH_ID = "a" * 12 # a fixed per-launch id: the names are deterministic here

  def test_the_hermes_stage_is_a_skills_dir_named_for_hermes
    d = S::Hermes.new(LAUNCH_ID)
    dest, = staged(d)
    entry = File.read(File.join(dest, "busyyaks-skills/busyyaks-session-#{LAUNCH_ID}/SKILL.md"))
    assert_match(/\A---\nname: busyyaks-session-#{LAUNCH_ID}\n/, entry)
    assert_includes entry, "`busyyaks-reviewer-#{LAUNCH_ID}`"
    assert_includes entry, "## Agent type worker (project)"
    reviewer = File.read(File.join(dest, "busyyaks-skills/busyyaks-reviewer-#{LAUNCH_ID}/SKILL.md"))
    assert_match(/\A---\nname: busyyaks-reviewer-#{LAUNCH_ID}\n/, reviewer)
    assert_equal ["-s", "busyyaks-session-#{LAUNCH_ID}"], d.extra(dest)
    assert_equal({ "BUSYYAKS_SKILLS_DIR" => dest }, d.env(dest))
    assert_equal "${BUSYYAKS_SKILLS_DIR}/busyyaks-skills", S::Hermes::LINE
    assert_equal "x", d.prompt("x")
  end

  # a fresh token per launch: a user's own busyyaks-session (hermes looks in its local skills dir first) never matches
  def test_hermes_names_are_per_launch
    a = S::Hermes.new
    b = S::Hermes.new
    refute_equal a.skill_name("session"), b.skill_name("session")
    assert_match(/\Abusyyaks-session-\h{12}\z/, a.skill_name("session"))
    assert_raises(ArgumentError) { S::Hermes.new("x; rm") }
  end

  # `hermes skills list` (v0.21.5's table) has the entry skill's row ENABLED → loaded; missing or disabled → why
  def test_hermes_listed_reads_its_skills_table
    d = S::Hermes.new(LAUNCH_ID)
    head = "┃ Name ┃ Category ┃ Source ┃ Trust ┃ Status ┃\n"
    assert_nil d.listed("#{head}│ busyyaks-session-#{LAUNCH_ID} │          │ external │ local │ enabled │\n", "/h")
    shadow = "│ busyyaks-session │ │ external │ local │ enabled │\n│ busyyaks-session-#{LAUNCH_ID}x │ external │\n"
    why = d.listed("#{head}#{shadow}",
"/h")
    assert_equal "hermes does not list busyyaks-session-#{LAUNCH_ID}: /h/config.yaml needs " \
                 "`- ${BUSYYAKS_SKILLS_DIR}/busyyaks-skills` under skills.external_dirs (inert for every run busyyaks " \
                 "does not start)", why
    why = d.listed("#{head}│ busyyaks-session-#{LAUNCH_ID} │          │ external │ local │ disabled │\n", "/h")
    assert_match(/lists busyyaks-session-#{LAUNCH_ID} as disabled, not enabled/, why)
  end

  def test_the_delivery_per_kind
    assert_instance_of S::ClaudeCode, S.delivery("claude_code")
    assert_instance_of S::Hermes, S.delivery("hermes")
    refused(/kind codex: busyyaks has no way to hand it skills/) { S.delivery("codex") }
  end

  # --- links and shell lines (review round 1) ----------------------------------------------------------------------

  def test_a_project_layer_link_anywhere_is_refused
    own
    out = File.join(@tmp, "outside")
    skill(out, "secret", "PRIVATE CONTENT FROM OUTSIDE THE REPO\n")
    agent(out, "lead", "PRIVATE\n")
    base = File.join(@repo, ".busyyaks")
    # .busyyaks itself a link
    FileUtils.mkdir_p(File.join(@tmp, "elsewhere/skills"))
    File.symlink(File.join(@tmp, "elsewhere"), base)
    refused(%r{\.busyyaks is a symlink}) { plan }
    File.unlink(base)
    # skills a link out
    FileUtils.mkdir_p(base)
    File.symlink(out, File.join(base, "skills"))
    refused(%r{\.busyyaks/skills is a symlink}) { plan }
    File.unlink(File.join(base, "skills"))
    # agents a link out, an agent file a link out
    FileUtils.mkdir_p(pdir)
    File.symlink(File.join(out, "agents"), File.join(pdir, "agents"))
    refused(%r{skills/agents is a symlink}) { plan }
    File.unlink(File.join(pdir, "agents"))
    FileUtils.mkdir_p(File.join(pdir, "agents"))
    File.symlink(File.join(out, "agents/lead.md"), File.join(pdir, "agents/lead.md"))
    refused(%r{agents/lead.md: agents/ holds <agent type>.md files only}) { plan }
    File.unlink(File.join(pdir, "agents/lead.md"))
    # a skill dir a link out, a skill file a link out
    File.symlink(File.join(out, "secret"), File.join(pdir, "secret"))
    refused(%r{skills/secret is a symlink}) { plan }
    File.unlink(File.join(pdir, "secret"))
    FileUtils.mkdir_p(File.join(pdir, "secret"))
    File.symlink(File.join(out, "secret/SKILL.md"), File.join(pdir, "secret/SKILL.md"))
    refused(%r{secret/SKILL.md: a skill holds regular .md files only}) { plan }
  end

  def test_a_busyyaks_or_deployment_layer_link_is_refused
    own
    out = File.join(@tmp, "outside")
    skill(out, "local-x")
    File.symlink(out, File.join(@co, "skills-local"))
    refused(/skills-local is a symlink/) { S.busyyaks!(@co, types: TYPES, settings: local_set) }
    FileUtils.mv(File.join(@co, "skills"), File.join(@tmp, "real-skills"))
    File.symlink(File.join(@tmp, "real-skills"), File.join(@co, "skills"))
    refused(%r{checkout/skills is a symlink}) { load_own }
  end

  def test_a_shell_inline_line_is_refused_with_file_and_line
    dir = own
    File.write(File.join(dir, "core/SKILL.md"), "---\nname: core\ndescription: d\n---\nok\nRun !`cat ~/.ssh/id_rsa` now\n")
    refused(%r{core/SKILL.md:6: !`…` \(Claude Code runs it as a shell command\)}) { load_own }
    File.write(File.join(dir, "core/SKILL.md"), "---\nname: core\ndescription: d\n---\nok\n")
    File.write(File.join(dir, "core/more.md"), "!`id`\n")
    refused(%r{core/more.md:1: }) { load_own }
    FileUtils.rm_f(File.join(dir, "core/more.md"))
    agent(dir, "lead", "fine\n!`id`\n")
    refused(%r{agents/lead.md:2: }) { load_own }
  end

  # the lead's skill forbids Backlog work (the engine refuses it too) and reads "push tickets" as the cards
  # already past Backlog; it reaches every lead's entry skill
  def test_the_lead_never_prioritises_backlog_work
    lead = File.read(File.join(ROOT, "skills/busyyaks/agents/lead.md"))
    assert_match(/Never prioritise or start Backlog work/, lead)
    assert_match(/"Push\s+tickets" \/ "update tickets" means the cards already past Backlog/, lead)
    assert_match(/`kanban_move`, `kanban_claim` and `kanban_spawn`/, lead)
  end

  def test_the_repos_own_skills_hold_no_shell_inline
    S.busyyaks!(ROOT, types: TYPES, settings: SET) # refuses a !` line
    Dir.glob(File.join(ROOT, "{skills,skills-local,.busyyaks/skills}/**/*.md")).each { |f| refute_match(/!`/, File.read(f), f) }
  end

  def test_sweep_removes_only_the_stages_of_gone_sessions
    stages = File.join(@tmp, "stages")
    %w[a b c].each { FileUtils.mkdir_p(File.join(stages, _1)) }
    S.sweep(stages, %w[a c])
    assert_equal %w[a c], Dir.children(stages).sort
    assert_empty S.sweep(File.join(@tmp, "none"), [])
  end
end
