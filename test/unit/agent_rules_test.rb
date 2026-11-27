# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "busyyaks/agent_rules_api"
require "busyyaks/project_agent_rules_api"
require_relative "../support/writer_server"

# Settings → Agent rules: busyyaks's OWN skills layers — every global markdown a session busyyaks launches gets, per
# agent type, in the order a launch stages it — read from bin/launcher's skills_layers answer (Skills.layers_answer,
# the launch's own selection) and written through the writer service (SkillFiles). A checkout under the projects
# mount, a git repo, scanned as a project: the way the busyyaks checkout sits under PROJECTS_ROOT on a host.
class AgentRulesTest < Minitest::Test
  include DBReset

  API = Busyyaks::AgentRulesAPI
  S = Busyyaks::Skills
  F = Busyyaks::AgentRuleFiles
  ROOT = File.expand_path("../..", __dir__)
  GIT_ENV = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_AUTHOR_NAME" => "t",
              "GIT_AUTHOR_EMAIL" => "t@example.test", "GIT_COMMITTER_NAME" => "t",
              "GIT_COMMITTER_EMAIL" => "t@example.test", }.freeze
  def db = Hanami.app["db.gateway"].connection

  def setup
    super
    @root = File.realpath(Dir.mktmpdir("agent-rules"))
    @checkout = File.join(@root, "busyyaks")
    FileUtils.mkdir_p(File.join(@checkout, "skills"))
    FileUtils.cp_r(File.join(ROOT, "skills/busyyaks"), File.join(@checkout, "skills/busyyaks"))
    # a deployment's own layer (skills.local_dir) with one on-demand skill
    FileUtils.mkdir_p(File.join(@checkout, "skills-local/deploy-flow"))
    File.write(File.join(@checkout, "skills-local/deploy-flow/SKILL.md"), <<~MD)
      ---
      name: deploy-flow
      description: "This deployment's card flow. Load it on a board whose columns say so."
      ---
      # deploy-flow

      The deployment's own steps.
    MD
    git("init", "-q", "-b", "local")
    git("add", "-A")
    git("commit", "-q", "-m", "skills")
    store.upsert_project(slug: "busyyaks", path: @checkout, remote: nil, branch: "local", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    @skills = S.settings!(SKILLS_SETTINGS.merge("local_dir" => "skills-local"))
    # the writer's own read-only mount of this checkout's skills/ (compose ./skills): what tells it which repo to write
    @sock = WriterServer.start(root: @root, skills: -> { @skills }, own_skills: File.join(@checkout, "skills"),
                               checkout: @checkout)
    @projects_root = @root
  end

  def teardown
    WriterServer.stop(@sock)
    FileUtils.rm_rf(@root)
    super
  end

  def git(*args)
    out, err, st = Open3.capture3(GIT_ENV, "git", "-C", @checkout, *args)
    raise "git #{args.join(' ')}: #{err}" unless st.success?

    out
  end

  def types = Busyyaks::Kanban.config(db).agent_type_keys

  # bin/launcher's skills_layers answer, as it reaches the web (JSON: string keys)
  def layers(settings:)
    answer = S.layers_answer(checkout: @checkout, types: types, settings: @skills, projects_root: @projects_root,
                             container_root: @root)
    JSON.parse(JSON.generate({ ok: true, **answer }))
  end

  def launcher = Struct.new(:test) { def skills_layers(settings:) = test.layers(settings: settings) }.new(self)
  def show = API.show(db: db, launcher: launcher, root: @root)
  def file(body, path) = body[:files].find { _1[:path] == path } || flunk("no card for #{path}")
  def type(body, key) = body[:agent_types].find { _1[:key] == key }

  # the editor's Save: each path against the sha the page last read
  def save(texts, bases: nil)
    read = show.last
    files = texts.to_h { |p, b| [p, { "base" => bases ? bases[p] : file(read, p)[:sha], "body" => b }] }
    API.save({ "files" => files }, by: "op", db: db, launcher: launcher, root: @root)
  end

  # one launch of `type` in the checkout, as bin/launcher stages it → the entry skill's text
  def entry_skill(type)
    sel, = S.plan!(checkout: @checkout, repo: @checkout, type: type, types: types, settings: @skills,
                   trust_refusal: "not trusted")
    stage = File.join(@root, "stage-#{type}")
    S.stage!(sel, stage, S.delivery("claude_code"))
    File.read(File.join(stage, "skills/session/SKILL.md"))
  end

  LEAD = "skills/busyyaks/agents/lead.md"
  REVIEWER = "skills/busyyaks/reviewer/SKILL.md"
  CORE = "skills/busyyaks/core/SKILL.md"

  # --- the operator's words -----------------------------------------------------------------------------------------

  # "where are global markdowns for all projects? … where in web app?"
  def test_the_operator_can_read_every_global_markdown_a_lead_gets_in_the_order_a_launch_stages_it
    status, body = show
    assert_equal 200, status, body.inspect
    lead = type(body, "lead")
    assert_equal [CORE, LEAD], lead[:start]
    entry = entry_skill("lead")
    at = lead[:start].map do |p|
      text = File.read(File.join(@checkout, p)).sub(/\A---\n.*?^---\n/m, "").strip
      entry.index(text) || flunk("#{p} is not in the staged entry skill")
    end
    assert_equal at.sort, at, "the page's order is the entry skill's"
    assert_equal %w[critic design qa reviewer security deploy-flow], lead[:on_demand]
    lead[:start].each do |p|
      f = file(body, p)
      assert_equal File.size(File.join(@checkout, p)), f[:bytes]
      assert_equal "busyyaks", f[:source]
      assert_match(/<h1[ >]/, f[:html], "#{p} rendered on the server")
      refute_match(/name: core/, f[:html], "the frontmatter is not rendered as text")
    end
    assert_equal lead[:start_bytes], entry_skill_bytes("lead")
  end

  def entry_skill_bytes(type)
    sel, = S.plan!(checkout: @checkout, repo: @checkout, type: type, types: types, settings: @skills, trust_refusal: "x")
    sel.core.body.bytesize + sel.parts.sum { _1.body.bytesize }
  end

  # "Missing teamlead, reviewer?" — every agent type and every on-demand skill has its own card, nothing hidden
  def test_one_card_per_file_the_team_lead_and_the_reviewer_each_their_own
    _, body = show
    paths = body[:files].map { _1[:path] }
    assert_equal paths.uniq, paths, "one card per file"
    [CORE, LEAD, "skills/busyyaks/agents/worker.md", "skills/busyyaks/agents/team.md", REVIEWER,
     "skills-local/deploy-flow/SKILL.md",].each { assert_includes paths, _1 }
    # plain has no busyyaks file yet, and the deployment layer no agents file: each still a card, empty, to make
    plain = file(body, "skills/busyyaks/agents/plain.md")
    assert_equal [false, "busyyaks", "plain", ""], plain.values_at(:exists, :source, :type, :body)
    assert_equal "deployment", file(body, "skills-local/agents/lead.md")[:source]
    reviewer = file(body, REVIEWER)
    assert_equal %w[skill on_demand reviewer], reviewer.values_at(:kind, :load, :skill)
    assert_match(/reviewer agent's brief/, reviewer[:description])
    assert_equal "deployment", file(body, "skills-local/deploy-flow/SKILL.md")[:source]
    assert_equal({ "lead" => nil, "worker" => "lead", "team" => "lead", "plain" => nil },
                 body[:agent_types].to_h { [_1[:key], _1[:under]] })
    assert_equal [true], body[:agent_types].select { _1[:key] == "plain" }.map { _1[:standalone] }
  end

  def test_the_operator_edits_the_team_leads_global_rules_in_the_web
    text = "#{File.read(File.join(@checkout, LEAD))}\n- GLOBAL-LEAD: one card at a time.\n"
    status, body = save({ LEAD => text })
    assert_equal 200, status, body.inspect
    assert_equal text, File.read(File.join(@checkout, LEAD))
    assert_includes entry_skill("lead"), "GLOBAL-LEAD: one card at a time."
    refute_includes entry_skill("worker"), "GLOBAL-LEAD"
    # tracked in the busyyaks repo: an uncommitted change, never a commit
    assert_equal "modified", file(body, LEAD)[:git]
    assert_equal "committed", file(body, CORE)[:git]
    assert_equal 1, git("rev-list", "--count", "HEAD").to_i
  end

  def test_the_reviewer_skill_is_editable_and_its_frontmatter_stays_valid
    old = File.read(File.join(@checkout, REVIEWER))
    status, body = save({ REVIEWER => old.sub("name: reviewer", "name: critic") })
    assert_equal 422, status
    assert_match(/not written: skills\/busyyaks\/reviewer\/SKILL.md: name "critic" must be its dir's reviewer/, body["error"])
    assert_equal old, File.read(File.join(@checkout, REVIEWER)), "nothing written"
    status, body = save({ REVIEWER => old.sub(/\A---\n.*?^---\n/m, "") })
    assert_equal 422, status
    assert_match(/no frontmatter/, body["error"])
    status, = save({ REVIEWER => "#{old}\n- RESOLVED only by the reviewer.\n" })
    assert_equal 200, status
    assert_includes File.read(File.join(@checkout, REVIEWER)), "RESOLVED only by the reviewer."
  end

  def test_the_core_skill_every_session_gets_is_editable_and_never_removed
    status, = save({ CORE => "#{File.read(File.join(@checkout, CORE))}\nCORE-RULE\n" })
    assert_equal 200, status
    %w[lead worker team plain].each { assert_includes entry_skill(_1), "CORE-RULE" }
    status, body = save({ CORE => nil })
    assert_equal 422, status
    assert_match(/cannot be removed/, body["error"])
  end

  def test_a_missing_agent_file_is_made_and_removed_from_the_web
    plain = "skills/busyyaks/agents/plain.md"
    status, body = save({ plain => "PLAIN-RULE\n" }, bases: { plain => nil })
    assert_equal 200, status, body.inspect
    assert_includes entry_skill("plain"), "## Agent type plain (busyyaks)\n\nPLAIN-RULE"
    assert_equal "untracked", file(body, plain)[:git]
    status, = save({ plain => nil })
    assert_equal 200, status
    refute File.exist?(File.join(@checkout, plain))
    deployment = "skills-local/agents/lead.md"
    status, = save({ deployment => "DEPLOY-LEAD\n" }, bases: { deployment => nil })
    assert_equal 200, status
    assert_match(/## Agent type lead \(busyyaks\).*## Agent type lead \(deployment\)\n\nDEPLOY-LEAD/m, entry_skill("lead"))
  end

  def test_a_global_change_over_a_types_launch_budget_is_refused_and_nothing_is_written
    room = type(show.last, "lead")[:budget]
    status, body = save({ LEAD => "#{File.read(File.join(@checkout, LEAD))}#{'x' * (room + 1)}\n" })
    assert_equal 422, status
    assert_match(/agent type lead: core \+ agents\/lead.md are \d+ bytes, over skills.max_start_bytes 32768/, body["error"])
    assert_equal "committed", file(show.last, LEAD)[:git]
  end

  def test_a_shell_line_is_refused_verbatim
    status, body = save({ LEAD => "Run !`rm -rf /`\n" })
    assert_equal 422, status
    assert_match(/skills\/busyyaks\/agents\/lead.md:1: !`…` \(Claude Code runs it as a shell command\)/, body["error"])
  end

  def test_a_file_changed_on_disk_since_the_editor_read_it_is_a_conflict
    base = file(show.last, LEAD)[:sha]
    File.write(File.join(@checkout, LEAD), "edited by hand\n")
    status, body = save({ LEAD => "from the web\n" }, bases: { LEAD => base })
    assert_equal 409, status
    assert_match(/changed on disk since the editor read it/, body["error"])
    assert_equal "edited by hand\n", File.read(File.join(@checkout, LEAD))
  end

  def test_a_crlf_file_keeps_its_line_ends
    File.binwrite(File.join(@checkout, LEAD), "# Lead\r\n\r\n- one\r\n")
    f = file(show.last, LEAD)
    assert_equal ["crlf", "# Lead\n\n- one\n"], f.values_at(:eol, :body)
    assert_equal 200, save({ LEAD => "# Lead\n\n- two\n" }).first
    assert_equal "# Lead\r\n\r\n- two\r\n", File.binread(File.join(@checkout, LEAD))
  end

  def test_only_files_of_the_skills_layers_are_written
    %w[config/busyyaks.yml ../outside.md skills/busyyaks/agents/nobody.md skills/busyyaks/core/NEW.md].each do |p|
      status, body = save({ p => "x\n" }, bases: { p => nil })
      assert_equal 422, status, p
      assert_match(/not a file of busyyaks's skills layers/, body["error"])
    end
  end

  # the critic: "any scanned repo carrying skills/busyyaks/core/SKILL.md (a clone/fork) is writable" — the writer finds
  # the checkout itself (the repo whose skills/ IS its own mount), never from the request: a fork under the projects,
  # scanned, with the same files, is never written, whatever the request names
  def test_a_clone_of_busyyaks_under_the_projects_is_never_written_only_the_checkout_itself
    fork = File.join(@root, "aaa-fork")
    FileUtils.mkdir_p(fork)
    FileUtils.cp_r(File.join(@checkout, "skills"), File.join(fork, "skills"))
    store.upsert_project(slug: "aaa-fork", path: fork, remote: nil, branch: "local", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    before = File.read(File.join(fork, LEAD))
    sha = file(show.last, LEAD)[:sha]
    req = { op: "skills_save", checkout: fork, files: { LEAD => { "base" => sha, "body" => "MINE\n" } }, by: "op" }
    status, = Busyyaks::WriterClient.call(req)
    assert_equal 200, status
    assert_equal "MINE\n", File.read(File.join(@checkout, LEAD)), "the checkout itself"
    assert_equal before, File.read(File.join(fork, LEAD)), "the fork the request named: untouched"
    # the checkout not scanned (not under PROJECTS_ROOT): refused, the fork still never written
    db[:projects].where(slug: "busyyaks").delete
    status, body = save({ LEAD => "AGAIN\n" }, bases: { LEAD => F.sha("MINE\n") })
    assert_equal 422, status
    assert_match(/\Anot written: the busyyaks checkout is not a repo the scanner found under PROJECTS_ROOT/, body["error"])
    assert_equal before, File.read(File.join(fork, LEAD))
    assert_equal "MINE\n", File.read(File.join(@checkout, LEAD))
  end

  # the critic: growing core / agents/lead.md from the web can push a PROJECT's own agents/<type>.md over
  # max_start_bytes — every launch of that type on that project refused. The save is refused instead, naming them.
  def test_a_global_edit_that_would_refuse_a_projects_launches_is_refused_naming_the_project
    app = File.join(@root, "app")
    FileUtils.mkdir_p(File.join(app, ".busyyaks/skills/agents"))
    store.upsert_project(slug: "app", path: app, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    room = type(show.last, "lead")[:budget]
    File.write(File.join(app, ".busyyaks/skills/agents/lead.md"), "#{'p' * (room - 10)}\n")
    status, body = save({ LEAD => "#{File.read(File.join(@checkout, LEAD))}#{'g' * 100}\n" })
    assert_equal 422, status
    assert_match(/every launch of these would be refused .* — app: agent type lead: core \+ agents\/lead.md are \d+ bytes/,
                 body["error"])
    assert_match(/over skills.max_start_bytes 32768\z/, body["error"])
    assert_equal "committed", file(show.last, LEAD)[:git], "nothing written"
    # the worker's file is no project's concern: still saved
    assert_equal 200, save({ "skills/busyyaks/agents/worker.md" => "# Worker\n\nshorter\n" }).first
    # a project already over is not this save's doing
    File.write(File.join(app, ".busyyaks/skills/agents/lead.md"), "#{'p' * (room + 10)}\n")
    assert_equal 200, save({ LEAD => "#{File.read(File.join(@checkout, LEAD))}\n- one more\n" }).first
  end

  # the critic: a Refused from a write half way (a link that appeared) left the earlier files written — every file
  # already written is put back
  def test_a_save_that_fails_half_way_puts_back_every_file_it_wrote
    worker = "skills/busyyaks/agents/worker.md"
    olds = [LEAD, worker].to_h { [_1, File.read(File.join(@checkout, _1))] }
    real = Busyyaks::SkillFiles.method(:put)
    fail_on = ->(co, rel, text, st) { rel == worker && text&.start_with?("NEW") ? raise(Busyyaks::SkillFiles::Refused, "a link appeared") : real.call(co, rel, text, st) }
    Busyyaks::SkillFiles.stub(:put, fail_on) do
      status, body = save({ LEAD => "NEW lead\n", worker => "NEW worker\n" })
      assert_equal 422, status
      assert_match(/not written \(a link appeared\): every file is as it was/, body["error"])
    end
    olds.each { |p, t| assert_equal t, File.read(File.join(@checkout, p)), p }
  end

  def test_a_checkout_the_writer_cannot_reach_is_refused_saying_how_to_fix_it
    @projects_root = File.realpath(Dir.mktmpdir("other-root"))
    status, body = show
    assert_equal 200, status
    assert_nil body.dig(:checkout, :mount)
    assert_match(/is not under PROJECTS_ROOT .*: the writer service cannot write it — edit the files in the checkout/,
                 body[:git_error])
  ensure
    FileUtils.rm_rf(@projects_root) if @projects_root != @root
  end

  def test_the_launcher_down_or_too_old_is_a_503_that_says_restart_it
    down = Object.new
    def down.skills_layers(**) = raise(Busyyaks::LauncherClient::Unavailable, "launcher not reachable at /x: Errno::ENOENT")
    assert_equal [503, { error: "launcher not reachable at /x: Errno::ENOENT" }], API.show(db: db, launcher: down)
    old = Object.new
    def old.skills_layers(**) = { "ok" => false, "error" => "unknown op" }
    assert_equal [503, { error: "launcher protocol error (unknown op): restart it (deploy/install-launcher.sh)" }],
                 API.show(db: db, launcher: old)
    bad = Object.new
    def bad.skills_layers(**) = { "ok" => false, "status" => 422, "error" => "skills: core missing" }
    assert_equal [422, { error: "skills: core missing" }], API.show(db: db, launcher: bad)
  end

  # the project page's Settings tab shows the layers its files add to: the same view
  def test_the_project_tab_shows_the_global_layers_each_type_inherits
    proj = Busyyaks::ProjectAgentRulesAPI
    Busyyaks::LauncherClient.stub(:skills_layers, ->(settings:) { layers(settings: settings) }) do
      none = { "ok" => true, "project_skills" => "none", "budget" => {}, "checkout" => true }
      Busyyaks::LauncherClient.stub(:project_skills, ->(**) { none }) do
        _, body = proj.show("busyyaks", db: db, skills: @skills, root: @root)
        assert_nil body[:global_error]
        lead = body[:global][:agent_types].find { _1[:key] == "lead" }
        assert_equal [CORE, LEAD], lead[:start]
        assert_match(/<h1 id="lead">Lead/, body[:global][:files].find { _1[:path] == LEAD }[:html])
        assert_equal({ key: "lead", label: body[:types].first[:label], under: nil, takes: %w[queued working review gate],
                       standalone: false, }, body[:types].first)
      end
    end
  end

  # an old `/.busyyaks/` exclude line hid a repo's committed .busyyaks/skills from git ("ignored by git"): the writer
  # replaces it on every sync, and before every agent-rules save — not only when workflow.yml is written
  def test_the_writer_replaces_the_old_busyyaks_exclude_line_on_every_sync_and_every_rules_save
    exclude = File.join(@checkout, ".git/info/exclude")
    writer = WriterServer.writer(root: @root, skills: -> { @skills }, checkout: @checkout)
    project = db[:projects].where(slug: "busyyaks").first
    writer.sync(project)
    File.write(exclude, "/.busyyaks/\n")
    assert_equal "unchanged", writer.sync(project)
    assert_equal ["/.busyyaks/workflow.yml"], File.read(exclude).lines.map(&:strip)
    File.write(exclude, "/.busyyaks/\n")
    status, body = writer.agent_rules("busyyaks", { "agents/lead.md" => { "base" => nil, "body" => "P\n" } }, by: "op")
    assert_equal 200, status, body.inspect
    assert_equal ["/.busyyaks/workflow.yml"], File.read(exclude).lines.map(&:strip)
    assert_equal({ "agents/lead.md" => "untracked" },
                 F.git_states(project, *F.read(project, types: types, settings: @skills), root: @root)
                   .slice("agents/lead.md"))
  end

  # the critic: a byte that is not UTF-8 in .git/info/exclude raised on every pass, and stopped the writer's sync at
  # that repo — the file is read as bytes (kept as they are), and one repo's failure never stops the pass
  def test_a_strange_byte_in_a_repos_exclude_file_never_stops_the_writers_sync
    exclude = File.join(@checkout, ".git/info/exclude")
    File.binwrite(exclude, "caf\xE9-notes\n/.busyyaks/\n".b)
    writer = WriterServer.writer(root: @root, skills: -> { @skills }, checkout: @checkout)
    done = writer.sync_all
    refute_match(/refused/, done.fetch("busyyaks"))
    assert_equal "caf\xE9-notes\n/.busyyaks/workflow.yml\n".b, File.binread(exclude)
    # any other failure of one repo: recorded on it, the pass goes on to the next
    other = File.join(@root, "zzz")
    FileUtils.mkdir_p(other)
    WriterServer.git_init(other)
    store.upsert_project(slug: "zzz", path: other, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    real = Busyyaks::WorkflowFiles.method(:read_bytes)
    boom = ->(p) { p[:slug] == "busyyaks" ? raise(ArgumentError, "invalid byte sequence") : real.call(p) }
    Busyyaks::WorkflowFiles.stub(:read_bytes, boom) do
      done = writer.sync_all
      assert_equal "refused: ArgumentError: invalid byte sequence", done.fetch("busyyaks")
      assert_equal "exported", done.fetch("zzz"), "the next repo is synced"
    end
  end
end
