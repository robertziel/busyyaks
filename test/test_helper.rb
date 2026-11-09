# frozen_string_literal: true

ENV["HANAMI_ENV"] ||= "test"
require "hanami/prepare"
require "minitest/autorun"
require "busyyaks/store"
require_relative "support/sign_in"

module DBReset
  def setup
    super
    db = Hanami.app["db.gateway"].connection
    %i[agent_sessions session_dialogs card_attachments card_pings checklist_items checklists board_labels card_activity
       cards projects commits reports notes scans daily gh_users gh_follows gh_repos gh_stars gh_pages gh_runs gh_events
       gh_pr_checks gh_pr_states ci_watches gh_merged_prs gh_pr_runs].each { |t| db[t].delete }
    # the projects' boards go; the TEMPLATE board (project_slug "", seeded by the migration) stays — every project is
    # instantiated from it
    %i[board_transitions board_columns boards].each { |t| db[t].exclude(project_slug: "").delete }
  end

  def store = Busyyaks::Store.default
end
