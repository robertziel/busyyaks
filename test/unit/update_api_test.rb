# frozen_string_literal: true

require "test_helper"
require "busyyaks/update_api"

# Settings → Updates' relay (card 536): the launcher's `update` answers as [status, body], its refusals with their status
class UpdateApiTest < Minitest::Test
  API = Busyyaks::UpdateAPI
  SHA = "a" * 40

  class Launcher
    attr_reader :seen

    def initialize(answer) = (@answer = answer)

    def update(**req)
      @seen = req
      @answer
    end
  end

  def test_status_and_check_relay_the_answer_without_ok
    l = Launcher.new({ "ok" => true, "check" => nil, "running" => false })
    assert_equal [200, { "check" => nil, "running" => false }], API.status(launcher: l)
    assert_equal({ step: "status" }, l.seen)
    API.check(launcher: l)
    assert_equal({ step: "check" }, l.seen)
  end

  def test_apply_sends_mode_and_sha_and_keeps_the_launchers_refusal_status
    l = Launcher.new({ "ok" => false, "error" => "an update is already running", "status" => 409 })
    assert_equal [409, { error: "an update is already running" }], API.apply(mode: "tags", sha: SHA, launcher: l)
    assert_equal({ step: "apply", mode: "tags", sha: SHA }, l.seen)
  end

  def test_apply_refuses_a_bad_mode_or_sha_before_asking
    l = Launcher.new({ "ok" => true })
    assert_equal 400, API.apply(mode: "nightly", sha: SHA, launcher: l).first
    assert_equal 400, API.apply(mode: "branch", sha: "abc", launcher: l).first
    assert_nil l.seen
  end

  def test_an_old_launcher_or_none_is_503
    old = Launcher.new({ "ok" => false, "error" => "unknown op" })
    assert_equal 503, API.status(launcher: old).first
    down = Object.new
    def down.update(**) = raise(Busyyaks::LauncherClient::Unavailable, "launcher socket missing")
    assert_equal [503, { error: "launcher socket missing" }], API.status(launcher: down)
  end
end
