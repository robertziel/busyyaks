# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "tmpdir"
require "fileutils"

class IconsApiTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods
  include SignIn

  def app = Hanami.app

  def setup
    super
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "public"))
    File.write(File.join(@dir, "public/favicon.svg"), %(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>))
    File.symlink("/etc/hostname", File.join(@dir, "public/evil.png")) rescue nil
    store.upsert_project(slug: "g/r", path: @dir, remote: nil, branch: "main", own: true, last_commit_at: 1, commits_window: 0,
                         mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1, icon_path: "public/favicon.svg", icon_mtime: 7)
    assert_equal 200, sign_in
  end

  def teardown
    FileUtils.rm_rf(@dir)
    super
  end

  def test_serves_svg_sandboxed_and_lists_url
    get "/api/icons/g/r"
    assert_equal 200, last_response.status
    assert_equal "image/svg+xml", last_response.content_type
    assert_includes last_response.headers["Content-Security-Policy"], "sandbox"
    assert_equal "/api/icons/g/r?v=7", Busyyaks::API.icon_url(store.project("g/r"))
  end

  def test_path_outside_repo_and_missing_are_404
    kept = store.project("g/r").slice(:slug, :path, :remote, :branch, :own, :last_commit_at, :commits_window, :mine_window,
                                      :dirty, :unpushed, :scanned_at)
    store.upsert_project(**kept, icon_path: "public/evil.png", icon_mtime: 8)
    get "/api/icons/g/r"
    assert_equal 404, last_response.status
    get "/api/icons/nope"
    assert_equal 404, last_response.status
  end

  def test_terminal_url_template
    assert_equal "https://term.test/code/#s=widgets_13&sock=default", Busyyaks::API.terminal_url("widgets_13")
    assert_equal "https://term.test/code/#s=a%20b&sock=s2", Busyyaks::API.terminal_url("a b", "s2")
  end

  def test_ssh_attach_quotes_the_session_name
    assert_equal "ssh -t box tmux attach -t a\\;\\ rm", Busyyaks::API.ssh_attach("a; rm")
  end

  def test_requires_sign_in
    clear_cookies
    get "/api/icons/g/r"
    assert_equal 401, last_response.status
  end
end
