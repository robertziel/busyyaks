# frozen_string_literal: true

require "test_helper"
require "busyyaks/dashboard_url"

# The dashboard origin per docs/DEPLOY.md mode, from .env only: every card's `url` in the kanban MCP tools.
class DashboardUrlTest < Minitest::Test
  U = Busyyaks::DashboardUrl

  def test_public_host_is_the_https_origin
    env = { "PUBLIC_HOST" => "dash.example.com", "WEB_HOST_PORT" => "8080" }
    assert_equal "https://dash.example.com", U.origin(env)
    assert_equal "https://dash.example.com/projects/g/sub%20r?tab=board&card=7", U.card("g/sub r", 7, env)
  end

  def test_empty_public_host_is_localhost_mode
    assert_equal "http://127.0.0.1:8080/projects/r?tab=board&card=3",
                 U.card("r", 3, { "PUBLIC_HOST" => "", "WEB_HOST_PORT" => "8080" })
  end

  def test_a_missing_or_malformed_value_raises
    assert_match(/PUBLIC_HOST missing/, assert_raises(U::Invalid) { U.origin({}) }.message)
    assert_match(/WEB_HOST_PORT missing/, assert_raises(U::Invalid) { U.origin({ "PUBLIC_HOST" => "" }) }.message)
    assert_match(/PUBLIC_HOST="a b" is not a hostname/,
                 assert_raises(U::Invalid) { U.origin({ "PUBLIC_HOST" => "a b" }) }.message)
    assert_match(/WEB_HOST_PORT="0" is not a port/,
                 assert_raises(U::Invalid) { U.origin({ "PUBLIC_HOST" => "", "WEB_HOST_PORT" => "0" }) }.message)
  end
end
