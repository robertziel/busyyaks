# frozen_string_literal: true

require "test_helper"
require "busyyaks/tree"

class TreeTest < Minitest::Test
  def p(slug, at, dirty: 0, unpushed: nil)
    { slug: slug, last_commit_at: at, dirty: dirty, unpushed: unpushed, commits_window: 1, mine_window: 0 }
  end

  def test_groups_by_folder_with_totals_and_recency_order
    nodes = Busyyaks::Tree.build([p("a", 10), p("g/x", 50, dirty: 2, unpushed: 3), p("g/y", 5, dirty: 1), p("b", 20)])
    assert_equal %w[g b a], nodes.map(&:name)
    g = nodes.first
    assert g.folder?
    assert_equal %w[x y], g.children.map(&:name)
    assert_equal 3, g.sum(:dirty)
    assert_equal [3], g.unpushed_known
    assert_equal 50, g.last_commit_at
  end
end
