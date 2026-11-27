# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "minitest/mock"
require "busyyaks/writer_client"
require_relative "../support/writer_server"

# card #429: a project's workflow lives in <repo>/.busyyaks/workflow.yml, git-ignored, written and applied by the writer
# service. Each case drives the writer's sync or its socket the way bin/writer and the web do.
class WorkflowFilesTest < Minitest::Test
  include DBReset

  WF = Busyyaks::WorkflowFiles
  GIT_ENV = { "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_AUTHOR_NAME" => "A",
              "GIT_AUTHOR_EMAIL" => "a@x.io", "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@x.io", }.freeze

  def setup
    super
    @root = File.realpath(Dir.mktmpdir("wf"))
    @dir = File.join(@root, "r")
    FileUtils.mkdir_p(@dir)
    WriterServer.git_init(@dir)
    store.upsert_project(slug: "g/r", path: @dir, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    @now = 1_000
    @w = WriterServer.writer(root: @root, clock: -> { @now })
  end

  def teardown
    FileUtils.rm_rf(@root)
    super
  end

  def db = Hanami.app["db.gateway"].connection
  def project = db[:projects].where(slug: "g/r").first
  def file = File.join(@dir, ".busyyaks/workflow.yml")
  def doc = YAML.safe_load_file(file)
  def kb = Busyyaks::Kanban.store(db)
  def row = WF.status(db, "g/r")

  def git(*args)
    out, err, st = Open3.capture3(GIT_ENV, "git", "-C", @dir, *args)
    raise "git #{args.join(' ')}: #{err}" unless st.success?

    out
  end

  def edit!
    d = doc
    yield d
    File.write(file, d.to_yaml)
  end

  def test_a_project_without_a_file_gets_its_board_written_git_ignored
    assert_equal "exported", @w.sync(project)
    assert_equal kb.board_of("g/r").to_h, doc
    assert_match(/\A# busyyaks workflow/, File.read(file))
    assert_includes File.read(File.join(@dir, ".git/info/exclude")).lines.map(&:strip), "/.busyyaks/workflow.yml"
    assert_equal "", git("status", "--porcelain", "--ignored=no"), "git sees nothing new"
    assert_equal [WF.sha(File.binread(file)), @now, nil], row.values_at(:applied_sha, :applied_at, :error)
    assert_equal "unchanged", @w.sync(project)
    excl = File.read(File.join(@dir, ".git/info/exclude"))
    @w.sync(project)
    assert_equal excl, File.read(File.join(@dir, ".git/info/exclude")), "the rule is added once"
  end

  def test_a_hand_edit_is_applied_and_a_refused_one_shown_until_fixed
    @w.sync(project)
    edit! { |d| d["columns"].find { |c| c["key"] == "qa" }["label"] = "Code review" }
    @now = 2_000
    assert_equal "applied", @w.sync(project)
    assert_equal "Code review", kb.board_of("g/r").label("qa")
    assert_equal WF::AUTHOR, db[:boards].where(project_slug: "g/r").get(:updated_by)

    kb.create(slug: "g/r", title: "held", column: "qa", by: "owner@example.com")
    edit! do |d|
      d["columns"].reject! { |c| c["key"] == "qa" }
      d["transitions"].reject! { |t| [t["to"], *Array(t["from"])].include?("qa") }
    end
    @now = 3_000
    out = @w.sync(project)
    assert_match(/\Arefused: cannot remove a column with cards: Code review \(qa\)/, out)
    assert_equal [3_000, 2_000], row.values_at(:error_at, :applied_at)
    assert_equal "Code review", kb.board_of("g/r").label("qa"), "the board keeps the shape last applied"
    @now = 4_000
    @w.sync(project)
    assert_equal 3_000, row[:error_at], "the same refusal keeps its time"

    File.write(file, "columns: [")
    assert_match(/refused: .*not valid YAML/, @w.sync(project))
    File.write(file, "columns: []\ntransitions: []\nextra: 1\n")
    assert_match(/unknown key extra/, @w.sync(project))
    File.write(file, "columns: []\n")
    assert_match(/missing transitions/, @w.sync(project))
    File.write(file, "- 1\n")
    assert_match(/not a mapping/, @w.sync(project))

    File.write(file, WF.dump(kb.board_of("g/r").to_h))
    assert_equal "applied", @w.sync(project)
    assert_nil row[:error]
  end

  def test_a_board_reshaped_outside_the_file_is_written_back
    @w.sync(project)
    shape = kb.board_of("g/r").to_h
    shape["columns"].find { |c| c["key"] == "backlog" }["label"] = "Ideas"
    kb.board_save("g/r", shape, by: "a migration")
    assert_equal "exported", @w.sync(project)
    assert_equal "Ideas", doc["columns"].first["label"]
  end

  # the file holds the bytes last applied, which a newer engine rule refuses (an agent way out of a parked
  # column), while that engine's migration rewrote the stored board → the stored board is written back, not refused
  def test_applied_bytes_a_newer_rule_refuses_are_replaced_by_the_migrated_board
    @w.sync(project)
    old = doc
    exit_by_agent = { "name" => "Prioritise", "from" => "backlog", "to" => "todo", "by" => "any" }
    old["transitions"] = [exit_by_agent] + old["transitions"].reject { |t| t["name"] == "Prioritise" }
    File.write(file, old.to_yaml)
    db[:workflow_files].where(project_slug: "g/r").update(applied_sha: WF.sha(File.binread(file)))
    assert_raises(AgentsKanban::Invalid) { AgentsKanban::Board.new(old, host: kb.config) }

    logs = []
    w = WriterServer.writer(root: @root, clock: -> { @now }, log: ->(line) { logs << line })
    assert_equal "exported", w.sync(project)
    assert_nil row[:error]
    assert_equal kb.board_of("g/r").to_h, doc
    prioritise = doc["transitions"].find { |t| t["name"] == "Prioritise" }
    assert_equal "operator", prioritise["by"]
    assert(logs.any? { |l| l.include?("which the engine now refuses") && l.include?("Prioritise") }, logs.inspect)
    assert_equal "unchanged", w.sync(project)

    # the same refused shape as a hand edit (a sha the writer never applied): refused, the file left as it is
    hand = "#{old.to_yaml}# a hand edit\n"
    File.write(file, hand)
    assert_match(/\Arefused: .*only the operator moves a card out of a parked column/, w.sync(project))
    assert_equal hand, File.read(file)
    assert_equal "operator", kb.board_of("g/r").to_h["transitions"].find { |t| t["name"] == "Prioritise" }["by"]
  end

  def test_a_file_git_would_keep_is_refused
    @w.sync(project)
    git("add", "-f", ".busyyaks/workflow.yml")
    edit! { |d| d["columns"].first["label"] = "X" }
    assert_match(/refused: .*tracked by git/, @w.sync(project))
    git("rm", "-q", "-f", "--cached", ".busyyaks/workflow.yml")

    FileUtils.rm_rf(File.join(@dir, ".busyyaks"))
    File.write(File.join(@dir, ".gitignore"), "!/.busyyaks/\n")
    assert_match(/refused: .gitignore's "!\/.busyyaks\/" would un-ignore/, @w.sync(project))
    refute File.exist?(file), "nothing written where git would see it"
    File.write(File.join(@dir, ".gitignore"), "!*.yml\n")
    assert_match(/refused: .*(would un-ignore|is not ignored by git)/, @w.sync(project))
    File.write(File.join(@dir, ".gitignore"), "!keep.txt\n*.log\n")
    assert_equal "exported", @w.sync(project)
    File.write(File.join(@dir, ".git/info/exclude"), "")
    File.write(File.join(@dir, ".gitignore"), "")
    FileUtils.rm_rf(File.join(@dir, ".busyyaks"))
    WF.stub(:exclude!, nil) { assert_match(/refused: .*is not ignored by git/, @w.sync(project)) }
  end

  def test_a_file_committed_after_it_was_applied_is_refused_on_the_next_pass
    @w.sync(project)
    assert_equal "unchanged", @w.sync(project)
    git("add", "-f", ".busyyaks/workflow.yml")
    assert_match(/refused: .*tracked by git/, @w.sync(project), "the same bytes, tracked now")
    assert_match(/tracked by git/, row[:error])
    git("rm", "-q", "--cached", ".busyyaks/workflow.yml")
    assert_equal "unchanged", @w.sync(project)
    assert_nil row[:error]

    File.write(File.join(@dir, ".gitignore"), "!/.busyyaks/\n")
    assert_match(/would un-ignore/, @w.sync(project), "a new negation over an applied file")
  end

  def test_an_unchanged_repo_is_not_asked_again
    @w.sync(project)
    calls = 0
    real = WF.method(:ignored!)
    WF.stub(:ignored!, ->(*a, **k) { calls += 1; real.call(*a, **k) }) do
      2.times { assert_equal "unchanged", @w.sync(project) }
    end
    assert_equal 0, calls
  end

  def test_an_editor_save_over_a_refused_file_says_how_to_get_out
    @w.sync(project)
    File.write(file, "columns: [\n  - broken")
    status, body = @w.save("g/r", kb.board_of("g/r").to_h, by: "op")
    assert_equal 422, status
    assert_match(/not saved: .*is refused \(.*not valid YAML.*\) — fix it, or delete it/, body[:error])
  end

  def test_symlinks_and_odd_git_dirs_are_refused
    out = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(out)
    File.symlink(out, File.join(@dir, ".busyyaks"))
    assert_match(/refused: .busyyaks is a symlink/, @w.sync(project))
    File.unlink(File.join(@dir, ".busyyaks"))
    FileUtils.mkdir_p(File.join(@dir, ".busyyaks"))
    File.symlink(File.join(out, "x.yml"), file)
    assert_match(/refused: .*workflow.yml is a symlink/, @w.sync(project))
    assert_empty Dir.children(out)
    File.unlink(file)
    Dir.mkdir(file)
    assert_match(/not a regular file/, @w.sync(project))
    Dir.rmdir(file)
    File.write(file, "x" * (WF::MAX_BYTES + 1))
    assert_match(/over #{WF::MAX_BYTES} bytes/, @w.sync(project))
    FileUtils.rm_rf(File.join(@dir, ".busyyaks"))
    File.write(File.join(@dir, ".busyyaks"), "")
    assert_match(/not a directory/, @w.sync(project))
    File.unlink(File.join(@dir, ".busyyaks"))

    FileUtils.mv(File.join(@dir, ".git"), File.join(@root, "r.git"))
    File.write(File.join(@dir, ".git"), "gitdir: #{File.join(@root, 'r.git')}\n")
    assert_match(/refused: .git is not a directory/, @w.sync(project))
  end

  # a board shape that drops a column the repo's .busyyaks/agents.yml maps is refused naming it (the file is
  # changed first); a shape that keeps it saves
  def test_a_save_that_drops_a_mapped_column_is_refused_naming_it
    @w.sync(project)
    File.write(File.join(@dir, ".busyyaks/agents.yml"), "columns: {qa: worker}\n")
    shape = kb.board_of("g/r").to_h
    keep = shape.merge("columns" => shape["columns"].map { |c| c["key"] == "qa" ? c.merge("label" => "Review") : c })
    assert_equal 200, @w.save("g/r", keep, by: "op")[0]
    dropped = keep.merge("columns" => keep["columns"].reject { |c| c["key"] == "qa" },
                         "transitions" => keep["transitions"].reject { |t| [t["from"], t["to"]].include?("qa") })
    status, body = @w.save("g/r", dropped, by: "op")
    assert_equal 422, status
    assert_match(%r{not saved: qa \(→ worker\) mapped in \.busyyaks/agents\.yml — change its columns}, body[:error])
    assert_equal "Review", kb.board_of("g/r").label("qa"), "nothing saved"
  end

  def test_editor_saves_write_the_file_and_the_board_together
    shape = kb.board_of("g/r").to_h
    shape["columns"].find { |c| c["key"] == "qa" }["label"] = "Review"
    status, body = @w.save("g/r", shape, by: "owner@example.com")
    assert_equal [200, "owner@example.com"], [status, body[:updated_by]]
    assert_equal "Review", doc["columns"].find { |c| c["key"] == "qa" }["label"]

    bad = shape.merge("transitions" => [{ "name" => "X", "from" => "nope", "to" => "doing", "by" => "any" }])
    assert_equal 422, @w.save("g/r", bad, by: "owner@example.com")[0]
    assert_equal "Review", doc["columns"].find { |c| c["key"] == "qa" }["label"], "a refused save leaves the file"

    edit! { |d| d["columns"].first["label"] = "Hand" }
    status, body = @w.save("g/r", shape, by: "owner@example.com")
    assert_equal 409, status
    assert_match(/changed on disk/, body[:error])
    assert_equal "Hand", kb.board_of("g/r").label("backlog"), "the hand edit is the board now"

    File.write(file, "nope: 1\n")
    status, body = @w.save("g/r", shape, by: "owner@example.com")
    assert_equal 422, status
    assert_match(/unknown key nope/, body[:error])
    File.write(file, WF.dump(kb.board_of("g/r").to_h))
    @w.sync(project)

    write = WF.method(:write!)
    hand = lambda do |p, text, expected:|
      File.write(file, "# a hand edit landing during the save\n")
      write.call(p, text, expected: expected)
    end
    WF.stub(:write!, hand) do
      status, body = @w.save("g/r", shape.merge("columns" => shape["columns"].map { |c| c.merge("label" => "Y") }),
                             by: "owner@example.com")
      assert_equal 409, status
      assert_match(/changed on disk during the write: not overwritten/, body[:error])
    end
    assert_equal "# a hand edit landing during the save\n", File.read(file), "the hand edit is kept"
    assert_equal "Hand", kb.board_of("g/r").label("backlog"), "a conflicting write rolls the save back"
    File.delete(file)
    WF.stub(:write!, hand) { assert_equal "changed", @w.sync(project) } # an export meeting a hand edit leaves it too
    assert_equal "# a hand edit landing during the save\n", File.read(file)
    File.write(file, WF.dump(kb.board_of("g/r").to_h))
    @w.sync(project)

    # the row (or the COMMIT) fails after the rename: the file is put back, the board stays — tables and file, or neither
    kept = File.read(file)
    record = @w.method(:record)
    calls = 0
    failing = lambda do |p, **f|
      calls += 1
      raise Sequel::DatabaseError, "disk I/O error" if calls == 2 # 1 = the sync's look, 2 = the save's row

      record.call(p, **f)
    end
    z = shape.merge("columns" => shape["columns"].map { |c| c.merge("label" => "Z") })
    @w.stub(:record, failing) do
      status, body = @w.save("g/r", z, by: "owner@example.com")
      assert_equal 500, status
      assert_match(/not saved: disk I.O error \(.busyyaks.workflow.yml put back as it was\)/, body[:error])
    end
    assert_equal [kept, "Hand"], [File.read(file), kb.board_of("g/r").label("backlog")]
    calls = 0
    @w.stub(:record, failing) do
      WF.stub(:write!, lambda { |p, text, expected:|
        raise Errno::EROFS if text == kept # the put-back fails

        write.call(p, text, expected: expected)
      }) do
        status, body = @w.save("g/r", z, by: "owner@example.com")
        assert_equal 504, status
        assert_match(/could not be put back.*applies the file on its next look/, body[:error])
      end
    end
    File.write(file, kept)
    @w.sync(project)
    # a hand edit lands after the rename, then the row fails: the edit is kept, never overwritten by the put-back
    calls = 0
    meanwhile = lambda do |p, **f|
      calls += 1
      if calls == 2
        File.write(file, "# edited after the rename\n")
        raise Sequel::DatabaseError, "disk I/O error"
      end
      record.call(p, **f)
    end
    @w.stub(:record, meanwhile) do
      status, body = @w.save("g/r", z, by: "owner@example.com")
      assert_equal 500, status
      assert_match(/changed on disk meanwhile: kept/, body[:error])
    end
    assert_equal "# edited after the rename\n", File.read(file)
    File.write(file, kept)
    @w.sync(project)
    # a failure before any rename (the engine's save) with a hand edit meanwhile: nothing is put back
    WF.stub(:write!, lambda { |*, **|
      File.write(file, "# edited during the engine save\n")
      raise Sequel::DatabaseError, "lock timeout"
    }) do
      assert_raises(Sequel::DatabaseError) { @w.save("g/r", z, by: "owner@example.com") }
    end
    assert_equal ["# edited during the engine save\n", "Hand"], [File.read(file), kb.board_of("g/r").label("backlog")]
    File.write(file, kept)
    @w.sync(project)

    WF.stub(:write!, ->(*) { raise Errno::ENOSPC }) do
      status, body = @w.save("g/r", shape.merge("columns" => shape["columns"].map { |c| c.merge("label" => "Z") }),
                             by: "owner@example.com")
      assert_equal 422, status
      assert_match(/No space left/, body[:error])
    end
    assert_equal "Hand", kb.board_of("g/r").label("backlog"), "a file that cannot be written rolls the save back"

    status, = @w.reset("g/r", by: "owner@example.com")
    assert_equal 200, status
    assert_equal kb.board_template.to_h, doc
    assert_equal 404, @w.save("nope", shape, by: "x")[0]
    @w.stub(:sync_one, "changed") { assert_equal 409, @w.save("g/r", shape, by: "x")[0] }

    # a hand-made file in a repo whose exclude rule is gone: the rule is written back, then the file applied
    excl = File.join(@dir, ".git/info/exclude")
    File.write(excl, File.read(excl).sub("/.busyyaks/workflow.yml\n", ""))
    edit! { |d| d["columns"].first["label"] = "Again" }
    assert_equal "applied", @w.sync(project)
    assert_includes File.read(excl).lines.map(&:strip), "/.busyyaks/workflow.yml"
  end

  def test_state_says_what_the_board_shows
    assert_equal ["the writer has not read .busyyaks/workflow.yml yet", true],
                 WF.state(db, project, now: 0, interval: 30).values_at(:error, :stale)
    @w.sync(project)
    s = WF.state(db, project, now: @now + 30, interval: 30)
    assert_equal [nil, false, Time.at(@now).utc.iso8601], s.values_at(:error, :stale, :applied_at)
    assert s[:path].start_with?("/"), s[:path]
    assert WF.state(db, project, now: @now + 91, interval: 30)[:stale]
    assert_equal "/host/projects/a/.busyyaks/workflow.yml", WF.on_host("/projects/a/.busyyaks/workflow.yml")
  end

  def test_sync_all_and_the_socket_protocol
    assert_equal({ "g/r" => "exported" }, @w.sync_all)
    db[:projects].where(slug: "g/r").update(present: false)
    assert_empty @w.sync_all
    db[:projects].where(slug: "g/r").update(present: true)
    srv = WF::Server.new(@w, nil)
    j = ->(line) { JSON.parse(srv.handle(line)) }
    assert_equal 400, j.("nope")["status"]
    assert_equal 400, j.("[1]")["status"]
    assert_equal 400, j.(JSON.generate(op: "x"))["status"]
    assert_match(/key not found/, j.(JSON.generate(op: "workflow_save", slug: "g/r"))["body"]["error"])
    shape = kb.board_of("g/r").to_h
    assert_equal 200, j.(JSON.generate(op: "workflow_save", slug: "g/r", board: shape, by: "o"))["status"]
    assert_equal 200, j.(JSON.generate(op: "workflow_reset", slug: "g/r", by: "o"))["status"]
    @w.stub(:reset, ->(*, **) { raise "boom" }) do
      _, err = capture_io { assert_equal 500, j.(JSON.generate(op: "workflow_reset", slug: "g/r", by: "o"))["status"] }
      assert_match(/boom/, err)
    end
  end

  def test_the_client_over_a_running_server
    sock = WriterServer.start(root: @root)
    status, body = Busyyaks::WriterClient.workflow_reset("g/r", by: "owner@example.com")
    assert_equal [200, "owner@example.com"], [status, body["updated_by"]]
    status, = Busyyaks::WriterClient.workflow_save("g/r", kb.board_of("g/r").to_h, by: "owner@example.com")
    assert_equal 200, status
    WriterServer.stop(sock)
    e = assert_raises(Busyyaks::WriterClient::Unavailable) { Busyyaks::WriterClient.workflow_reset("g/r", by: "o") }
    assert_match(/writer not reachable/, e.message)

    mute = UNIXServer.new(ENV.fetch("WRITER_SOCKET")) # takes the request, never answers
    e = assert_raises(Busyyaks::WriterClient::NoAnswer) { Busyyaks::WriterClient.call({ op: "x" }, timeout: 0.2) }
    assert_match(/did not answer within 0.2 s: the change may still apply/, e.message)
    # reads the request, dies without an answer (the first connection is the unanswered one above)
    gone = Thread.new { 2.times { (c = mute.accept).gets && c.close } }
    e = assert_raises(Busyyaks::WriterClient::NoAnswer) { Busyyaks::WriterClient.call({ op: "x" }, timeout: 5) }
    assert_match(/gave no answer \(JSON::ParserError\): the change may still apply/, e.message)
    gone.join
  ensure
    mute&.close
    FileUtils.rm_f(ENV.fetch("WRITER_SOCKET")) if mute
  end

  # card #477: only the workflow file is ignored — a repo commits its .busyyaks/skills; the old whole-dir line
  # (`/.busyyaks/`) is replaced the next time the writer writes the rule
  def test_only_the_workflow_file_is_ignored_and_the_old_dir_rule_is_replaced
    excl = File.join(@dir, ".git/info/exclude")
    File.write(excl, "# keep me\n/.busyyaks/\n")
    WF.exclude!(project)
    assert_equal ["# keep me", "/.busyyaks/workflow.yml"], File.read(excl).lines.map(&:strip)
    File.write(excl, "/.busyyaks/workflow.yml\n/.busyyaks/\n")
    WF.exclude!(project)
    assert_equal ["/.busyyaks/workflow.yml"], File.read(excl).lines.map(&:strip)
    @w.sync(project)
    FileUtils.mkdir_p(File.join(@dir, ".busyyaks/skills/agents"))
    File.write(File.join(@dir, ".busyyaks/skills/agents/worker.md"), "x\n")
    assert_equal "?? .busyyaks/", git("status", "--porcelain", "--ignored=no").strip, "the skills show up to commit"
    assert_equal "ignored", git("check-ignore", "-q", ".busyyaks/workflow.yml") && "ignored"
  end
end
