# frozen_string_literal: true

# Standalone: Busyyaks::CiSettings is a pure file (bin/yaks requires it on the host too: `yaks ci required`).
require "minitest/autorun"
require_relative "../../lib/busyyaks/ci_settings"

class CiSettingsTest < Minitest::Test
  def parse(required) = Busyyaks::CiSettings.parse!("max_pending_minutes" => 60, "required" => required)

  def test_required_for_is_case_insensitive
    checks = ["gates", "ci / build (ubuntu)"]
    assert_equal checks, parse("Owner/Repo" => checks).required_for("owner/repo")
    assert_nil parse("owner/repo" => ["gates"]).required_for("owner/other")
  end

  # a name GitHub can never match exactly, or one that prints as two lines, is refused
  def test_a_context_with_surrounding_space_or_a_line_break_is_refused
    ["", " ", " gates", "gates ", "ga\ntes", "ga\rtes", 7].each do |bad|
      error = assert_raises(Busyyaks::CiSettings::Invalid) { parse("owner/repo" => [bad]) }
      assert_includes error.message, "ci.required.owner/repo must be a non-empty list"
    end
  end
end
