# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require_relative "../../lib/busyyaks/skills"

# The skills bin/launcher hands each session (lib/busyyaks/skills.rb) — the manifests and every refusal,
# the selection per agent type, the two layers, the trust rule, the stage per CLI kind. Host-side code: no app.
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

  def manifest(path, skills)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, YAML.dump("version" => 1, "skills" => skills))
  end

  def own(skills = { "workflow" => { "types" => "all", "load" => "start" } })
    dir = File.join(@co, "skills")
    manifest(File.join(dir, "manifest.yml"), skills)
    skills.each_key { |n| skill(dir, n) }
    dir
  end

  def refused(pattern, &)
    e = assert_raises(S::Invalid, &)
    assert_match(pattern, e.message)
  end

  # --- the repo's own skills --------------------------------------------------------------------------------------

  def test_the_repos_skills_load_for_every_template_type
    skills = S.busyyaks!(ROOT, types: TYPES, settings: SET)
    assert_equal %w[workflow lead author reviewer], skills.map(&:name)
    TYPES.each { |t| S.check_selection!(S.select(skills, t), t, SET) }
    assert_equal %w[workflow author reviewer], S.select(skills, "worker").map(&:name)
    assert_equal %w[workflow], S.select(skills, "team").map(&:name)
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

  # --- manifest refusals -------------------------------------------------------------------------------------------

  def test_every_manifest_refusal
    dir = own
    path = File.join(dir, "manifest.yml")
    load = -> { S.busyyaks!(@co, types: TYPES, settings: SET) }
    { { "version" => 2, "skills" => { "workflow" => { "types" => "all", "load" => "start" } } } => /version must be 1/,
      { "version" => 1, "skills" => {}, "x" => 1 } => /must be \{version, skills\}/,
      { "version" => 1, "skills" => {} } => /non-empty map/,
      { "version" => 1, "skills" => { "workflow" => { "types" => "all", "load" => "always" } } } => /load must be/,
      { "version" => 1, "skills" => { "workflow" => { "types" => "all" } } } => /must be \{types, load\}/,
      { "version" => 1, "skills" => { "workflow" => { "types" => ["boss"], "load" => "start" } } } => /boss not an agent type/,
      { "version" => 1, "skills" => { "workflow" => { "types" => [], "load" => "start" } } } => /all or a list/,
      { "version" => 1, "skills" => { "Bad_Name" => { "types" => "all", "load" => "start" } } } => /must match/,
      { "version" => 1, "skills" => { "session" => { "types" => "all", "load" => "start" } } } => /generated entry/, }
      .each do |doc, pattern|
        File.write(path, YAML.dump(doc))
        refused(pattern, &load)
      end
  end

  def test_the_manifest_and_the_dirs_must_agree
    dir = own
    skill(dir, "stray")
    refused(/stray not in .*manifest.yml/) { S.busyyaks!(@co, types: TYPES, settings: SET) }
    FileUtils.rm_rf(File.join(dir, "stray"))
    FileUtils.rm_rf(File.join(dir, "workflow"))
    refused(/workflow named in .*manifest.yml but missing/) { S.busyyaks!(@co, types: TYPES, settings: SET) }
    FileUtils.rm_rf(@co)
    refused(%r{skills/manifest.yml missing}) { S.busyyaks!(@co, types: TYPES, settings: SET) }
  end

  def test_a_skill_holds_regular_md_files_with_exact_frontmatter
    dir = own
    sk = File.join(dir, "workflow")
    load = -> { S.busyyaks!(@co, types: TYPES, settings: SET) }
    File.write(File.join(sk, "run.sh"), "x")
    refused(/regular .md files only/, &load)
    FileUtils.rm_f(File.join(sk, "run.sh"))
    File.symlink(File.join(sk, "SKILL.md"), File.join(sk, "more.md"))
    refused(/regular .md files only/, &load)
    FileUtils.rm_f(File.join(sk, "more.md"))
    FileUtils.mkdir_p(File.join(sk, "sub"))
    refused(/regular .md files only/, &load)
    FileUtils.rm_rf(File.join(sk, "sub"))
    skill(dir, "workflow", front: { "name" => "workflow", "description" => "d", "allowed-tools" => "Bash" })
    refused(/frontmatter must be exactly name \+ description/, &load)
    skill(dir, "workflow", front: { "name" => "other", "description" => "d" })
    refused(/name "other" must be its dir's workflow/, &load)
    File.write(File.join(sk, "SKILL.md"), "no frontmatter\n")
    refused(/no frontmatter/, &load)
    File.binwrite(File.join(sk, "SKILL.md"), "---\nname: workflow\ndescription: \xff\n---\n")
    refused(/not UTF-8/, &load)
  end

  def test_size_limits
    own
    small = S.settings!("max_bytes" => 50, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil)
    refused(/over skills.max_bytes 50/) { S.busyyaks!(@co, types: TYPES, settings: small) }
    tight = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 5, "project" => "allow", "local_dir" => nil)
    skills = S.busyyaks!(@co, types: TYPES, settings: tight)
    refused(/over skills.max_start_bytes 5/) { S.check_selection!(skills, "lead", tight) }
  end

  def test_a_type_with_no_start_skill_is_refused
    own("workflow" => { "types" => ["lead"], "load" => "start" }, "extra" => { "types" => "all", "load" => "on_demand" })
    skills = S.busyyaks!(@co, types: TYPES, settings: SET)
    refused(/agent type worker: no `load: start` skill/) { S.check_selection!(S.select(skills, "worker"), "worker", SET) }
  end

  # --- the deployment's layer ----------------------------------------------------------------------------------------

  def test_the_deployments_local_dir_adds_its_skills_and_never_shadows
    own
    local = File.join(@co, "skills-local")
    manifest(File.join(local, "manifest.yml"), "local-repo" => { "types" => "all", "load" => "on_demand" })
    skill(local, "local-repo")
    set = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => "skills-local")
    skills = S.busyyaks!(@co, types: TYPES, settings: set)
    assert_equal [%w[workflow busyyaks], %w[local-repo deployment]], skills.map { [_1.name, _1.source] }
    manifest(File.join(local, "manifest.yml"), "workflow" => { "types" => "all", "load" => "start" })
    FileUtils.mv(File.join(local, "local-repo"), File.join(local, "workflow"))
    skill(local, "workflow")
    refused(/workflow shadows a busyyaks skill/) { S.busyyaks!(@co, types: TYPES, settings: set) }
  end

  # --- the project layer + trust -----------------------------------------------------------------------------------

  def project(skills)
    base = File.join(@repo, ".busyyaks")
    manifest(File.join(base, "skills.yml"), skills)
    skills.each_key { |n| skill(File.join(base, "skills"), n) }
  end

  def plan(trust_refusal: nil, settings: SET, type: "lead")
    S.plan!(checkout: @co, repo: @repo, type: type, types: TYPES, settings: settings, trust_refusal: trust_refusal)
  end

  def test_no_busyyaks_dir_means_only_busyyaks_skills
    own
    selected, status = plan
    assert_equal "none", status
    assert_equal %w[workflow], selected.map(&:name)
  end

  def test_a_trusted_projects_skills_load_after_busyyaks_and_for_their_types
    own
    project("deploy" => { "types" => ["lead"], "load" => "start" }, "notes" => { "types" => "all", "load" => "on_demand" })
    selected, status = plan
    assert_equal "loaded", status
    assert_equal [%w[workflow busyyaks], %w[deploy project], %w[notes project]], selected.map { [_1.name, _1.source] }
    selected, status = plan(type: "team")
    assert_equal "loaded", status
    assert_equal %w[workflow notes], selected.map(&:name)
  end

  def test_a_project_skill_type_with_none_for_it
    own
    project("deploy" => { "types" => ["lead"], "load" => "start" })
    _selected, status = plan(type: "worker")
    assert_equal "none for worker", status
  end

  def test_an_untrusted_or_denied_project_is_left_unread
    own
    FileUtils.mkdir_p(File.join(@repo, ".busyyaks"))
    File.write(File.join(@repo, ".busyyaks/skills.yml"), "not: [valid") # never read: no refusal
    selected, status = plan(trust_refusal: "repo is not trusted")
    assert_equal "left: repo is not trusted", status
    assert_equal %w[workflow], selected.map(&:name)
    deny = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "deny", "local_dir" => nil)
    assert_equal "left: config/busyyaks.yml skills.project is deny", plan(settings: deny)[1]
  end

  def test_a_trusted_projects_bad_skills_refuse_the_launch
    own
    project("workflow" => { "types" => "all", "load" => "start" })
    refused(/workflow shadows a busyyaks skill/) { plan }
    FileUtils.rm_rf(File.join(@repo, ".busyyaks"))
    FileUtils.mkdir_p(File.join(@repo, ".busyyaks/skills"))
    refused(%r{\.busyyaks/skills.yml missing}) { plan }
  end

  # --- the stage per kind ------------------------------------------------------------------------------------------

  def staged(delivery)
    own("workflow" => { "types" => "all", "load" => "start" }, "reviewer" => { "types" => "all", "load" => "on_demand" })
    skills = S.busyyaks!(@co, types: TYPES, settings: SET)
    dest = File.join(@tmp, "stage/s1")
    [dest, S.stage!(skills, dest, delivery)]
  end

  def test_the_claude_code_stage_is_a_plugin_with_the_entry_skill
    d = S::ClaudeCode.new
    dest, receipt = staged(d)
    assert_equal %w[workflow reviewer session], receipt.map { _1[:name] }
    assert(receipt.all? { _1[:sha].match?(/\A\h{64}\z/) })
    assert_equal 0o700, File.stat(dest).mode & 0o777
    assert_equal({ "name" => "busyyaks" }, JSON.parse(File.read(File.join(dest, ".claude-plugin/plugin.json"))))
    entry = File.read(File.join(dest, "skills/session/SKILL.md"))
    assert_match(/\A---\nname: session\ndescription: /, entry)
    assert_includes entry, "## workflow (busyyaks)\n\nBody of workflow."
    assert_includes entry, "- `busyyaks:reviewer` (busyyaks): about reviewer"
    assert_match(/\A---\nname: reviewer\n/, File.read(File.join(dest, "skills/reviewer/SKILL.md")))
    assert_equal ["--plugin-dir", dest], d.extra(dest)
    assert_equal "/busyyaks:session hi", d.prompt("hi")
    assert_equal "/busyyaks:session", d.prompt(nil)
    assert_empty d.env(dest)
  end

  LAUNCH_ID = "a" * 12 # a fixed per-launch id: the names are deterministic here

  def test_the_hermes_stage_is_a_skills_dir_named_for_hermes
    d = S::Hermes.new(LAUNCH_ID)
    dest, = staged(d)
    entry = File.read(File.join(dest, "busyyaks-skills/busyyaks-session-#{LAUNCH_ID}/SKILL.md"))
    assert_match(/\A---\nname: busyyaks-session-#{LAUNCH_ID}\n/, entry)
    assert_includes entry, "`busyyaks-reviewer-#{LAUNCH_ID}`"
    workflow = File.read(File.join(dest, "busyyaks-skills/busyyaks-workflow-#{LAUNCH_ID}/SKILL.md"))
    assert_match(/\A---\nname: busyyaks-workflow-#{LAUNCH_ID}\n/, workflow)
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

  def outside(name = "secret")
    dir = File.join(@tmp, "outside")
    skill(dir, name, "PRIVATE CONTENT FROM OUTSIDE THE REPO\n")
    manifest(File.join(@tmp, "m.yml"), name => { "types" => "all", "load" => "start" })
    dir
  end

  def test_a_project_layer_link_anywhere_is_refused
    own
    out = outside
    base = File.join(@repo, ".busyyaks")
    # .busyyaks itself a link
    File.symlink(File.join(@tmp, "elsewhere"), base)
    FileUtils.mkdir_p(File.join(@tmp, "elsewhere/skills"))
    refused(%r{\.busyyaks is a symlink}) { plan }
    File.unlink(base)
    # skills.yml a link out, skills a link out
    FileUtils.mkdir_p(base)
    File.symlink(File.join(@tmp, "m.yml"), File.join(base, "skills.yml"))
    File.symlink(out, File.join(base, "skills"))
    refused(/skills.yml is a symlink/) { plan }
    File.unlink(File.join(base, "skills.yml"))
    manifest(File.join(base, "skills.yml"), "secret" => { "types" => "all", "load" => "start" })
    refused(%r{\.busyyaks/skills is a symlink}) { plan }
    File.unlink(File.join(base, "skills"))
    # a skill dir a link out, a skill file a link out
    FileUtils.mkdir_p(File.join(base, "skills"))
    File.symlink(File.join(out, "secret"), File.join(base, "skills/secret"))
    refused(%r{skills/secret is a symlink}) { plan }
    File.unlink(File.join(base, "skills/secret"))
    FileUtils.mkdir_p(File.join(base, "skills/secret"))
    File.symlink(File.join(out, "secret/SKILL.md"), File.join(base, "skills/secret/SKILL.md"))
    refused(%r{secret/SKILL.md: a skill holds regular .md files only}) { plan }
  end

  def test_a_busyyaks_or_deployment_layer_link_is_refused
    own
    out = outside("local-x")
    File.symlink(out, File.join(@co, "skills-local"))
    set = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => "skills-local")
    refused(/skills-local is a symlink/) { S.busyyaks!(@co, types: TYPES, settings: set) }
    FileUtils.mv(File.join(@co, "skills"), File.join(@tmp, "real-skills"))
    File.symlink(File.join(@tmp, "real-skills"), File.join(@co, "skills"))
    refused(%r{checkout/skills is a symlink}) { S.busyyaks!(@co, types: TYPES, settings: SET) }
  end

  def test_a_shell_inline_line_is_refused_with_file_and_line
    dir = own
    File.write(File.join(dir, "workflow/SKILL.md"),
"---\nname: workflow\ndescription: d\n---\nok\nRun !`cat ~/.ssh/id_rsa` now\n")
    refused(%r{workflow/SKILL.md:6: !`…` \(Claude Code runs it as a shell command\)}) {
 S.busyyaks!(@co, types: TYPES, settings: SET) }
    File.write(File.join(dir, "workflow/SKILL.md"), "---\nname: workflow\ndescription: d\n---\nok\n")
    File.write(File.join(dir, "workflow/more.md"), "!`id`\n")
    refused(%r{workflow/more.md:1: }) { S.busyyaks!(@co, types: TYPES, settings: SET) }
  end

  def test_the_repos_own_skills_hold_no_shell_inline
    set = S.settings!("max_bytes" => 65_536, "max_start_bytes" => 32_768, "project" => "allow", "local_dir" => nil)
    S.busyyaks!(ROOT, types: TYPES, settings: set) # refuses a !` line
    Dir.glob(File.join(ROOT, "skills{,-local}/**/*.md")).each { |f| refute_match(/!`/, File.read(f), f) }
  end

  def test_sweep_removes_only_the_stages_of_gone_sessions
    stages = File.join(@tmp, "stages")
    %w[a b c].each { FileUtils.mkdir_p(File.join(stages, _1)) }
    S.sweep(stages, %w[a c])
    assert_equal %w[a c], Dir.children(stages).sort
    assert_empty S.sweep(File.join(@tmp, "none"), [])
  end
end
