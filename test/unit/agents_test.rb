# frozen_string_literal: true

require "test_helper"
require "busyyaks/agents"

class AgentsTest < Minitest::Test
  def test_team_puts_running_first
    t = Busyyaks::Agents.team("agents" => [{ "id" => "a", "state" => "done", "mtime" => 9 },
                                           { "id" => "b", "state" => "running", "mtime" => 1 },])
    assert_equal %w[b a], t[:agents].map { |a| a[:label] }
  end

  def test_groups_match_longest_project_path_and_rank_blocked_first
    snap = { "sessions" => [
      { "name" => "idle1", "socket" => "default", "activity" => 5,
        "panes" => [{ "project_path" => "/projects/g/r", "status" => "idle" }], },
      { "name" => "ask", "socket" => "default", "activity" => 1,
        "panes" => [{ "project_path" => "/projects/g/r/x", "status" => "idle", "waiting_for" => "approve?" }], },
      { "name" => "top", "socket" => "default", "activity" => 9,
        "panes" => [{ "project_path" => "/projects/g", "status" => "busy" }], },
    ] }
    projects = [{ slug: "g", path: "/projects/g" }, { slug: "g/r", path: "/projects/g/r" }]
    groups = Busyyaks::Agents.groups(snap, projects)
    assert_equal ["g/r", "g"], groups.map { |_, slug, _| slug }
    assert_equal %w[ask idle1], groups.first[2].map(&:name)
    assert_equal ["blocked", "collector: waiting_for"], [groups.first[2].first.state, groups.first[2].first.state_by]
  end

  def session(panes, attached: 0, asks: {}, reviews: {}, cards: {}, seen: {})
    snap = { "sessions" => [{ "name" => "s", "socket" => "default", "activity" => 1, "attached" => attached,
                              "panes" => panes, }] }
    by_session = cards.transform_keys { |k| [k, "default"] }.transform_values { |v| { cards: v } }
    Busyyaks::Agents.groups(snap, [], asks: asks, reviews: reviews, cards: by_session, seen: seen).first[2].first
  end

  def state_of(panes) = session(panes).then { |x| [x.state, x.state_by] }

  def test_the_screen_card_and_collector_each_say_their_state_worst_wins
    assert_equal ["blocked", "screen: bash_permission_prompt"],
                 state_of([{ "status" => "busy", "screen" => { "state" => "blocked", "rule" => "bash_permission_prompt" } }])
    assert_equal ["working", "screen: live_turn_working"],
                 state_of([{ "status" => "idle", "screen" => { "state" => "working", "rule" => "live_turn_working" } }])
    assert_equal ["working", "subagents running"], state_of([{ "status" => "idle", "subagents_running" => 2 }])
    asked = session([{ "status" => "idle", "screen" => { "state" => "idle", "rule" => "live_prompt_box" } }],
                    asks: { "s" => [{ id: 7 }] })
    assert_equal ["blocked", "card #7"], [asked.state, asked.state_by]
    assert_equal "unknown", session([{ "screen" => { "state" => "unknown", "rule" => nil } }]).state
    assert_equal "unknown", session([{ "screen" => { "error" => "capture-pane %1: no pane" } }]).state
  end

  # an ended turn the operator has not opened is UNREAD — a flag beside the state, never "done"
  def test_unread_is_a_turn_that_ended_after_the_operator_last_saw_the_session
    pane = [{ "status" => "idle", "status_at" => 100.0, "screen" => { "state" => "idle", "rule" => "live_prompt_box" } }]
    assert_equal ["idle", true], session(pane, seen: { "default/s" => 50.0 }).then { |x| [x.state, x.unread?] }
    refute session(pane, seen: { "default/s" => 150.0 }).unread?
    refute session(pane, seen: { "default/s" => 50.0 }, attached: 1).unread?, "attached = being looked at"
    refute session(pane).unread?, "never recorded = not known as unseen"
    refute session([{ "status" => "idle", "screen" => { "state" => "idle" } }], seen: { "default/s" => 50.0 }).unread?,
           "no turn end time"
  end

  # finished = idle and every card it owns (≥ 1) is in its board's done column — the cards say it
  def test_finished_needs_at_least_one_card_and_all_of_them_done
    idle = [{ "status" => "idle", "status_at" => 100.0, "screen" => { "state" => "idle", "rule" => "live_prompt_box" } }]
    done = { id: 5, column_label: "Done (public)", finishes: true }
    open = { id: 6, column_label: "Merged to local", finishes: false }
    gone = { id: 7, column_label: "old", finishes: nil }
    fin = session(idle, cards: { "s" => [done] })
    assert_equal ["finished", "cards: 1 in Done (public)"], [fin.state, fin.state_by]
    assert_equal "idle", session(idle, cards: { "s" => [] }).state, "no cards = not finished"
    unknown = session(idle)
    assert_equal ["idle", false], [unknown.state, unknown.cards_known?],
                 "no open registration = its cards unknown, never finished"
    assert_equal "idle", session(idle, cards: { "s" => [done, open] }).state, "a card in a parked column is not finished"
    assert_equal "idle", session(idle, cards: { "s" => [done, gone] }).state, "a column the board lost is unknown, not done"
    assert_equal [6], session(idle, cards: { "s" => [done, open] }).open_cards.map { |c| c[:id] }
    assert_equal "working", session([{ "status" => "busy" }], cards: { "s" => [done] }).state, "working beats finished"
    assert_equal "unknown", session([{ "screen" => { "state" => "unknown" } }], cards: { "s" => [done] }).state,
                 "the screen unread = unknown, never guessed finished"
  end

  # two kinds of waiting: a PR to review (calm) and a stopped job (needs input) — the stopped one wins
  def test_a_card_in_review_is_review_unless_the_job_is_stopped
    idle = [{ "status" => "idle", "status_at" => 100.0, "screen" => { "state" => "idle", "rule" => "live_prompt_box" } }]
    rev = session(idle, reviews: { "s" => [{ id: 9 }] }, seen: { "default/s" => 50.0 })
    assert_equal ["review", "card #9 in review"], [rev.state, rev.state_by], "review beats finished"
    both = session(idle, asks: { "s" => [{ id: 7 }] }, reviews: { "s" => [{ id: 9 }] })
    assert_equal ["blocked", "card #7"], [both.state, both.state_by]
  end

  def test_groups_rank_blocked_then_review_then_working_then_finished
    assert_equal %w[blocked review working finished idle unknown], Busyyaks::Agents::STATES
  end
end
