# frozen_string_literal: true

require "test_helper"
require "busyyaks/kanban"
require "busyyaks/pr_assign_audit"
require "open3"

# The one-off report: PR URLs an open card names but does not have assigned — printed for the operator to
# confirm, nothing written (a PR is never assigned from text).
class PrAssignAuditTest < Minitest::Test
  include DBReset
  A = Busyyaks::PrAssignAudit
  LOCAL = "https://github.com/o/r_local/pull/5"
  ENGINE = "https://github.com/o/eng_local/pull/91"

  def setup
    super
    @conn = Hanami.app["db.gateway"].connection
    [%w[o-r r_local r], %w[o-eng eng_local eng]].each do |slug, local, pub|
      @conn[:projects].insert(slug: slug, path: "/projects/#{slug}", remote: "git@github.com:o/#{local}.git",
                              pr_remote: "git@github.com:o/#{local}.git", own: true, commits_window: 0, mine_window: 0,
                              dirty: 0, scanned_at: 0, local_mode: "own", local_repo: "git@github.com:o/#{local}.git",
                              public_repo: "git@github.com:o/#{pub}.git", public_head: "git@github.com:o/#{pub}.git")
    end
    @kb = Busyyaks::Kanban.store(@conn)
  end

  def test_lists_the_prs_a_card_names_but_has_not_assigned_and_writes_nothing
    id = @kb.create(slug: "o-r", title: "ship", by: "lead", column: "doing", notes: "engine side: #{ENGINE}")
    @kb.assign_pr(id, url: LOCAL, role: "local", by: "lead")
    @conn[:cards].where(id: id).update(pr_url: LOCAL)
    c = @kb.comment(id, body: "also #{ENGINE.upcase.sub('HTTPS://GITHUB.COM', 'https://github.com').sub('PULL', 'pull')} " \
                              "and https://github.com/o/r/pull/9", author: "lead")
    done = @kb.create(slug: "o-r", title: "old", by: "lead", column: "merged", notes: "https://github.com/o/x/pull/1")
    before = @conn[:cards].order(:id).select_map(%i[id metadata updated_at])
    rows = @kb.unassigned_pr_mentions
    assert_equal [[id, "o-r", "In progress", ENGINE, "description"],
                  [id, "o-r", "In progress", "https://github.com/o/r/pull/9", "comment #{c}"],],
                 rows.map { |r| r.values_at(:card, :project, :column, :url, :seen) }
    refute(rows.any? { |r| r[:card] == done }, "a done card is not audited")
    assert_equal before, @conn[:cards].order(:id).select_map(%i[id metadata updated_at]), "nothing written"
    text = A.text(rows)
    assert_match(/\Acard\tproject\tcolumn\tPR named but not assigned\tfirst named in\n/, text)
    assert_match(/2 PR\(s\) on 1 card\(s\) — confirm each: the card's agent assigns it with kanban_pr_assign/, text)
    # a PR already on the card — assigned, or taken off on purpose (an unassign, the v14 migration) — is not listed
    @kb.unassign_pr(id, url: LOCAL, by: "lead", reason: "opened for another card", agent: true)
    refute(@kb.unassigned_pr_mentions.any? { |r| r[:url] == LOCAL }, "a removed PR named in pr_url is not listed")
  end

  def test_the_bin_prints_the_report
    # stdout is the report only — even when the environment says LOG_LEVEL info (the SQL logger's level)
    out, err, status = Open3.capture3({ "LOG_LEVEL" => "info" }, RbConfig.ruby,
                                      File.expand_path("../../bin/pr-assign-audit", __dir__))
    assert status.success?, err
    assert_equal "card\tproject\tcolumn\tPR named but not assigned\tfirst named in\n0 PR(s) on 0 card(s) — confirm " \
                 "each: the card's agent assigns it with kanban_pr_assign, nothing here writes\n", out
  end
end
