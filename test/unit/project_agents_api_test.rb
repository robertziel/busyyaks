# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "rack/test"
require "busyyaks/project_agents_api"
require "busyyaks/project_agent_rules_api"
require_relative "../support/writer_server"

# The project Settings tab's Agent types — GET/POST /api/projects/*slug/agents. Read by the web (the repo's
# .busyyaks/agents.yml + bin/launcher's project_agents answer), written only by the writer service (ProjectAgentsFile,
# checked against the agent settings and the board).
class ProjectAgentsApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  API = Busyyaks::ProjectAgentsAPI
  def app = Hanami.app
  def db = Hanami.app["db.gateway"].connection

  def setup
    super
    @root = File.realpath(Dir.mktmpdir("project-agents-api"))
    @repo = File.join(@root, "app")
    FileUtils.mkdir_p(@repo)
    WriterServer.git_init(@repo)
    store.upsert_project(slug: "app", path: @repo, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    @sock = WriterServer.start(root: @root, skills: -> { Busyyaks::Skills.settings!(SKILLS_SETTINGS) })
    @answer = { "ok" => true, "state" => "none", "agents" => nil, "opt_in" => [] }
  end

  def teardown
    WriterServer.stop(@sock)
    FileUtils.rm_rf(@root)
    super
  end

  def launcher(&) = Busyyaks::LauncherClient.stub(:project_agents, ->(**) { @answer }, &)
  def show = launcher { API.show("app", db: db) }
  def save(body) = launcher { API.save("app", body, by: "op", db: db) }

  def test_show_reads_the_file_the_board_and_what_the_launcher_does_with_it
    status, body = show
    assert_equal 200, status
    assert_equal [nil, nil, nil, ".busyyaks/agents.yml"], body.values_at(:text, :sha, :error, :file)
    assert_equal %w[backlog todo doing qa human_check ready merged], body[:columns].map { _1[:key] }
    assert_equal %w[worker team], body[:types].map { _1[:key] }, "the types a lead starts"
    assert_equal %w[copywriter researcher], body[:presets]
    assert_equal({ state: "none", reason: nil, agents: nil }, body[:launches])
    @answer = { "ok" => true, "state" => "left: the repo is not trusted", "agents" => nil, "opt_in" => [] }
    assert_equal ["left", "the repo is not trusted"], show.last[:launches].values_at(:state, :reason)
    @answer = { "ok" => false, "status" => 422, "error" => "agent types: unknown keys x" }
    assert_equal ["refused", "agent types: unknown keys x"], show.last[:launches].values_at(:state, :reason)
    @answer = { "ok" => false, "error" => "unknown op project_agents" }
    assert_match(/launcher protocol error .* restart it/, show.last[:launches][:reason])
    Busyyaks::LauncherClient.stub(:project_agents, ->(**) { raise Busyyaks::LauncherClient::Unavailable, "down" }) do
      assert_equal %w[unknown down], API.show("app", db: db).last[:launches].values_at(:state, :reason)
    end
    # a loaded file whose column the board no longer has: every spawn refused, said here too
    @answer = { "ok" => true, "state" => "loaded", "opt_in" => [],
                "agents" => { "use" => [], "roles" => {}, "columns" => { "gone" => "worker" } }, }
    assert_equal "refused", show.last[:launches][:state]
    assert_match(/kanban_spawn and kanban_assign_worker are refused: .*no column gone/, show.last[:launches][:reason])
    assert_equal [404, { error: "no project nope" }], launcher { API.show("nope", db: db) }
  end

  def test_save_writes_through_the_writer_and_reads_back
    status, body = save({ "base" => nil, "text" => "columns: {qa: worker}\n" })
    assert_equal 200, status, body.inspect
    assert_equal "columns: {qa: worker}\n", body[:text]
    assert_equal "columns: {qa: worker}\n", File.read(File.join(@repo, ".busyyaks/agents.yml"))
    sha = body[:sha]
    status, body = save({ "base" => nil, "text" => "columns: {}\n" })
    assert_equal 409, status
    assert_match(/changed on disk since it was read — load the newest/, body["error"])
    status, body = save({ "base" => sha, "text" => "roles: {notes: {label: Notes, like: worker}}\n",
                          "briefs" => { "notes" => "Write the notes.\n" }, })
    assert_equal 200, status, body.inspect
    assert_equal({ "notes" => true }, body[:briefs])
    # QA round 2: the role's brief is one of the Agent rules editor's files, named as a role (its own card)
    rules = Busyyaks::LauncherClient.stub(:project_skills, ->(**) { { "ok" => false, "error" => "down" } }) do
      Busyyaks::ProjectAgentRulesAPI.show("app", db: db, skills: Busyyaks::Skills.settings!(SKILLS_SETTINGS), root: @root)
    end.last
    assert_equal ["notes"], rules[:roles]
    assert_equal "Write the notes.\n", rules[:files]["agents/notes.md"][:body]
    assert_empty rules[:errors]
    # reviewer round 3: the brief saves from its card (the writer's check reads agents.yml beside the layer), and is
    # never removed while the file declares its role (every launch would be refused)
    skills = Busyyaks::Skills.settings!(SKILLS_SETTINGS)
    rule_save = lambda do |body|
      Busyyaks::LauncherClient.stub(:project_skills, ->(**) { { "ok" => false, "error" => "down" } }) do
        Busyyaks::ProjectAgentRulesAPI.save("app", { "files" => { "agents/notes.md" => body } }, by: "op", db: db,
                                                                                              skills: skills, root: @root)
      end
    end
    sha = rules[:files]["agents/notes.md"][:sha]
    status, out = rule_save.({ "base" => sha, "body" => "Write the release notes.\n" })
    assert_equal 200, status, out.inspect
    assert_equal "Write the release notes.\n", File.read(File.join(@repo, ".busyyaks/skills/agents/notes.md"))
    status, out = rule_save.({ "base" => out[:files]["agents/notes.md"][:sha], "body" => nil })
    assert_equal 422, status
    assert_match(/agents\/notes.md is the brief of role notes in .busyyaks\/agents.yml: remove the role there first/,
                 out["error"] || out[:error])
    assert File.exist?(File.join(@repo, ".busyyaks/skills/agents/notes.md")), "nothing removed"
    sha = body[:sha]
    status, body = save({ "base" => sha, "text" => "columns: {backlog: worker}\n" })
    assert_equal 422, status
    assert_match(/not written: .*backlog is a parked column/, body["error"])
    status, body = save({ "base" => sha, "text" => "columns: {}\n" })
    assert_equal 422, status
    assert_match(/not written: .*agents\/notes.md: the brief of a role this file no longer has/, body["error"])
    assert_equal [422, { error: "body must be an object {base, text, briefs}" }], save([])
    assert_equal 404, launcher { API.save("nope", {}, by: "op", db: db) }.first
    WriterServer.stop(@sock)
    assert_raises(Busyyaks::WriterClient::Unavailable) { save({ "base" => nil, "text" => "{}" }) }
  end

  def test_the_routes_answer_signed_in
    assert_equal 200, sign_in
    get "/"
    csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
    launcher do
      get "/api/projects/app/agents", {}, "HTTP_ACCEPT" => "application/json"
      assert_equal 200, last_response.status
      assert_equal "app", JSON.parse(last_response.body)["project"]
      post "/api/projects/app/agents", JSON.generate(base: nil, text: "use: [nobody]\n"),
           "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json", "HTTP_X_CSRF_TOKEN" => csrf
      assert_equal 422, last_response.status
      assert_match(/use: no agent type nobody/, JSON.parse(last_response.body)["error"])
      WriterServer.stop(@sock)
      post "/api/projects/app/agents", JSON.generate(base: nil, text: "{}"),
           "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json", "HTTP_X_CSRF_TOKEN" => csrf
      assert_equal 503, last_response.status
    end
  end

  def test_presets_are_checked_whole
    Dir.mktmpdir do |d|
      FileUtils.mkdir_p(File.join(d, "config"))
      f = File.join(d, Busyyaks::AgentPresets::FILE)
      bad = lambda do |text, pattern|
        File.write(f, text)
        e = assert_raises(Busyyaks::AgentPresets::Invalid) { Busyyaks::AgentPresets.load!(d) }
        assert_match(pattern, e.message)
      end
      good = Busyyaks::AgentPresets.load!.first
      bad.("x: 1\n", /must be \{presets:/)
      bad.(YAML.dump("presets" => [good, JSON.parse(JSON.generate(good))]), /preset copywriter is listed twice/)
      bad.(YAML.dump("presets" => [good.merge("x" => 1)]), /unknown keys x/)
      bad.(YAML.dump("presets" => [good.except("label")]), /missing keys label/)
      bad.(YAML.dump("presets" => [good.merge("key" => "Bad")]), /key must match/)
      bad.(YAML.dump("presets" => [good.merge("description" => "a\nb")]), /description must be one line/)
      bad.(YAML.dump("presets" => ["x"]), /must be a mapping/)
      bad.("presets: [\n", /agent_presets.yml/)
      FileUtils.rm_f(f)
      assert_raises(Busyyaks::AgentPresets::Invalid) { Busyyaks::AgentPresets.keys(d) }
    end
  end
end
