# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "minitest/mock"

# Auth, allowlist, CSRF, the SPA shell and the read API (rack-test, JSON).
class WebTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods

  def app = Hanami.app

  include SignIn

  def csrf
    get "/login"
    last_response.body[CSRF, 1]
  end

  def api(verb, path, body = nil, csrf: nil)
    headers = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" }
    headers["HTTP_X_CSRF_TOKEN"] = csrf if csrf
    send(verb, path, body && JSON.generate(body), headers)
    assert_equal "application/json", last_response.content_type.split(";").first,
                 "#{verb} #{path}: #{last_response.body[0, 200]}"
    JSON.parse(last_response.body)
  end

  # the shell carries the token the SPA sends back as X-CSRF-Token
  def shell_csrf
    get "/"
    assert_equal 200, last_response.status
    last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
  end

  # the session cookie: HttpOnly, SameSite and Secure as .env says (the test env: strict, not secure — plain http)
  def test_session_cookie_flags
    get "/login"
    cookie = Array(last_response.headers["set-cookie"]).join("\n")
    assert_match(/rack\.session=/, cookie)
    assert_match(/; httponly/i, cookie)
    assert_match(/; samesite=strict/i, cookie)
    refute_match(/; secure/i, cookie)
  end

  def test_health_is_public
    get "/up"
    assert_equal 200, last_response.status
  end

  def test_pages_redirect_and_api_answers_401_when_signed_out
    %w[/ /projects /projects/x/y /reports /reports/3 /commit/abcdef1 /nope].each do |path|
      get path
      assert_equal 302, last_response.status, path
      assert_equal "/login", URI(last_response.location).path
    end
    %w[/api/today /api/today/rev /api/projects /api/reports /api/agents /api/setup].each do |path|
      j = api(:get, path)
      assert_equal 401, last_response.status, path
      assert_equal "not signed in", j["error"]
    end
    api(:post, "/api/notes", { slug: "x", body: "y" })
    assert_equal 403, last_response.status, "CSRF is checked before the session"
    api(:post, "/api/notes", { slug: "x", body: "y" }, csrf: csrf)
    assert_equal 401, last_response.status
  end

  def test_allowed_email_gets_the_shell_and_rendered_reports
    sign_in("Owner@example.com")
    store.add_report(date: Date.today.iso8601, title: "Today report", body_md: "<script>x</script>\n\n**bold**",
                     author: "claude")
    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, '<meta name="csrf-token" content="'
    assert_includes last_response.body, '<meta name="user-email" content="owner@example.com">'
    assert_match(%r{<script type="module" src="/app/assets/[^"]+\.js"></script>}, last_response.body)
    refute_includes last_response.body, "<script>x</script>"
    get "/reports/components" # any client route → the same shell
    assert_equal 200, last_response.status
    assert_includes last_response.body, '<div id="root"></div>'

    j = api(:get, "/api/today")
    assert_equal 200, last_response.status
    assert_equal "Today report", j["reports"][0]["title"]
    assert_includes j["reports"][0]["html"], "<strong>bold</strong>"
    refute_includes j["reports"][0]["html"], "<script>x</script>"
    assert_equal %w[active7 commits_today dirty prs_today repos unpushed], j["stats"].keys.sort
    assert_equal %w[lead worker team plain], j["launches"]["types"].map { |t| t["key"] }
    assert_nil j["launches"]["concurrency"]
    assert_includes j["launches"]["sessions_error"], "launcher not reachable"
    assert_includes j["launcher_error"], "launcher not reachable" # no launcher socket in this test
  end

  # the kanban.yml theme sits on :root, so the Launch bar and the Select menus portalled out of the board
  # resolve the host's tokens, not the engine's OS-scheme defaults; app.css holds no second copy
  def test_the_shell_writes_the_board_theme_onto_root
    sign_in("Owner@example.com")
    get "/"
    style = last_response.body[%r{<style>(.*?)</style>}m, 1]
    refute_nil style, "the shell has no <style>"
    Busyyaks::Kanban.config.theme.each { |name, value| assert_includes style, "#{name}: #{value};" }
    assert style.start_with?(":root {"), style
    refute_match(/--ak-/, File.read(Hanami.app.root.join("public/static/app.css")).gsub(%r{/\*.*?\*/}m, ""))
  end

  # the home page polls /api/today/rev and re-reads /api/today only when it changes
  def test_today_rev_changes_with_what_the_page_shows_not_with_every_scan
    attrs = { slug: "r", path: "/p/r", remote: nil, branch: "main", own: true, last_commit_at: 1, commits_window: 0,
              mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1, }
    store.upsert_project(attrs)
    sign_in
    first = api(:get, "/api/today/rev")
    assert_equal 200, last_response.status
    assert_equal "no-store", last_response.headers["Cache-Control"]
    assert_nil first["scan"]
    assert_equal first["rev"], api(:get, "/api/today/rev")["rev"], "stable while nothing changes"

    id = store.scan_started(100)
    store.scan_finished(id, 110, 1, nil)
    store.upsert_project(attrs.merge(scanned_at: 110))
    j = api(:get, "/api/today/rev")
    assert_equal first["rev"], j["rev"], "a scan that found nothing new is not a change"
    assert_equal({ "finished_at" => 110, "error" => nil }, j["scan"], "the last scan rides along for the label")
    store.scan_started(200)
    assert_equal 110, api(:get, "/api/today/rev")["scan"]["finished_at"], "a running scan is not reported"

    store.upsert_project(attrs.merge(dirty: 2))
    dirty = api(:get, "/api/today/rev")["rev"]
    refute_equal first["rev"], dirty, "repo state"
    store.add_report(date: Date.today.iso8601, title: "t", body_md: "b", author: "claude")
    refute_equal dirty, api(:get, "/api/today/rev")["rev"], "a new report"
  end

  def test_nested_slug_project_and_note_with_csrf
    store.upsert_project(slug: "group/same", path: "/p/group/same", remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    sign_in
    token = shell_csrf
    j = api(:get, "/api/projects/group/same")
    assert_equal 200, last_response.status
    assert_equal "group/same", j["project"]["slug"]
    assert_nil j["project"]["unpushed"]
    assert_equal [], j["notes"]

    api(:post, "/api/notes", { slug: "group/same", body: "hello *note*" })
    assert_equal 403, last_response.status, "a mutation without X-CSRF-Token is refused"
    assert_equal({ "error" => "invalid CSRF token" }, JSON.parse(last_response.body))
    sign_in # the failed CSRF check cleared the session
    token = shell_csrf

    j = api(:post, "/api/notes", { slug: "group/same", body: "hello *note*" }, csrf: token)
    assert_equal 201, last_response.status
    assert_equal "owner@example.com", j["note"]["author"]
    assert_includes j["note"]["html"], "<em>note</em>"
    assert_equal ["hello *note*"], store.notes(project_slug: "group/same").map { |n| n[:body] }

    j = api(:post, "/api/notes", { slug: "group/same", body: "  " }, csrf: token)
    assert_equal 400, last_response.status
    assert_equal "body is empty", j["error"]
    api(:post, "/api/notes", { slug: "nope", body: "x" }, csrf: token)
    assert_equal 404, last_response.status
    api(:get, "/api/projects/nope")
    assert_equal 404, last_response.status
  end

  def test_commit_redirects_to_github_and_report_has_neighbours_toc_and_sha_links
    store.upsert_project(slug: "r", path: "/p/r", remote: "git@github.com:o/r.git", branch: "main", own: true,
                         last_commit_at: Time.now.to_i, commits_window: 1, mine_window: 1, dirty: 0, unpushed: nil,
                         scanned_at: 1)
    commit = { sha: "abcdef1234567", author: "A B", email: "a@x", committed_at: Time.now.to_i, subject: "s", mine: true }
    store.replace_commits("r", [commit], 0)
    store.replace_daily("r", { Date.today.iso8601 => [3, 2] })
    a = store.add_report(date: "2026-10-31", title: "Old", body_md: "x", author: "c")
    b = store.add_report(date: "2026-11-01", title: "New", body_md: "## One\n\n## Two\n\n## Three `abcdef12`", author: "c")
    sign_in
    get "/commit/abcdef12"
    assert_equal "https://github.com/o/r/commit/abcdef1234567", last_response.location
    j = api(:get, "/api/commits/abcdef12")
    assert_equal "https://github.com/o/r/commit/abcdef1234567", j["commit"]["url"]
    assert_equal "r", j["project"]["slug"]
    api(:get, "/api/commits/0000000")
    assert_equal 404, last_response.status
    api(:get, "/api/commits/zz")
    assert_equal 400, last_response.status

    j = api(:get, "/api/reports/#{b}")
    assert_equal a, j["older"]["id"]
    assert_nil j["newer"]
    assert_equal %w[One Two], j["report"]["toc"].first(2).map { |t| t["text"] }
    assert_includes j["report"]["html"], 'class="gh-ref gh-commit" href="https://github.com/o/r/commit/abcdef1234567"'
    api(:get, "/api/reports/999")
    assert_equal 404, last_response.status

    j = api(:get, "/api/reports")
    assert_equal %w[New Old], j["reports"].map { |r| r["title"] }
    refute j["reports"][0].key?("html")

    j = api(:get, "/api/today")
    assert_equal({ Date.today.iso8601 => 2 }, j["year"])
    assert_equal 2, j["year_total"]
    assert_equal 3, j["year_all"]
    assert_equal "abcdef1234567", j["today_commits"][0]["sha"]
    assert_equal "https://github.com/o/r/commit/abcdef1234567", j["today_commits"][0]["url"]
    assert_equal ["r"], j["active_tree"].map { |n| n["project"]["slug"] }
    assert_equal Busyyaks::Config.load.window_days, j["days"].size
    assert_equal({ "day" => Date.today.iso8601, "commits" => 1, "mine" => 1, "repos" => 1, "prs" => nil }, j["days"][0],
                 "PRs never read: unknown")
    assert_equal [[], 0, nil, nil], [j["merged_prs"], j["merged_prs_total"], j["pr_status"], j["stats"]["prs_today"]]

    db = Busyyaks::GithubNetwork::Data.default.db
    db[:gh_pr_runs].insert(login: ENV.fetch("GITHUB_LOGIN"), since: (Date.today - 7).iso8601, started_at: 1, finished_at: 2,
                           ok: true, found: 1, added: 1, calls: 1)
    db[:gh_merged_prs].insert(login: ENV.fetch("GITHUB_LOGIN"), repo: "o/r", number: 5, title: "T",
                              url: "https://github.com/o/r/pull/5", merged_at: Time.now.to_i, first_seen_at: 2)
    j = api(:get, "/api/today")
    assert_equal [1, 1], [j["stats"]["prs_today"], j["days"][0]["prs"]]
    assert_equal({ "repo" => "o/r", "number" => 5, "title" => "T", "url" => "https://github.com/o/r/pull/5",
                   "merged_at" => j["merged_prs"][0]["merged_at"], "project_slug" => "r", },
                 j["merged_prs"][0], "the GitHub repo maps to the tracked project")
  end

  def test_component_gallery_renders_every_catalog_example
    sign_in
    j = api(:get, "/api/reports/components")
    assert_equal Busyyaks::ReportBlocks::CATALOG.size, j["components"].size
    j["components"].each do |c|
      assert_includes c["html"], %(class="tl tl-#{c['name']}"), c["name"]
      refute_includes c["html"], "tl-error", c["name"]
    end
    assert_includes j["inline"]["html"], "tl-pill"
  end

  def test_other_email_is_refused
    assert_equal 403, sign_in("stranger@example.com")
    assert_equal "not_allowed", JSON.parse(last_response.body)["error"]
    get "/"
    assert_equal 302, last_response.status
    api(:get, "/api/today")
    assert_equal 401, last_response.status
  end

  # the core asks the provider on every request — one that stops vouching for a session ends it at once
  def test_provider_is_asked_on_every_request
    assert_equal 200, sign_in
    api(:get, "/api/today")
    assert_equal 200, last_response.status
    p = Busyyaks::Auth.provider
    Busyyaks::Auth.use(p.class.new({ "allowed_emails" => ["other@example.com"] }, dir: p.dir)) do
      api(:get, "/api/today")
      assert_equal 401, last_response.status
      get "/"
      assert_equal "/login", URI(last_response.location).path
    end
  end

  def test_login_page_is_the_providers_and_its_scripts_load
    get "/login"
    assert_equal 200, last_response.status
    assert_includes last_response.body, '<p id="stub-login">stub sign-in</p>'
    assert_includes last_response.body, '<script src="/auth/stub-login.js" defer></script>'
    sign_in
    get "/login"
    assert_equal "/", URI(last_response.location).path, "signed in → the app"
    get "/"
    assert_includes last_response.body, '<script src="/auth/stub-app.js" defer></script>'
    assert_includes last_response.body, '<meta name="sign-out" content="/logout">'
  end

  # a deep link opened signed out (e.g. from another site under SameSite=strict) survives the sign-in: the page
  # carries itself as ?next=, the login card hands it to the provider's script, a signed-in /login goes there
  def test_a_deep_link_survives_the_sign_in
    get "/projects/acme/shop?tab=board&card=3"
    assert_equal "/login?next=%2Fprojects%2Facme%2Fshop%3Ftab%3Dboard%26card%3D3", last_response.location
    get last_response.location
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'id="auth-login" data-next="/projects/acme/shop?tab=board&amp;card=3"'
    get "/login"
    assert_includes last_response.body, 'id="auth-login" data-next="/"', "no page asked for: the app"
    sign_in
    get "/login?next=%2Fprojects%2Facme%2Fshop%3Ftab%3Dboard%26card%3D3"
    assert_equal "/projects/acme/shop?tab=board&card=3", last_response.location
  end

  # next is a path of this app or a 400 — never another host, never quietly replaced by "/"
  def test_an_unsafe_next_is_refused
    ["//evil.test/x", "https://evil.test/", "/\\evil.test", "javascript:alert(1)", "x", "/a b", "/#{'a' * 2048}",
     "/\t/evil.test", "/a\r\nX: y", "/\x00", "/a\x7f",].each do |n|
      get "/login", { "next" => n }
      assert_equal 400, last_response.status, n
      assert_match(/next must be a path of this app/, last_response.body, n)
    end
  end

  def test_provider_endpoints_and_sign_out
    post "/auth/sign-in", JSON.generate(email: "owner@example.com"), "CONTENT_TYPE" => "application/json"
    assert_equal 403, last_response.status, "CSRF applies to the provider's POSTs"
    get "/auth/nope"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "no such auth endpoint" }, JSON.parse(last_response.body))
    sign_in
    token = shell_csrf
    post "/logout", { "_csrf_token" => token }
    assert_equal "/login", URI(last_response.location).path
    api(:get, "/api/today")
    assert_equal 401, last_response.status
  end

  # provider none: no sign-in, every request is the operator; /login and /logout lead to the app
  def test_provider_none_lets_every_request_in_as_the_operator
    Busyyaks::Auth.use(Busyyaks::Auth::None.new(Busyyaks::Auth::None::OPT_IN)) do
      get "/"
      assert_equal 200, last_response.status
      assert_includes last_response.body, '<meta name="user-email" content="operator">'
      assert_includes last_response.body, '<meta name="sign-out" content="">'
      refute_includes last_response.body, "/auth/"
      j = api(:post, "/api/notes", { slug: "nope", body: "x" }, csrf: last_response.body[CSRF, 1])
      assert_equal [404, "no project nope"], [last_response.status, j["error"]], "past the gate, no session needed"
      get "/login"
      assert_equal "/", URI(last_response.location).path
      post "/logout", { "_csrf_token" => shell_csrf }
      assert_equal "/", URI(last_response.location).path
      get "/auth/sign-in"
      assert_equal 404, last_response.status
    end
  end

  # the shell says setup pending until someone finishes the hello screen; the API answers the checks and
  # the completion needs CSRF like every mutation
  def test_the_hello_screen_setup_flag_and_api
    sign_in
    get "/"
    assert_includes last_response.body, '<meta name="setup" content="pending">'
    j = api(:get, "/api/setup")
    assert_equal 200, last_response.status
    assert_nil j["completed"]
    assert_equal %w[database scanner launcher agents github], j["checks"].map { |c| c["key"] }
    assert_equal ENV.fetch("PROJECTS_ROOT"), j["projects"]["host_root"]
    api(:post, "/api/setup/complete", {})
    assert_equal 403, last_response.status, "no CSRF token"
    refute Busyyaks::SetupAPI.completed?(Hanami.app["db.gateway"].connection), "refused: nothing written"
    sign_in # a refused CSRF token ends the session
    j = api(:post, "/api/setup/complete", {}, csrf: shell_csrf)
    assert_equal [200, "owner@example.com"], [last_response.status, j["completed"]["author"]]
    get "/"
    assert_includes last_response.body, '<meta name="setup" content="done">'
  end

  def test_built_assets_are_immutable_and_static_is_public
    get "/static/app.css"
    assert_equal 200, last_response.status
    sign_in
    get "/"
    js = last_response.body[%r{src="(/app/assets/[^"]+\.js)"}, 1]
    get js
    assert_equal 200, last_response.status
    assert_equal "public, max-age=31536000, immutable", last_response.headers["cache-control"]
  end

  # an old cached app.css with the new HTML drew both logos as 22px squares — every /static file a page
  # names carries its content digest, and /static itself is revalidated on every load
  def test_pages_name_static_files_by_digest_and_static_revalidates
    digest = ->(f) { Digest::SHA256.file(File.join(Hanami.app.root, "public/static", f)).hexdigest[0, 12] }
    get "/login"
    login = last_response.body
    sign_in
    get "/"
    [login, last_response.body].each do |html|
      %w[app.css skin.js icon.svg].each { |f| assert_includes html, "/static/#{f}?v=#{digest.(f)}" }
      refute_match %r{"/static/[^"?]+"}, html, "a bare /static URL"
    end
    %w[logo-light.svg logo-dark.svg].each { |f| assert_includes login, "/static/#{f}?v=#{digest.(f)}" }
    get "/static/app.css?v=#{digest.('app.css')}"
    assert_equal 200, last_response.status
    assert_equal "no-cache", last_response.headers["cache-control"]
  end

  # card #361: the login page and the shell both carry the skins — the <meta> skin.js reads before first paint
  # (escaped into the attribute) and their <style> after app.css
  def test_pages_carry_the_skins_in_their_head
    dusk = { "key" => "dusk", "label" => "Dusk <&>", "base" => "dark", "tokens" => { "--bg" => "#101820" } }
    Busyyaks::Skins.stub(:all, Busyyaks::Skins.all + [dusk]) do
      get "/login"
      login = last_response.body
      sign_in
      get "/"
      [login, last_response.body].each do |html|
        assert_includes html, ',{&quot;key&quot;:&quot;dusk&quot;,&quot;label&quot;:&quot;Dusk &lt;&amp;&gt;&quot;,' \
                              '&quot;base&quot;:&quot;dark&quot;}]">'
        assert_includes html, %(:root[data-skin-key="dusk"] { --bg: #101820; }</style>)
        assert_includes html, ':root[data-skin="light"] { --bg: #f4f3ee;'
        assert_operator html.index('name="skins"'), :<, html.index("/static/skin.js")
        assert_operator html.index("/static/app.css"), :<, html.index('id="skins-css"')
      end
    end
  end

  def test_asset_refuses_a_missing_file
    assert_raises(ArgumentError) { Busyyaks::Action::Helpers.asset("/static/nope.css") }
    assert_raises(ArgumentError) { Busyyaks::Action::Helpers.asset("/app/x.js") }
  end
end
