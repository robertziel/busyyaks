# frozen_string_literal: true

require "test_helper"
require "rack/test"
require "open3"
require "busyyaks/qa_cookie"

# bin/qa-cookie: a signed-in cookie for browser QA with no email in the command.
class QaCookieTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods

  def app = Hanami.app

  def setup
    super
    store.upsert_project(slug: "g/r", path: Dir.mktmpdir("qa-repo"), remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
  end

  def board_with(cookie)
    header "Cookie", cookie
    header "Accept", "application/json"
    get "/api/projects/g/r/board"
    last_response.status
  end

  def test_minted_cookie_signs_in_as_the_providers_qa_identity
    cookie = Busyyaks::QaCookie.mint
    assert_match(/\Arack\.session=\S+\z/, cookie)
    assert_equal 200, board_with(cookie)
  end

  def test_cookie_for_an_email_outside_allowed_emails_is_refused
    assert_raises(ArgumentError) { Busyyaks::QaCookie.mint("intruder@example.com") }
    assert_equal 401, board_with(Busyyaks::QaCookie.sign("intruder@example.com"))
  end

  def test_script_takes_no_arguments_and_prints_the_cookie
    root = Hanami.app.root.to_s
    out, status = Open3.capture2e("bin/qa-cookie", chdir: root)
    assert status.success?, out
    assert_equal 200, board_with(out.strip)

    out, status = Open3.capture2e("bin/qa-cookie", "owner@example.com", chdir: root)
    refute status.success?
    assert_includes out, "no arguments"
  end

  def test_provider_none_needs_no_cookie
    Busyyaks::Auth.use(Busyyaks::Auth::None.new(Busyyaks::Auth::None::OPT_IN)) do
      e = assert_raises(Busyyaks::Auth::Invalid) { Busyyaks::QaCookie.mint }
      assert_includes e.message, "no cookie is needed"
    end
  end
end
