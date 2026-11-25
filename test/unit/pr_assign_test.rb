# frozen_string_literal: true

require "test_helper"
require "busyyaks/kanban"
require "busyyaks/pr_states"
require "open3"
require "busyyaks/github_pollers"
require "tmpdir"
require_relative "../support/wait"

# kanban_pr_assign on busyyaks's wiring — the engine's prs: port answered by PrStates::Roles from the
# project's enrolment (the scanner's projects row). The engine's own rules are tested in the vendored suite.
class PrAssignHostTest < Minitest::Test
  include DBReset
  PS = Busyyaks::PrStates
  LOCAL = "https://github.com/o/r_local/pull/5"
  PUBLIC = "https://github.com/o/r/pull/9"

  def setup
    super
    @conn = Hanami.app["db.gateway"].connection
    @conn[:projects].insert(slug: "o-r", path: "/projects/r", remote: "git@github.com:o/r_local.git",
                            pr_remote: "git@github.com:o/r_local.git", own: true, commits_window: 0, mine_window: 0,
                            dirty: 0, scanned_at: 0, local_mode: "own", local_repo: "git@github.com:o/r_local.git",
                            public_repo: "git@github.com:o/r.git", public_head: "git@github.com:o/r.git")
    @conn[:projects].insert(slug: "plain", path: "/projects/p", remote: "git@github.com:o/p.git",
                            pr_remote: "git@github.com:o/p.git", own: true, commits_window: 0, mine_window: 0, dirty: 0,
                            scanned_at: 0)
    @kb = Busyyaks::Kanban.store(@conn)
    @id = @kb.create(slug: "o-r", title: "ship", by: "lead", column: "todo")
  end

  def assign(url, role, id: @id) = @kb.assign_pr(id, url: url, role: role, by: "lead")
  def refused(url, role, id: @id) = assert_raises(AgentsKanban::Invalid) { assign(url, role, id: id) }.message
  def urls(card) = card[:metadata]["prs"].map { |p| p["url"] }

  # the kanban engine's own mirror: enrolled too, so its PRs are local / public PRs of a busyyaks card
  def enrol_engine!
    @conn[:projects].insert(slug: "o-eng", path: "/projects/eng", remote: "git@github.com:o/eng_local.git",
                            pr_remote: "git@github.com:o/eng_local.git", own: true, commits_window: 0, mine_window: 0,
                            dirty: 0, scanned_at: 0, local_mode: "own", local_repo: "git@github.com:o/eng_local.git",
                            public_repo: "https://github.com/o/eng.git", public_head: "https://github.com/o/eng.git")
  end

  def roles = PS::Roles.new(projects: ->(s) { @conn[:projects].where(slug: s).first },
                            enrolled: -> { @conn[:projects].exclude(local_mode: nil).order(:slug).all })

  def test_roles_come_from_every_enrolment_the_scanner_wrote
    assert_equal({ "local" => { repos: ["o/r_local"], required: true }, "public" => { repos: ["o/r"], required: false } },
                 roles.pr_roles({ project_slug: "o-r" }))
    enrol_engine!
    assert_equal({ "local" => { repos: %w[o/eng_local o/r_local], required: true },
                   "public" => { repos: %w[o/eng o/r], required: false }, }, roles.pr_roles({ project_slug: "o-r" }))
    assert_equal({ "pr" => { repos: ["o/p"], required: false } }, roles.pr_roles({ project_slug: "plain" }))
    @conn[:projects].where(slug: "plain").update(remote: "https://gitlab.com/o/p.git", pr_remote: nil)
    assert_equal({ repos: [], required: false, error: "the repo of plain is not on github.com (https://gitlab.com/o/p.git)" },
                 roles.pr_roles({ project_slug: "plain" })["pr"])
    e = assert_raises(AgentsKanban::Delivery::Unavailable) { roles.pr_roles({ project_slug: "gone" }) }
    assert_equal "project gone is not a scanned project", e.message
  end

  def test_a_card_holds_every_pr_of_every_repo_it_changes
    enrol_engine!
    assign(LOCAL, "local")
    assign("https://github.com/o/eng_local/pull/91", "local")
    assign("https://github.com/o/r_local/pull/6", "local")
    card = assign(PUBLIC, "public")
    assign("https://github.com/o/eng/pull/4", "public")
    card = @kb.card(@id)
    assert_equal [LOCAL, "https://github.com/o/eng_local/pull/91", "https://github.com/o/r_local/pull/6", PUBLIC,
                  "https://github.com/o/eng/pull/4",], urls(card)
    rows = PS::Flags.new(PS::Reader.new(db: @conn, stale_after: 180, wanted_for: 600),
                         enrolled: -> { @conn[:projects].exclude(local_mode: nil).all })
                    .apply([], card, @conn[:projects].where(slug: "o-r").first)
    assert_equal [["#5 r_local", "local"], ["#91 eng_local", "local"], ["#6 r_local", "local"], ["#9 r", "public"],
                  ["#4 eng", "public"],], rows.map { |l| l.values_at(:label, :group) }
    assert_equal %w[Repo Role State Assigned Read], rows.first[:detail].map { |d| d[:label] }
    assert_match(/\Alead · \d{4}-\d\d-\d\d /, rows.first[:detail][3][:value])
    assert_equal 5, @conn[:gh_pr_states].count, "every PR is polled"
  end

  def test_assign_refuses_a_role_the_host_does_not_read
    assert_match(/role "pr" is not one this project reads \(local, public\)/, refused(PUBLIC, "pr"))
    plain = @kb.create(slug: "plain", title: "p", by: "lead")
    assert_match(/role "local" is not one this project reads \(pr\)/, refused(LOCAL, "local", id: plain))
    mine = "https://github.com/o/p/pull/3"
    assert_equal [mine], urls(assign(mine, "pr", id: plain))
    assert_match(%r{a pr PR is on o/p, not on x/y}, refused("https://github.com/x/y/pull/3", "pr", id: plain))
    assert_nil @kb.card(@id)[:metadata]
  end

  def test_assign_refuses_a_pr_of_a_repo_its_role_does_not_take
    assert_match(%r{a public PR is on o/r, not on o/r_local}, refused(LOCAL, "public"))
    assert_match(%r{a local PR is on o/r_local, not on o/r}, refused(PUBLIC, "local"))
    assert_match(%r{a local PR is on o/r_local, not on o/eng_local}, refused("https://github.com/o/eng_local/pull/1", "local"),
                 "an engine PR needs the engine's enrolment")
    assign(LOCAL, "local")
    assert_equal [LOCAL, PUBLIC], urls(assign(PUBLIC, "public"))
  end

  def test_a_side_no_enrolment_can_read_refuses_with_its_reason
    @conn[:projects].where(slug: "o-r").update(public_repo: nil, public_head: nil,
                                               local_error: 'guard.upstream names remote "upstream", which has no URL')
    assert_match(/a public PR cannot be assigned on card ##{@id} now: guard.upstream names remote "upstream"/,
                 refused(PUBLIC, "public"))
    assert assign(LOCAL, "local")
  end

  def test_one_pr_assigned_to_two_cards_is_refused_naming_the_other
    assign(LOCAL, "local")
    other = @kb.create(slug: "o-r", title: "other", by: "lead")
    assert_match(/is already the local PR of card ##{@id} \(o-r\): a PR belongs to one card/,
                 refused(LOCAL, "local", id: other))
  end

  def test_unassign_takes_one_off_and_frees_it
    assign(LOCAL, "local")
    assign("https://github.com/o/r_local/pull/6", "local")
    card = @kb.unassign_pr(@id, url: LOCAL, by: "lead", reason: "opened for another card", agent: true)
    assert_equal ["https://github.com/o/r_local/pull/6"], urls(card)
    assert_equal "opened for another card", card[:metadata]["prs_removed"].first["reason"]
    other = @kb.create(slug: "o-r", title: "other", by: "lead")
    assert_equal [LOCAL], urls(assign(LOCAL, "local", id: other))
  end

  def test_a_list_that_is_not_one_of_prs_is_said_on_the_rail
    meta = { "prs" => { "local" => LOCAL } } # the pre-list shape, never read as none
    project = @conn[:projects].where(slug: "o-r").first
    rows = PS::Flags.new(PS::Reader.new(db: @conn, stale_after: 180, wanted_for: 600),
                         enrolled: -> { @conn[:projects].exclude(local_mode: nil).all })
                    .apply([], { id: 4, metadata: meta }, project)
    assert_equal ["PRs"], rows.map { |l| l[:label] }
    assert_match(/card #4 metadata prs is not a list of PRs: /, rows.first[:detail].find { |d| d[:label] == "Why" }[:value])
  end

  def test_handoff_refused_without_an_assigned_local_pr
    @kb.move(@id, column: "doing", by: "lead", agent: true)
    e = assert_raises(AgentsKanban::Denied) { @kb.move(@id, column: "qa", by: "lead", agent: true) }
    assert_match(/card ##{@id} has no local PR assigned — open the PR and kanban_pr_assign/, e.message)
    assert_equal "qa", @kb.move(@id, column: "qa", by: "operator")[:column], "the operator's drag is never refused"
    assert_equal "In progress → QA (dragged: no local PR)", @kb.activity(@id).reverse.find { |e| e[:kind] == "move" }[:body]
    @kb.move(@id, column: "doing", by: "operator")
    e = assert_raises(AgentsKanban::Invalid) { @kb.update(@id, { "metadata" => { "prs" => [{ "url" => LOCAL }] } }, by: "lead") }
    assert_match(/metadata prs is written only by kanban_pr_assign/, e.message, "no way around the checks")
    assign(LOCAL, "local")
    assert_equal "qa", @kb.move(@id, column: "qa", by: "lead", agent: true)[:column]
    plain = @kb.create(slug: "plain", title: "p", by: "lead", column: "todo")
    @kb.move(plain, column: "doing", by: "lead", agent: true)
    assert_equal "qa", @kb.move(plain, column: "qa", by: "lead", agent: true)[:column], "a plain project requires none"
  end

  # a renamed / transferred repo: GitHub's 301 is never followed; the PR row says where the repo went
  class MovedHttp
    attr_reader :requests

    def initialize(name: "o/renamed", repo_status: 200) = (@name = name; @repo_status = repo_status; @requests = [])

    def get(url, _headers)
      @requests << url
      return [301, { "location" => "https://api.github.com/repositories/42/pulls/5" }, "{}"] if url.end_with?("/pulls/5")
      body = JSON.generate("full_name" => @name, "message" => "Not Found")
      return [@repo_status, {}, body] if url.end_with?("/repositories/42")

      [404, {}, "{}"]
    end
  end

  def test_a_moved_repo_says_where_it_moved
    now = 1_000_000
    reader = PS::Reader.new(db: @conn, stale_after: 180, wanted_for: 600, clock: -> { now })
    assert_equal({ state: "checking" }, reader.lookup("o/r_local", "pr:5"))
    http = MovedHttp.new
    PS::Poller.new(db: @conn, client: Busyyaks::GithubNetwork::Client.new(token: "t", http: http), wanted_for: 600,
                   gate: Busyyaks::GithubPollers.new(db: @conn, clock: -> { now }), clock: -> { now }).run
    msg = "GitHub read failed: GitHub 301 at /repos/o/r_local/pulls/5: repo moved to o/renamed — assign the PR again " \
          "with its o/renamed URL"
    assert_equal({ error: msg }, reader.lookup("o/r_local", "pr:5"))
    assert_equal ["https://api.github.com/repos/o/r_local/pulls/5", "https://api.github.com/repositories/42"],
                 http.requests, "the Location is read for its name only, the PR never at its new address"
    client = Busyyaks::GithubNetwork::Client.new(token: "t", http: MovedHttp.new(repo_status: 404))
    e = assert_raises(Busyyaks::GithubNetwork::RepoMoved) { client.get("/repos/o/r_local/pulls/5") }
    assert_match(/moved to repository 42, whose name could not be read: GitHub 404/, e.message)
  end

  def test_a_301_with_an_unknown_location_names_it
    http = Object.new
    def http.get(_url, _headers) = [301, { "location" => "https://example.com/x" }, "{}"]
    client = Busyyaks::GithubNetwork::Client.new(token: "t", http: http)
    e = assert_raises(Busyyaks::GithubNetwork::RepoMoved) { client.get("/repos/o/r/pulls/1") }
    assert_equal 'GitHub 301 at /repos/o/r/pulls/1: the repo moved (Location "https://example.com/x")', e.message
  end

  # Two agents assign one PR to two cards at the same moment, each its own process with its own connection (like the
  # services: SQLite BEGIN IMMEDIATE · PostgreSQL advisory lock). The first holds the write lock inside its transaction
  # until the second is waiting for it; the role and one-card checks run inside the transaction, so the second sees
  # the first's PR once it commits and is refused — one wins, one is refused.
  WRITER = File.expand_path("../support/pr_assign_writer.rb", __dir__)

  def test_two_concurrent_assigns_of_one_pr_one_wins_one_is_refused
    other = @kb.create(slug: "o-r", title: "other", by: "lead")
    procs = []
    Dir.mktmpdir("pr-assign-") do |dir|
      hold = File.join(dir, "hold")
      release = File.join(dir, "release")
      spawn = lambda do |id, name, h, r|
        stdin, out, wait = Open3.popen2e(RbConfig.ruby, WRITER, id.to_s, LOCAL, name, h, r)
        stdin.close
        procs << wait
        assert_equal "ready", line(out, wait), "#{name} booted"
        [out, wait]
      end
      first = spawn.call(@id, "agent-a", hold, release)
      Wait.for("the first assign to reach its transaction", seconds: 30) { File.exist?(hold) }
      second = spawn.call(other, "agent-b", "-", "-")
      refute Wait.readable?(second[0], seconds: 1), "the second assign waits for the first writer's lock"
      File.write(release, "")
      assert_equal({ "ok" => true }, JSON.parse(line(*first)), "the first wins")
      refused = JSON.parse(line(*second))
      assert_match(/already the local PR of card ##{@id}/, refused["refused"], "the second is refused")
      assert [first, second].all? { |_, w| w.value.success? }
    end
    assert_equal [LOCAL], urls(@kb.card(@id))
    assert_nil @kb.card(other)[:metadata], "nothing written for the loser"
  ensure
    procs.each do |w|
      Process.kill("KILL", w.pid) if w.alive?
    rescue Errno::ESRCH # exited between alive? and kill
      nil
    end
  end

  private

  # the writer's next line within 60 s, or the test fails with what it printed — never hangs
  def line(out, wait)
    return out.gets.to_s.chomp if Wait.readable?(out, seconds: 60)

    Process.kill("KILL", wait.pid) if wait.alive?
    flunk "no line from the writer in 60 s"
  end
end
