# frozen_string_literal: true

require "test_helper"
require "busyyaks/project_rename"

# a renamed project directory keeps its board, cards, commits and history under the new slug.
class ProjectRenameTest < Minitest::Test
  include DBReset

  def db = Hanami.app["db.gateway"].connection

  def project(slug)
    store.upsert_project(slug: slug, path: "/p/#{slug}", remote: "https://github.com/o/#{slug}.git",
                         pr_remote: "git@github.com:o/#{slug}.git", branch: "main", own: true, last_commit_at: 1,
                         commits_window: 0, mine_window: 0, dirty: 0, unpushed: nil, scanned_at: 1)
  end

  def seed
    project("old")
    project("other")
    now = Time.now.to_i
    %w[old other].each do |s|
      db[:commits].insert(project_slug: s, sha: "a#{s}", author: "x", email: "x@example.com", committed_at: 1, subject: "s",
                          mine: false)
      id = db[:cards].insert(project_slug: s, column: "todo", position: 0, title: "t", created_by: "x", created_at: now,
                             updated_at: now, asked_by: "oldbot", pr_url: "https://github.com/o/#{s}/pull/7")
      db[:gh_merged_prs].insert(login: "me", repo: "o/#{s}", number: 7, title: "t", url: "https://github.com/o/#{s}/pull/7",
                                merged_at: 1, first_seen_at: 1)
      db[:card_activity].insert(card_id: id, kind: "comment", author: "oldbot", body: "b", created_at: now)
    end
  end

  def test_moves_every_project_slug_row_and_only_that_project
    seed
    out = Busyyaks::ProjectRename.run(db, from: "old", to: "new")
    assert_equal 1, out["projects.slug"]
    assert_equal 1, out["commits.project_slug"]
    assert_equal 1, out["cards.project_slug"]
    assert_equal %w[new other], db[:projects].order(:slug).select_map(:slug)
    assert_equal %w[new other], db[:cards].order(:project_slug).select_map(:project_slug)
    with_slug = db.tables.select { |t| db.schema(t).any? { |c, _| c == :project_slug } }
    assert_equal 0, with_slug.sum { |t| db[t].where(project_slug: "old").count }
    assert_equal %w[/p/new /p/other], db[:projects].order(:slug).select_map(:path)
    assert_equal %w[oldbot oldbot], db[:card_activity].select_map(:author), "authors untouched without --author"
    assert_equal %w[o/old o/other], db[:gh_merged_prs].order(:repo).select_map(:repo), "repos untouched without --repo"
  end

  def test_author_re_signs_the_engine_entries
    seed
    out = Busyyaks::ProjectRename.run(db, from: "old", to: "new", author: %w[oldbot busyyaks])
    assert_equal 2, out["card_activity.author"]
    assert_equal %w[busyyaks busyyaks], db[:cards].select_map(:asked_by)
  end

  def test_repo_rewrites_merged_prs_card_pr_urls_and_remotes_of_that_repo_only
    seed
    db[:gh_merged_prs].insert(login: "me", repo: "o/old-tool", number: 1, title: "t",
                              url: "https://github.com/o/old-tool/pull/1", merged_at: 1, first_seen_at: 1)
    out = Busyyaks::ProjectRename.run(db, from: "old", to: "new", repo: %w[o/old o/new_mirror])
    assert_equal 1, out["gh_merged_prs.repo"]
    assert_equal %w[o/new_mirror o/old-tool o/other], db[:gh_merged_prs].order(:repo).select_map(:repo)
    assert_equal ["https://github.com/o/new_mirror/pull/7", "https://github.com/o/old-tool/pull/1",
                  "https://github.com/o/other/pull/7",],
                 db[:gh_merged_prs].order(:repo).select_map(:url)
    assert_equal %w[https://github.com/o/new_mirror/pull/7 https://github.com/o/other/pull/7],
                 db[:cards].order(:project_slug).select_map(:pr_url)
    p = db[:projects].where(slug: "new").first
    assert_equal ["https://github.com/o/new_mirror.git", "git@github.com:o/new_mirror.git"], [p[:remote], p[:pr_remote]]
  end

  def test_refused_when_the_new_slug_has_rows_or_the_old_is_unknown
    seed
    e = assert_raises(Busyyaks::ProjectRename::Refused) { Busyyaks::ProjectRename.run(db, from: "old", to: "other") }
    assert_match(/"other" already has rows in projects\.slug/, e.message)
    assert_raises(Busyyaks::ProjectRename::Refused) { Busyyaks::ProjectRename.run(db, from: "nope", to: "new") }
    assert_raises(Busyyaks::ProjectRename::Refused) { Busyyaks::ProjectRename.run(db, from: "old", to: "old") }
    assert_raises(Busyyaks::ProjectRename::Refused) do
      Busyyaks::ProjectRename.run(db, from: "old", to: "new", author: ["oldbot", ""])
    end
    assert_raises(Busyyaks::ProjectRename::Refused) do
      Busyyaks::ProjectRename.run(db, from: "old", to: "new", repo: %w[o/old nope])
    end
    db[:projects].where(slug: "old").update(path: "/p/elsewhere")
    e = assert_raises(Busyyaks::ProjectRename::Refused) { Busyyaks::ProjectRename.run(db, from: "old", to: "new") }
    assert_match(/does not end in \/old/, e.message)
    assert_equal %w[old other], db[:projects].order(:slug).select_map(:slug), "nothing written"
  end
end
