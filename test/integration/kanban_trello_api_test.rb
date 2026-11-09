# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "tmpdir"
require "fileutils"
require "busyyaks/kanban"

# JSON API for the Trello-parity endpoints: labels, due/cover, checklists, comment edit/delete, markdown preview.
class KanbanTrelloApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  def app = Hanami.app
  def kb = Busyyaks::Kanban.default

  def setup
    super
    @dir = Dir.mktmpdir
    store.upsert_project(slug: "g/r", path: @dir, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    assert_equal 200, sign_in
    get "/"
    @csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
    @id = kb.create(slug: "g/r", title: "card", by: "owner@example.com", column: "todo")
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def api(verb, path, body = nil)
    headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" }
    headers["HTTP_X_CSRF_TOKEN"] = @csrf if @csrf
    send(verb, path, body && JSON.generate(body), headers)
    assert_equal "application/json", last_response.content_type.split(";").first,
                 "#{verb} #{path}: #{last_response.body[0, 200]}"
    JSON.parse(last_response.body)
  end

  def test_labels_endpoints_and_board_json
    j = api(:post, "/api/projects/g/r/labels", name: "bug", color: "red")
    assert_equal [201, "bug", "red"], [last_response.status, j["label"]["name"], j["label"]["color"]]
    lid = j["label"]["id"]
    assert_match(/already exists/, api(:post, "/api/projects/g/r/labels", name: "bug", color: "red")["error"])
    assert_equal 422, last_response.status
    assert_match(/colour must be one of/, api(:post, "/api/projects/g/r/labels", name: "x", color: "nope")["error"])
    assert_match(/unknown fields: x/, api(:post, "/api/projects/g/r/labels", name: "y", color: "red", x: 1)["error"])

    api(:patch, "/api/cards/#{@id}", labels: ["bug"])
    j = api(:patch, "/api/labels/#{lid}", name: "defect", color: "orange")
    assert_equal %w[defect orange], j["label"].values_at("name", "color")
    board = api(:get, "/api/projects/g/r/board")
    assert_equal [{ "id" => lid, "name" => "defect", "color" => "orange" }], board["labels"]
    assert_includes board["label_colors"], "teal"
    assert_equal ["defect"], board["columns"][1]["cards"][0]["labels"]
    assert_equal [], api(:delete, "/api/labels/#{lid}")["labels"]
    assert_equal [], api(:get, "/api/cards/#{@id}")["card"]["labels"]
    assert_equal "no label 999999", api(:delete, "/api/labels/999999")["error"]
    assert_equal 404, last_response.status
  end

  def test_due_cover_and_face_fields
    j = api(:patch, "/api/cards/#{@id}", due: "2026-11-05T18:00", due_done: false, cover: "blue", description: "x")
    c = j["card"]
    assert_equal [false, "blue", true, 0, 0],
                 c.values_at("due_done", "cover", "has_description", "checklist_done", "checklist_total")
    assert c["due"].start_with?("2026-11-05T18:00")
    assert_match(/due must be ISO 8601/, api(:patch, "/api/cards/#{@id}", due: "5 Nov")["error"])
    assert_match(/due_done must be true or false/, api(:patch, "/api/cards/#{@id}", due_done: "x")["error"])
    j = api(:post, "/api/projects/g/r/board", title: "with due", column: "todo", due: "2026-12-01T09:00Z")
    assert_equal 201, last_response.status
    refute_nil j["card"]["due"]
  end

  def test_checklist_lifecycle_and_convert
    j = api(:post, "/api/cards/#{@id}/checklists", title: "Ship", items: ["a **b**", "c"])
    assert_equal 201, last_response.status
    cl = j["card"]["checklists"][0]
    assert_equal ["Ship", ["a **b**", "c"], "a <strong>b</strong>"],
                 [cl["title"], cl["items"].map { |i| i["body"] }, cl["items"][0]["body_html"]]
    j = api(:post, "/api/checklists/#{cl['id']}/items", body: "d")
    assert_equal [201, 3], [last_response.status, j["card"]["checklist_total"]]
    item = j["card"]["checklists"][0]["items"][0]
    j = api(:patch, "/api/checklist-items/#{item['id']}", done: true)
    assert_equal [true, "owner@example.com"], j["card"]["checklists"][0]["items"][0].values_at("done", "done_by")
    assert_equal 1, j["card"]["checklist_done"]
    assert_equal 1, api(:get, "/api/projects/g/r/board")["columns"][1]["cards"][0]["checklist_done"]
    assert_match(/done must be true or false/, api(:patch, "/api/checklist-items/#{item['id']}", done: "x")["error"])
    assert_match(/body or done is required/, api(:patch, "/api/checklist-items/#{item['id']}", {})["error"])
    j = api(:post, "/api/checklist-items/#{item['id']}", body: "edited")
    assert_equal "edited", j["card"]["checklists"][0]["items"][0]["body"]
    j = api(:patch, "/api/checklists/#{cl['id']}", title: "Ship it")
    assert_equal "Ship it", j["card"]["checklists"][0]["title"]

    last = j["card"]["checklists"][0]["items"][2]
    j = api(:post, "/api/checklist-items/#{last['id']}/convert")
    assert_equal [201, "d", "todo"], [last_response.status, j["created"]["title"], j["created"]["column"]]
    assert_equal 2, j["card"]["checklist_total"]
    j = api(:delete, "/api/checklist-items/#{item['id']}")
    assert_equal 1, j["card"]["checklist_total"]
    j = api(:delete, "/api/checklists/#{cl['id']}")
    assert_equal [], j["card"]["checklists"]
    assert_equal "no checklist 999999", api(:post, "/api/checklists/999999/items", body: "x")["error"]
    assert_equal 404, last_response.status
    assert_equal "no checklist item 999999", api(:delete, "/api/checklist-items/999999")["error"]
  end

  def test_comment_edit_delete_author_only
    j = api(:post, "/api/cards/#{@id}/comment", body: "hi @tl_g_r\n\n```\ncode\n```")
    c = j["activity"].last
    assert_includes c["body_html"], %(<span class="mention">@tl_g_r</span>)
    assert_nil c["edited"]
    j = api(:patch, "/api/comments/#{c['id']}", body: "- one\n- two")
    e = j["activity"].find { |a| a["id"] == c["id"] }
    assert_includes e["body_html"], "<li>one</li>"
    refute_nil e["edited"]
    agent = kb.comment(@id, body: "agent says", author: "agent-a")
    assert_match(/only agent-a edits or deletes/, api(:patch, "/api/comments/#{agent}", body: "x")["error"])
    assert_equal 422, last_response.status
    assert_match(/only agent-a/, api(:delete, "/api/comments/#{agent}")["error"])
    j = api(:delete, "/api/comments/#{c['id']}")
    assert_equal 1, j["card"]["comments"]
    assert_equal "delete", j["activity"].last["kind"]
    assert_equal "no comment 999999", api(:delete, "/api/comments/999999")["error"]
    assert_equal 404, last_response.status
  end

  def test_markdown_preview_is_the_server_render
    j = api(:post, "/api/markdown", body: "**b** @me <script>x</script>\n\n- [ ] task")
    assert_includes j["html"], "<strong>b</strong>"
    assert_includes j["html"], %(<span class="mention">@me</span>)
    refute_includes j["html"], "<script>"
    assert_includes j["html"], "checkbox"
    assert_equal "a <em>b</em>", api(:post, "/api/markdown", body: "a *b*", inline: true)["html"]
    assert_match(/body must be a string/, api(:post, "/api/markdown", body: 1)["error"])
  end

  def test_mutations_need_csrf
    cid = kb.comment(@id, body: "x", author: "owner@example.com")
    @csrf = nil
    api(:delete, "/api/comments/#{cid}")
    assert_equal 403, last_response.status
    api(:post, "/api/markdown", { body: "x" })
    assert_equal 403, last_response.status
  end

  def test_assignees_include_activity_members
    kb.comment(@id, body: "x", author: "claude-3")
    assert_includes api(:get, "/api/projects/g/r/board")["assignees"], "claude-3"
  end

  def test_board_and_card_revisions_change_on_any_change
    rev = -> { api(:get, "/api/projects/g/r/board/rev")["rev"] }
    crev = -> { api(:get, "/api/cards/#{@id}/rev")["rev"] }
    b0 = rev.call
    c0 = crev.call
    assert_equal b0, rev.call, "stable when nothing changed"
    kb.comment(@id, body: "agent says **hi**", author: "agent-x")
    refute_equal c0, crev.call, "a comment changes the card rev"
    b1 = rev.call
    refute_equal b0, b1, "a comment changes the board rev (comment count)"
    kb.move(@id, column: "qa", by: "agent-x", agent: true)
    refute_equal b1, rev.call, "a move changes the board rev"
  end

  # #N in a comment: an activity on this card → in-dialog anchor; a card on this board → ?card=; PR without a repo,
  # a card on another board, or nothing → plain text. Never a GitHub PR guess.
  def test_comment_refs_resolve_against_this_card_and_board
    store.upsert_project(slug: "o/other", path: @dir, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    other = kb.create(slug: "g/r", title: "other", by: "owner@example.com")
    # card ids and activity ids are separate sequences: a far card whose id is also an activity on this card would
    # (rightly) resolve as that activity, so the bare-text case needs an id that is neither (order-dependent before):
    # a far card no activity of this card has as its id, and this card's new activity ids pushed past it
    db = Hanami.app["db.gateway"].connection
    far = kb.create(slug: "o/other", title: "far", by: "owner@example.com")
    while db[:card_activity].where(card_id: @id, id: far).any?
      far = kb.create(slug: "o/other", title: "far", by: "owner@example.com")
    end
    kb.comment(other, body: "filler", author: "agent-a") while db[:card_activity].max(:id).to_i < far
    first = kb.comment(@id, body: "table here", author: "agent-a")
    kb.comment(@id, body: "see ##{first}, card ##{other}; then ##{far}, PR #5 and #999999", author: "agent-a")
    html = api(:get, "/api/cards/#{@id}")["activity"].last["body_html"]
    assert_includes html, %(<a class="gh-ref gh-comment" href="#a-#{first}" title="activity on this card ##{first}">)
    assert_includes html, %(<a class="gh-ref gh-card" href="/projects/g/r?tab=board&amp;card=#{other}" title="card ##{other}">)
    assert_includes html, "; then ##{far}, PR #5 and #999999",
                    "another board's card (bare), a PR with no repo, no such id → text"
    refute_includes html, "/pull/"
  end

  # PR #N opens the repo the work is pushed to (pr_remote), or the handoff pr_url's repo — never origin;
  # a full PR URL and a Jenkins %252F link stay as written
  def test_pr_refs_open_the_push_remote_or_the_handoff_repo
    store.upsert_project(slug: "g/r", path: @dir, remote: "https://github.com/me/widgets.git",
                         pr_remote: "git@github.com:me/widgets_local.git", branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)

    ci = "https://ci.example.com/job/widgets_local/job/card%252F63-dev-workflow/1/"
    kb.comment(@id, body: "PR #1, pull/2, https://github.com/me/other/pull/3 and #{ci}", author: "agent-a")
    html = api(:get, "/api/cards/#{@id}")["activity"].last["body_html"]
    assert_includes html, %(href="https://github.com/me/widgets_local/pull/1")
    assert_includes html, %(href="https://github.com/me/widgets_local/pull/2")
    assert_includes html, %(href="https://github.com/me/other/pull/3")
    assert_includes html, %(href="#{ci}")
    refute_includes html, "github.com/me/widgets/pull"

    kb.db[:cards].where(id: @id).update(pr_url: "https://github.com/me/elsewhere/pull/9")
    kb.comment(@id, body: "follow-up to PR #8", author: "agent-a")
    assert_includes api(:get, "/api/cards/#{@id}")["activity"].last["body_html"], %(href="https://github.com/me/elsewhere/pull/8")
  end

end
