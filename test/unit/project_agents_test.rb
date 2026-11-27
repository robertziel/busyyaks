# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "busyyaks/project_agents"
require "busyyaks/project_agents_file"

# A board's own agent types — <repo>/.busyyaks/agents.yml: the opt-in types it uses, its roles (a type + a
# brief), which type or role each column takes. Every value is checked whole; anything unknown is refused, never
# ignored, and nothing is ever started as something else.
class ProjectAgentsTest < Minitest::Test
  P = Busyyaks::ProjectAgents
  T = P::TypeInfo
  TYPES = {
    "lead" => T.new(key: "lead", under: nil, opt_in: false),
    "worker" => T.new(key: "worker", under: "lead", opt_in: false),
    "copywriter" => T.new(key: "copywriter", under: "lead", opt_in: true),
    "researcher" => T.new(key: "researcher", under: "lead", opt_in: true),
  }.freeze
  PRESETS = %w[copywriter researcher designer].freeze
  BOARD = { "backlog" => "parked", "todo" => "queued", "doing" => "working", "docs" => "working", "done" => "done" }.freeze

  def setup
    @repo = Dir.mktmpdir("project-agents")
  end

  def teardown
    FileUtils.rm_rf(@repo)
  end

  def parse(yaml) = P.parse!(yaml, types: TYPES, presets: PRESETS)

  def refused(pattern, &blk)
    e = assert_raises(P::Invalid, &blk)
    assert_match(pattern, e.message)
  end

  GOOD = <<~YAML
    use: [copywriter]
    roles:
      changelog: {label: Changelog writer, like: worker}
    columns:
      docs: copywriter
      todo: changelog
  YAML

  def test_a_file_says_the_opt_in_types_the_roles_and_the_columns
    a = parse(GOOD)
    assert_equal ["copywriter"], a.use
    assert_equal ["Changelog writer", "worker"], a.roles["changelog"].to_h.values_at(:label, :like)
    assert_equal "copywriter", a.for_column("docs")
    assert_equal "changelog", a.for_column("todo")
    assert_nil a.for_column("doing"), "an unmapped column: any type the board runs"
    assert_equal({ use: ["copywriter"], roles: { "changelog" => { label: "Changelog writer", like: "worker" } },
                   columns: { "docs" => "copywriter", "todo" => "changelog" }, }, a.to_h)
    assert_equal a.to_h, P.from_h(JSON.parse(JSON.generate(a.to_h))).to_h, "the launcher's answer reads back the same"
    assert_equal P::EMPTY.to_h, parse("{}").to_h, "every key optional"
  end

  def test_every_wrong_value_is_refused_naming_it
    refused(/must be a mapping of use, roles, columns/) { parse("- a\n") }
    refused(/unknown keys colums/) { parse("colums: {}\n") }
    refused(/use: no agent type designer \(opt-in types: copywriter, researcher\)/) { parse("use: [designer]\n") }
    refused(/use: worker is not an opt-in type — every board runs it already/) { parse("use: [worker]\n") }
    refused(/use lists copywriter twice/) { parse("use: [copywriter, copywriter]\n") }
    refused(/role worker: an agent type of the settings has that name/) do
      parse("roles: {worker: {label: W, like: worker}}\n")
    end
    refused(/role designer: a preset agent type has that name/) { parse("roles: {designer: {label: D, like: worker}}\n") }
    refused(/role Bad: the name must match/) { parse("roles: {Bad: {label: B, like: worker}}\n") }
    refused(/role x must be \{label, like\}/) { parse("roles: {x: {label: X}}\n") }
    refused(/role x: label must be one line/) { parse("roles: {x: {label: '', like: worker}}\n") }
    refused(/role x: like: "lead" is no agent type a lead starts/) { parse("roles: {x: {label: X, like: lead}}\n") }
    refused(/role x: like: researcher is opt-in and not under use/) { parse("roles: {x: {label: X, like: researcher}}\n") }
    refused(/columns.docs: researcher is opt-in and not under use/) { parse("columns: {docs: researcher}\n") }
    refused(/columns.docs: "nobody" is no agent type a lead starts \(worker, copywriter, researcher\)/) do
      parse("columns: {docs: nobody}\n")
    end
    refused(/agents.yml: / ) { parse("use: [\n") }
    refused(/is not UTF-8/) { parse("use: [\xff]\n".b) }
  end

  def test_a_mapped_column_is_one_of_the_boards_that_holds_work
    P.board_columns!(parse(GOOD), BOARD)
    refused(/the board has no column review \(backlog, todo, doing, docs, done\)/) do
      P.board_columns!(parse("columns: {review: worker}\n"), BOARD)
    end
    refused(/columns: backlog is a parked column — no session works a card there/) do
      P.board_columns!(parse("columns: {backlog: worker}\n"), BOARD)
    end
    refused(/done is a done column/) { P.board_columns!(parse("columns: {done: worker}\n"), BOARD) }
  end

  def write(rel, text)
    path = File.join(@repo, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def test_a_role_needs_its_brief_and_no_link_is_followed
    assert_nil P.load!(@repo, types: TYPES, presets: PRESETS), "no file: nil (the board runs as before)"
    write(P::FILE, GOOD)
    refused(%r{role changelog has no brief \.busyyaks/skills/agents/changelog\.md}) do
      P.load!(@repo, types: TYPES, presets: PRESETS)
    end
    write(".busyyaks/skills/agents/changelog.md", "Write the changelog entry.\n")
    assert_equal "changelog", P.load!(@repo, types: TYPES, presets: PRESETS).for_column("todo")
    File.write(File.join(@repo, "elsewhere.yml"), GOOD)
    FileUtils.rm_f(File.join(@repo, P::FILE))
    File.symlink(File.join(@repo, "elsewhere.yml"), File.join(@repo, P::FILE))
    refused(/symlink|link/) { P.load!(@repo, types: TYPES, presets: PRESETS) }
    # the one read: roles_of too
    assert_match(/symlink/, assert_raises(Busyyaks::Skills::Invalid) { Busyyaks::Skills.roles_of(@repo) }.message)
    FileUtils.rm_f(File.join(@repo, P::FILE))
    write(P::FILE, "#{GOOD}\n# #{'x' * P::MAX_BYTES}\n")
    refused(/over #{P::MAX_BYTES}/) { P.load!(@repo, types: TYPES, presets: PRESETS) }
    e = assert_raises(Busyyaks::Skills::Invalid) { Busyyaks::Skills.roles_of(@repo) }
    assert_match(/over #{P::MAX_BYTES}/, e.message)
    write(P::FILE, "roles: {}\n# \xff\n".b)
    e = assert_raises(Busyyaks::Skills::Invalid) { Busyyaks::Skills.roles_of(@repo) }
    assert_match(/is not UTF-8/, e.message)
  end

  def spawn(state: "loaded", agents: parse(GOOD), column: "doing", type: "worker", role: nil)
    P.spawn!(state: state, agents: agents, column: column, column_label: column.capitalize, type: type, role: role,
             opt_in: %w[copywriter researcher])
  end

  def test_the_spawn_rule
    spawn # an unmapped column, a plain type
    spawn(type: "copywriter") # an opt-in type the board uses, called for a card
    spawn(type: "worker", role: "changelog")
    spawn(column: "docs", type: "copywriter")
    spawn(column: "todo", type: "worker", role: "changelog")
    refused(/column Docs takes copywriter \(.busyyaks\/agents.yml\): kanban_spawn\(type: copywriter\)/) do
      spawn(column: "docs", type: "worker")
    end
    refused(/column Todo takes changelog .*kanban_spawn\(type: worker, role: changelog\)/) { spawn(column: "todo") }
    refused(/agent type researcher is opt-in and this board does not use it \(.*use: copywriter\)/) do
      spawn(type: "researcher")
    end
    refused(/role changelog runs as agent type worker/) { spawn(type: "copywriter", role: "changelog") }
    refused(/no role nope in .busyyaks\/agents.yml \(roles: changelog\)/) { spawn(role: "nope") }
    # no file: the plain types run, no opt-in type; a file the launcher left unread (an untrusted repo): no session is
    # started for its cards at all — never a plain worker instead of what the file names
    spawn(state: "none", agents: nil)
    refused(/opt-in and this board does not use it \(.busyyaks\/agents.yml: none\)/) do
      spawn(state: "none", agents: nil, type: "copywriter")
    end
    refused(/agents.yml is not read \(the repo is not trusted\): no session is started .* never a plain worker/) do
      spawn(state: "left: the repo is not trusted", agents: nil)
    end
    refused(/not read \(the repo is not trusted\): no card is handed to a worker/) do
      P.assign!(state: "left: the repo is not trusted", agents: nil, column: "docs", column_label: "Docs", worker: nil,
                session: "w1")
    end
  end

  def test_the_assign_rule
    a = parse(GOOD)
    assign = ->(column, worker) {
 P.assign!(state: "loaded", agents: a, column: column, column_label: column, worker: worker, session: "w1") }
    assign.("doing", nil) # unmapped: no check
    assign.("docs", { type: "copywriter", role: nil })
    assign.("todo", { type: "worker", role: "changelog" })
    refused(/column docs takes copywriter .*w1 is a worker — give it a card of its kind/) do
      assign.("docs", { type: "worker", role: nil })
    end
    refused(/column todo takes changelog .*w1's type is not recorded/) { assign.("todo", nil) }
  end

  # the writer's save (ProjectAgentsFile): checked whole against the settings + the board, briefs of new roles written
  # with it, nothing written on a refusal, a conflict when the file moved since it was read
  def test_the_writer_saves_the_file_and_new_roles_briefs_or_nothing
    f = Busyyaks::ProjectAgentsFile
    settings = Busyyaks::Skills.settings!(SKILLS_SETTINGS)
    save = ->(change) { f.write!(@repo, change, types: TYPES, presets: PRESETS, board: BOARD, settings: settings) }
    e = assert_raises(f::Refused) { save.({ "base" => nil, "text" => GOOD, "briefs" => {} }) }
    assert_match(%r{role changelog needs a brief .* written as \.busyyaks/skills/agents/changelog\.md}, e.message)
    refute File.exist?(File.join(@repo, P::FILE)), "nothing written"
    written = save.({ "base" => nil, "text" => GOOD, "briefs" => { "changelog" => "Write the entry.\n" } })
    assert_equal [".busyyaks/skills/agents/changelog.md", P::FILE], written
    assert_equal GOOD, File.read(File.join(@repo, P::FILE))
    _, sha = f.current(@repo)
    assert_raises(f::Conflict) { save.({ "base" => nil, "text" => GOOD }) }
    e = assert_raises(f::Refused) { save.({ "base" => sha, "text" => "use: [copywriter]\n" }) }
    assert_match(/agents\/changelog.md: the brief of a role this file no longer has — remove it with the role/, e.message)
    e = assert_raises(f::Refused) { save.({ "base" => sha, "text" => "columns: {backlog: worker}\n" }) }
    assert_match(/backlog is a parked column/, e.message)
    e = assert_raises(f::Refused) { save.({ "base" => sha, "text" => nil }) }
    assert_match(/roles still have briefs .*remove them with the file in this save/, e.message)
    e = assert_raises(f::Refused) { save.({ "base" => sha, "text" => GOOD, "briefs" => { "changelog" => nil } }) }
    assert_match(/briefs: changelog is a role of the new file — its brief stays/, e.message)
    e = assert_raises(f::Refused) { save.({ "base" => sha, "text" => "{}\n", "briefs" => { "lead" => nil } }) }
    assert_match(/briefs: lead is no role of the file on disk/, e.message)
    # QA round 4: a role and its brief go in ONE save (dropped from the file, its brief removed with it)
    written = save.({ "base" => sha, "text" => "use: [copywriter]\n", "briefs" => { "changelog" => nil } })
    assert_equal [P::FILE, ".busyyaks/skills/agents/changelog.md"], written
    refute File.exist?(File.join(@repo, ".busyyaks/skills/agents/changelog.md"))
    _, sha = f.current(@repo)
    save.({ "base" => sha, "text" => GOOD, "briefs" => { "changelog" => "Write the entry.\n" } })
    _, sha = f.current(@repo)
    # the file removed with its roles' briefs, in one save
    assert_equal [P::FILE, ".busyyaks/skills/agents/changelog.md"],
                 save.({ "base" => sha, "text" => nil, "briefs" => { "changelog" => nil } })
    refute File.exist?(File.join(@repo, ".busyyaks/skills/agents/changelog.md"))
    save.({ "base" => nil, "text" => "use: [copywriter]\n" })
    _, sha = f.current(@repo)
    # the file changed between the check and the rename: Conflict, the file on disk left as it was
    real = f.method(:current)
    calls = 0
    moved = lambda do |repo|
      calls += 1
      calls == 1 ? real.call(repo) : ["x", "another sha"]
    end
    f.stub(:current, moved) do
      e = assert_raises(f::Conflict) { save.({ "base" => sha, "text" => "use: []\n" }) }
      assert_match(/agents.yml changed on disk during the write: not overwritten/, e.message)
    end
    assert_equal "use: [copywriter]\n", File.read(File.join(@repo, P::FILE))
    assert_empty Dir.glob(File.join(@repo, ".busyyaks/.agents-write.*")), "no temp file left"
    assert_equal [P::FILE], save.({ "base" => sha, "text" => nil })
    refute File.exist?(File.join(@repo, P::FILE))
  end
end
