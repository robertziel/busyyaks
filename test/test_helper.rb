# frozen_string_literal: true

ENV["HANAMI_ENV"] ||= "test"
require "hanami/prepare"
require "minitest/autorun"
require "busyyaks/store"
require_relative "support/sign_in"

# config/busyyaks.yml `launch` for a test Config: no trusted paths, the one plain-claude invocation
LAUNCH_CLAUDE = {
  "trusted_paths" => [], "commands" => [{ "kind" => "claude_code", "command" => "claude", "args" => [], "via_shell" => false }],
  "start_seconds" => 30,
}.freeze

# The agent settings the suite runs on (test/fixtures/agents.yml: two launchers) as the newest revision — written once
# here and again before every DBReset test (a test may save revisions of its own).
module AgentSettingsFixture
  DOC = YAML.safe_load_file(File.expand_path("fixtures/agents.yml", __dir__))

  def self.install!(db = Hanami.app["db.gateway"].connection)
    db[:agent_settings].delete
    db[:agent_settings].insert(doc: JSON.generate(DOC), author: "test fixture", created_at: 0)
  end
end
AgentSettingsFixture.install!

module DBReset
  def setup
    super
    db = Hanami.app["db.gateway"].connection
    AgentSettingsFixture.install!(db)
    %i[daily_report_settings agent_sessions session_dialogs card_attachments card_pings checklist_items checklists
       board_labels card_activity cards projects commits reports notes scans daily gh_users gh_follows gh_repos gh_stars
       gh_pages gh_runs gh_events gh_pr_checks gh_pr_states ci_watches gh_merged_prs gh_pr_runs
       setup_completions].each { |t| db[t].delete }
    # the projects' boards go; the TEMPLATE board (project_slug "", seeded by the migration) stays — every project is
    # instantiated from it
    %i[board_transitions board_columns boards].each { |t| db[t].exclude(project_slug: "").delete }
  end

  def store = Busyyaks::Store.default
end
