# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "tmpdir"
require "fileutils"
require "busyyaks/kanban"

class AttachmentsApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  PNG = "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b + ("\x00".b * 40)

  def app = Hanami.app

  def setup
    super
    @env = ENV.to_h.slice("ATTACHMENTS_DIR", "ATTACHMENT_MAX_BYTES", "ATTACHMENT_TYPES")
    @root = Dir.mktmpdir("api-att")
    @dir = Dir.mktmpdir("api-repo")
    @files = Dir.mktmpdir("api-files")
    ENV["ATTACHMENTS_DIR"] = @root
    ENV["ATTACHMENT_MAX_BYTES"] = "2000"
    ENV["ATTACHMENT_TYPES"] = "image/png,image/svg+xml,text/html,text/plain"
    Busyyaks::Kanban.instance_variable_set(:@policy, nil) # the policy is memoised from env at boot; this test sets its own
    store.upsert_project(slug: "g/r", path: @dir, remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
    @card = Busyyaks::Kanban.default.create(slug: "g/r", title: "T", by: "op")
    assert_equal 200, sign_in
    get "/"
    @csrf = last_response.body[/name="csrf-token" content="([^"]+)"/, 1]
  end

  def teardown
    @env.each { |k, v| ENV[k] = v }
    Busyyaks::Kanban.instance_variable_set(:@policy, nil)
    FileUtils.rm_rf([@root, @dir, @files])
    super
  end

  def upload(name, bytes, client_type: "application/octet-stream", csrf: @csrf, extra: {})
    path = File.join(@files, name)
    File.binwrite(path, bytes)
    headers = { "HTTP_ACCEPT" => "application/json" }
    headers["HTTP_X_CSRF_TOKEN"] = csrf if csrf
    file = Rack::Test::UploadedFile.new(path, client_type, true, original_filename: name)
    post "/api/cards/#{@card}/attachments", { file: file }.merge(extra), headers
    JSON.parse(last_response.body)
  end

  def test_upload_serve_delete
    j = upload("shot.png", PNG, client_type: "text/html")
    assert_equal 201, last_response.status, j.inspect
    a = j["attachment"]
    assert_equal ["shot.png", "image/png", true], a.values_at("filename", "content_type", "image"),
                 "the client's type is ignored"
    assert_equal "![shot.png](/api/attachments/#{a['id']})", a["markdown"]

    get a["url"]
    assert_equal 200, last_response.status
    assert_equal PNG, last_response.body.b
    h = last_response.headers
    assert_equal "image/png", h["Content-Type"]
    assert_equal "nosniff", h["X-Content-Type-Options"]
    assert_equal "default-src 'none'; sandbox", h["Content-Security-Policy"]
    assert_match(/\Ainline; filename="shot.png"; filename\*=UTF-8''shot.png\z/, h["Content-Disposition"])
    assert_includes h["Cache-Control"], "immutable"
    assert_equal %("#{a['sha256']}"), h["ETag"]
    get a["url"], {}, "HTTP_IF_NONE_MATCH" => h["ETag"]
    assert_equal 304, last_response.status

    get a["download_url"]
    assert_match(/\Aattachment; /, last_response.headers["Content-Disposition"])

    card = JSON.parse(get("/api/cards/#{@card}").body)["card"]
    assert_equal [a["id"]], card["attachments"].map { |x| x["id"] }
    board = JSON.parse(get("/api/projects/g/r/board").body)
    assert_equal 1, board["columns"][0]["cards"][0]["attachments"]

    delete a["url"], {}, "HTTP_X_CSRF_TOKEN" => @csrf, "HTTP_ACCEPT" => "application/json"
    assert_equal 200, last_response.status
    d = JSON.parse(last_response.body)
    assert_empty d["card"]["attachments"]
    assert_equal "deleted attachment shot.png", d["activity"].last["body"]
    get a["url"]
    assert_equal 404, last_response.status
    assert_match "was deleted", JSON.parse(last_response.body)["error"]
  end

  def test_svg_and_html_are_downloads_only
    svg = upload("i.svg", %(<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>))["attachment"]
    html = upload("r.html", "<!doctype html><script>alert(1)</script>")["attachment"]
    [svg, html].each do |a|
      refute a["image"]
      assert_equal "[#{a['filename']}](/api/attachments/#{a['id']}/download)", a["markdown"]
      get a["url"] # even the "view" URL never renders them
      h = last_response.headers
      assert_match(/\Aattachment; /, h["Content-Disposition"], a["filename"])
      assert_equal "application/octet-stream", h["Content-Type"]
      assert_equal "default-src 'none'; sandbox", h["Content-Security-Policy"]
      assert_equal "nosniff", h["X-Content-Type-Options"]
    end
  end

  def test_rfc6266_filename
    a = upload("zażółć \"q\";x.txt", "hi")["attachment"]
    get a["download_url"]
    cd = last_response.headers["Content-Disposition"]
    assert_equal %(attachment; filename="za____ _q__x.txt"; filename*=UTF-8''za%C5%BC%C3%B3%C5%82%C4%87%20%22q%22%3Bx.txt), cd
  end

  def test_refusals
    j = upload("x.png", "<html>not a png</html>")
    assert_equal 422, last_response.status
    assert_match "the bytes are text/html, the name says image/png", j["error"]
    j = upload("big.txt", "x" * 2001)
    assert_equal 413, last_response.status
    assert_match "the limit is 2000", j["error"]
    j = upload("a.exe", "MZ")
    assert_equal 422, last_response.status
    assert_match ".exe is not an allowed type", j["error"]
    post "/api/cards/#{@card}/attachments", {}, "HTTP_X_CSRF_TOKEN" => @csrf
    assert_equal 422, last_response.status
    assert_match "file is required", JSON.parse(last_response.body)["error"]
    j = upload("a.txt", "x", extra: { comment_id: "999999" })
    assert_equal [422, "no comment 999999"], [last_response.status, j["error"]]
    post "/api/cards/999999/attachments", {}, "HTTP_X_CSRF_TOKEN" => @csrf
    assert_equal 404, last_response.status
    assert_equal 0, Dir.glob(File.join(@root, "**/*")).count { |f| File.file?(f) }, "nothing refused reached the disk"
  end

  def test_csrf_required
    upload("a.txt", "x", csrf: nil)
    assert_equal 403, last_response.status
    upload("a.txt", "x", csrf: "wrong")
    assert_equal 403, last_response.status
    assert_equal 0, Dir.glob(File.join(@root, "**/*")).count { |f| File.file?(f) }
  end

  def test_sign_in_required
    a = upload("a.txt", "x")["attachment"]
    delete a["url"], {}, "HTTP_ACCEPT" => "application/json"
    assert_equal 403, last_response.status, "DELETE without the token"
    assert_nil Busyyaks::Kanban.attachments.find(a["id"])[:deleted_at]
    post "/logout"
    get a["url"]
    assert_equal 401, last_response.status
    get a["download_url"]
    assert_equal 401, last_response.status
  end

  def test_markdown_renders_attachments_only
    a = upload("s.png", PNG)["attachment"]
    f = upload("run.log", "ok")["attachment"]
    post "/api/cards/#{@card}/comment", JSON.generate(body: "#{a['markdown']} #{f['markdown']} ![x](https://evil.example/t.png)"),
         "CONTENT_TYPE" => "application/json", "HTTP_X_CSRF_TOKEN" => @csrf
    html = JSON.parse(last_response.body)["activity"].last["body_html"]
    assert_includes html, %(<img src="/api/attachments/#{a['id']}")
    assert_includes html, %(class="kb-file-chip" href="/api/attachments/#{f['id']}/download")
    refute_includes html, %(src="https://evil.example)
    assert_equal 1, html.scan("<img").size
  end
end
