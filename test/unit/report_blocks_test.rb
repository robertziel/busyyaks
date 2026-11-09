# frozen_string_literal: true

require "test_helper"
require "busyyaks/markdown"

class ReportBlocksTest < Minitest::Test
  include DBReset

  def setup
    super
    store.upsert_project(slug: "blog", path: "/p/blog", remote: nil, branch: "main", own: true, last_commit_at: 1,
                         commits_window: 1, mine_window: 1, dirty: 0, unpushed: nil, scanned_at: 1)
  end

  def html(md) = Busyyaks::Markdown.report(md, store)

  def test_every_catalog_example_renders_without_error
    Busyyaks::ReportBlocks::CATALOG.each do |c|
      out = html("```tl:#{c[:name]}\n#{c[:example]}```\n")
      refute_includes out, "tl-error", "tl:#{c[:name]} example failed: #{out[/tl-error.*?<\/div>/m]}"
      assert_includes out, %(class="tl tl-#{c[:name]}")
    end
  end

  def test_broken_block_is_visible_not_dropped
    assert_includes html("```tl:stats\n- { label: x }\n```\n"), "<b>tl:stats</b> not rendered: value is required"
    assert_includes html("```tl:bars\nitems: [{ label: a, value: lots }]\n```\n"), "value must be a number"
    assert_includes html("```tl:stats\n- { label: a, value: 1, tone: pink }\n```\n"), "tone &quot;pink&quot;"
    assert_includes html("```tl:nope\n[]\n```\n"), "unknown component"
    assert_includes html("```tl:kv\n: : :\n```\n"), "tl-error"
  end

  def test_values_are_escaped_and_markdown_is_safe
    out = html("```tl:callout\ntone: warn\ntitle: \"<script>x</script>\"\nbody: \"**b** <img src=x onerror=alert(1)>\"\n```\n")
    refute_includes out, "<script>x"
    refute_includes out, "<img"
    assert_includes out, "<strong>b</strong>"
  end

  def test_inline_tokens_and_repo_chips
    out = html("`repo:blog` `repo:ghost` `warn:69 dirty` `ok:<b>`")
    assert_includes out, '<a class="tl-repo" href="/projects/blog">blog</a>'
    assert_includes out, '<span class="tl-repo unknown"'
    assert_includes out, '<span class="tl-pill t-warn">69 dirty</span>'
    assert_includes out, '<span class="tl-pill t-ok">&lt;b&gt;</span>'
  end

  def test_stats_change_vs_prev
    out = html("```tl:stats\n- { label: Commits, value: 49, prev: 12, good: up }\n" \
               "- { label: Dirty, value: 52, prev: 48, good: down }\n- { label: Same, value: 3, prev: 3 }\n```\n")
    assert_includes out, %(<span class="tl-chg up good" title="vs 12 yesterday"><i aria-hidden="true">▲</i>37</span>)
    assert_includes out, %(class="tl-chg up bad")
    assert_includes out, %(class="tl-chg flat")
    assert_includes html("```tl:stats\n- { label: a, value: lots, prev: 1 }\n```\n"), "value (with prev) must be a number"
    assert_includes html("```tl:stats\n- { label: a, value: 2, prev: 1, good: sideways }\n```\n"), "good must be up or down"
  end

  def test_cards_flags_needs_churn
    cards = html("```tl:cards\n- { repo: blog, upstream: false, commits: 3, prev: 5, dirty: 2, unpushed: null, " \
                 "add: 4, del: 1, shipped: [\"**x**\"], risks: [y] }\n```\n")
    assert_includes cards, %(<span class="tl-pill t-bad">no upstream</span>)
    assert_includes cards, %(class="tl-chg down")
    assert_includes cards, %(<span class="tl-fig hot"><b>2</b> dirty)
    assert_includes cards, %(<b>—</b> unpushed)
    assert_includes cards, %(<ul class="tl-shipped"><li><strong>x</strong></li></ul>)
    assert_includes html("```tl:cards\n- { repo: blog, upstream: maybe }\n```\n"), "upstream must be true or false"
    assert_includes html("```tl:cards\n- { repo: blog, shipped: one line }\n```\n"), "shipped must be a list"

    flags = html("```tl:flags\n- { level: info, kind: unpushed, text: b }\n" \
                 "- { level: bad, kind: no upstream, text: a, repo: blog }\n```\n")
    assert_operator flags.index("t-bad"), :<, flags.index("t-info"), "worst first"
    assert_includes html("```tl:flags\n- { level: red, kind: x, text: y }\n```\n"), "level &quot;red&quot;"
    assert_includes html("```tl:flags\n- { level: bad, kind: this is a whole sentence not a tag, text: y }\n```\n"),
                    "≤ 24 chars"

    needs = html("```tl:needs\n- { title: Ship it, repo: blog, card: 7, ask: \"**yes**\" }\n" \
                 "- { title: Ghost, repo: ghost, card: 8 }\n```\n")
    assert_includes needs, %(<a class="tl-need-title" href="/projects/blog?tab=board&amp;card=7">Ship it</a>)
    assert_includes needs, %(<span class="tl-need-title">Ghost</span>)
    assert_includes html("```tl:needs\n- { title: x, repo: blog, card: seven }\n```\n"), "card must be a whole number"

    churn = html("```tl:churn\n- { repo: blog, files: 2, add: 30, del: 10 }\n- { repo: blog, files: 1, add: 4, del: 0 }\n```\n")
    assert_includes churn, %(<i class="a" style="width:75.0%"></i><i class="d" style="width:25.0%"></i>)
    assert_includes html("```tl:churn\n- { repo: blog, files: 2, add: -1, del: 0 }\n```\n"), "add must be a whole number"
  end

  def test_digest
    md = "```tl:stats\n- { label: Commits, value: 49, prev: 12, good: up, tone: accent }\n```\n\n" \
         "```tl:flags\n- { level: warn, kind: unpushed, text: \"22 `x`\" }\n" \
         "- { level: bad, kind: no upstream, text: \"**25** commits\" }\n```\n\n" \
         "```tl:cards\n- { repo: blog }\n- { repo: blog }\n```\n\n" \
         "```tl:actions\n- { priority: high, text: a }\n- { priority: low, text: b }\n```\n\n```tl:stats\n- { label: x }\n```\n"
    d = Busyyaks::ReportBlocks.digest(md, Busyyaks::Markdown.report_ctx(store))
    assert_equal [{ label: "Commits", value: "49", tone: "accent", delta: "37", good: "up" }], d[:figures]
    assert_equal({ tone: "bad", text: "no upstream: 25 commits" }, d[:headline])
    assert_equal({ high: 1, med: 0, low: 1 }, d[:actions])
    assert_equal [2, 2, 1], [d[:repos], d[:flags], d[:broken]]
  end

  def test_example_daily_report_renders_clean
    md = File.read(File.expand_path("../fixtures/daily-report.md", __dir__))
    %w[acme/shop acme/api acme/site acme/auth acme/infra].each do |s|
      store.upsert_project(slug: s, path: "/p/#{s}", remote: nil, branch: "main", own: true, last_commit_at: 1,
                           commits_window: 1, mine_window: 1, dirty: 0, unpushed: nil, scanned_at: 1)
    end
    assert_empty Busyyaks::ReportBlocks.problems(md, Busyyaks::Markdown.report_ctx(store))
    refute_includes html(md), "tl-repo unknown"
  end

  def test_status_line_joins_its_heading
    out = html("## Needs you\n\n`ok:0 cards in Human Check`\n\n```tl:needs\n- { title: x, repo: blog }\n```\n\n" \
               "mid `ok:shipped` text\n")
    heading = %r{<div class="tl-sechead"><h2 id="needs-you">Needs you.*?</h2>}m
    status = %r{<p class="tl-status"><span class="tl-pill t-ok">0 cards in Human Check</span></p></div>}m
    assert_match(/#{heading}#{status}/m, out)
    assert_includes out, %(<p>mid <span class="tl-pill t-ok">shipped</span> text</p>), "a pill inside a sentence stays a pill"
    assert_equal [[2, "needs-you", "Needs you"]], Busyyaks::Markdown.headings(out)
  end

  def test_github_mark_and_commit_subject_only_where_they_help
    store.upsert_project(slug: "gh", path: "/p/gh", remote: "https://github.com/o/gh.git", branch: "main", own: true,
                         last_commit_at: 1, commits_window: 1, mine_window: 1, dirty: 0, unpushed: nil, scanned_at: 1)
    sha = "abcdef1234567"
    store.replace_commits("gh", [{ sha: sha, author: "a", email: "a@x", committed_at: Time.now.to_i, subject: "fix the thing",
                                   mine: true, }], 0)
    cards = html("```tl:cards\n- { repo: gh, shas: [#{sha}] }\n```\n")
    flags = html("```tl:flags\n- { level: warn, kind: breaking, repo: gh, sha: #{sha}, text: t }\n```\n")
    actions = html("```tl:actions\n- { priority: high, repo: gh, text: t }\n```\n")
    assert_includes cards, "gh-repo-link", "a card's own repo chip carries the GitHub mark"
    assert_includes cards, %(<code class="gh-sha">abcdef1</code><span class="gh-subj">fix the thing</span>)
    refute_includes flags, "gh-repo-link"
    refute_includes actions, "gh-repo-link"
    assert_includes flags, %(title="abcdef123 · fix the thing"><svg)
    assert_includes flags, %(<code class="gh-sha">abcdef1</code></a>),
                    "a flag's commit is glyph + sha, the subject in the tooltip"
  end

  def test_regular_code_fences_untouched
    out = html("```ruby\nputs 1\n```\n")
    assert_includes out, "<code>puts 1"
    refute_includes out, "tl-error"
  end
end
