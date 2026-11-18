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
  MP4 = "\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2".b + (0...100).map(&:chr).join.b
  WEBM = "\x1A\x45\xDF\xA3\x9F\x42\x86\x81\x01\x42\xF7\x81\x01\x42\x82\x84webm\x42\x87\x81\x04".b + ("\x00".b * 40)

  def app = Hanami.app

  def setup
    super
    @env = ENV.to_h.slice("ATTACHMENTS_DIR", "ATTACHMENT_MAX_BYTES", "ATTACHMENT_TYPES")
    @root = Dir.mktmpdir("api-att")
    @dir = Dir.mktmpdir("api-repo")
    @files = Dir.mktmpdir("api-files")
    ENV["ATTACHMENTS_DIR"] = @root
    ENV["ATTACHMENT_MAX_BYTES"] = "2000"
    ENV["ATTACHMENT_TYPES"] = "image/png,image/svg+xml,text/html,text/plain,video/mp4,video/webm"
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

  # a video is served inline (the page's <video> plays it) and answers single byte ranges, so it can seek
  def test_a_video_plays_inline_and_seeks_by_range
    a = upload("rec.mp4", MP4)["attachment"]
    assert_equal ["video/mp4", true, false], a.values_at("content_type", "video", "image")
    assert_equal "[rec.mp4](/api/attachments/#{a['id']}/download)", a["markdown"]
    get a["url"]
    h = last_response.headers
    assert_equal [200, "video/mp4", "bytes", MP4], [last_response.status, h["Content-Type"], h["Accept-Ranges"],
                                                    last_response.body.b,]
    assert_match(/\Ainline; filename="rec.mp4"/, h["Content-Disposition"])
    assert_equal "default-src 'none'; sandbox", h["Content-Security-Policy"]
    assert_equal "nosniff", h["X-Content-Type-Options"]

    size = MP4.bytesize
    { "bytes=0-9" => [0, 9], "bytes=10-" => [10, size - 1], "bytes=-5" => [size - 5, size - 1],
      "bytes=100-100000" => [100, size - 1], "bytes=-100000" => [0, size - 1], }.each do |range, (first, last)|
      get a["url"], {}, "HTTP_RANGE" => range
      assert_equal 206, last_response.status, range
      assert_equal "bytes #{first}-#{last}/#{size}", last_response.headers["Content-Range"], range
      assert_equal MP4.byteslice(first, last - first + 1), last_response.body.b, range
      assert_equal "video/mp4", last_response.headers["Content-Type"], range
    end
    ["bytes=#{size}-", "bytes=5-2", "bytes=0-1,4-5", "items=0-1", "bytes=-0", "bytes=-"].each do |range|
      get a["url"], {}, "HTTP_RANGE" => range
      assert_equal 416, last_response.status, range
      assert_equal "bytes */#{size}", last_response.headers["Content-Range"], range
      assert_match "unsatisfiable range", JSON.parse(last_response.body)["error"], range
    end

    get a["url"], {}, "HTTP_RANGE" => "bytes=0-9", "HTTP_IF_NONE_MATCH" => h["ETag"]
    assert_equal [304, ""], [last_response.status, last_response.body], "a cached copy is never re-sent in parts"

    w = upload("rec.webm", WEBM)["attachment"]
    assert_equal ["video/webm", true], w.values_at("content_type", "video")
    get w["url"]
    assert_equal "video/webm", last_response.headers["Content-Type"]
    assert_match(/\Ainline; /, last_response.headers["Content-Disposition"])
    get w["download_url"]
    assert_match(/\Aattachment; /, last_response.headers["Content-Disposition"])
  end

  # the policy refuses an empty file at upload, so a 0-byte attachment exists only if its file is emptied on disk
  def test_a_range_of_an_empty_file_is_unsatisfiable
    a = upload("rec.mp4", MP4)["attachment"]
    File.write(Dir[File.join(@root, @card.to_s, "*")].first, "")
    %w[bytes=-5 bytes=0- bytes=0-0].each do |range|
      get a["url"], {}, "HTTP_RANGE" => range
      assert_equal [416, "bytes */0"], [last_response.status, last_response.headers["Content-Range"]], range
    end
  end

  def test_the_page_csp_lets_a_video_play
    get "/"
    assert_includes last_response.headers["Content-Security-Policy"], "media-src 'self'"
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
