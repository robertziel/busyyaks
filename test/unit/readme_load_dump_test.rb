# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../scripts/readme-images/load-dump"

# The README screenshot environment's loader (scripts/readme-images/load-dump.rb's Busyyaks::ReadmeLoadDump): a dump
# goes into the database, its ids kept, every time moved forward by one shift (each *_at epoch column, whatever its
# table — a new timestamp column cannot stay behind), its picture written under ATTACHMENTS_DIR; a second load is
# refused; touch reads the PR states now. On this test's database, under a stubbed Busyyaks::Clock: every expected
# time derives from NOW, never the real clock. Required once (never re-loaded), so its coverage counts are stable.
class ReadmeLoadDumpTest < Minitest::Test
  include DBReset

  SLUG = "busyyaks_dumptest"
  AT = 1_700_000_000 # the dump's time: far in the past, so the shift is large and positive
  NOW = AT + 86_400 * 400 # the loader's clock
  SHIFT = NOW - AT
  PNG = "\x89PNG\r\n\x1a\nfixture".b

  def setup
    super
    @dir = Dir.mktmpdir("readme-dump-")
    @attachments = Dir.mktmpdir("readme-dump-att-")
    FileUtils.mkdir_p(File.join(@dir, "attachments"))
    File.binwrite(File.join(@dir, "attachments", "9101.png"), PNG)
    File.write(File.join(@dir, "board.json"), JSON.generate(board))
    File.write(File.join(@dir, "merged.json"), JSON.generate(
      [{ repo: "dev-example/busyyaks", number: 7, title: "A merged PR", url: "https://github.com/dev-example/busyyaks/pull/7",
         merged_at: AT - 3600, }],
    ))
  end

  def teardown
    FileUtils.rm_rf([@dir, @attachments])
    super
  end

  def board
    {
      slug: SLUG, card: 9101, exported_at: AT,
      columns: [
        { id: 1, project_slug: SLUG, key: "todo", label: "To do", type: "queued", position: 0, hide_after_hours: 72 },
        { id: 2, project_slug: SLUG, key: "doing", label: "In progress", type: "working", position: 1, hide_after_hours: 72 },
        { id: 3, project_slug: SLUG, key: "done", label: "Done", type: "done", position: 2, hide_after_hours: 24 },
      ],
      transitions: [{ id: 1, project_slug: SLUG, position: 0, name: "Start work", from_keys: '["todo"]', to_key: "doing",
                      by: "any", }],
      labels: [{ id: 1, project_slug: SLUG, name: "docs", color: "yellow", created_at: AT - 900 }],
      cards: [{ id: 9101, project_slug: SLUG, column: "doing", position: 0, title: "A dumped card", notes: "", labels: "[]",
                created_by: "operator", created_at: AT - 500, updated_at: AT - 100, due_at: AT + 86_400, ui_change: true,
                handoff_at: AT - 200, }],
      activity: [{ id: 9101, card_id: 9101, kind: "comment", body: "a comment", author: "operator", created_at: AT - 300,
                   by_operator: true, undelivered: false, }],
      checklists: [{ id: 9101, card_id: 9101, title: "Steps", position: 0, created_at: AT - 400 }],
      items: [{ id: 9101, checklist_id: 9101, body: "one", done: 1, position: 0, done_by: "operator", done_at: AT - 350,
                created_at: AT - 390, }],
      attachments: [{ id: 9101, card_id: 9101, activity_id: nil, filename: "shot.png", content_type: "image/png",
                      size: PNG.bytesize, sha256: "x", uploaded_by: "operator", created_at: AT - 250, file: "9101.png", }],
      pr_states: [{ id: 1, repo: "dev-example/busyyaks", ref: "pr:7", requested_at: AT - 60, checked_at: AT - 60, number: 7,
                    url: "https://github.com/dev-example/busyyaks/pull/7", state: "merged", }],
    }
  end

  # → [output, success?]: the printed line, or the refusal's message
  def load!(mode = "load", at: NOW)
    env = { "DUMP_DIR" => @dir, "ATTACHMENTS_DIR" => @attachments, "DEMO_GITHUB_LOGIN" => "dev-example" }
    Busyyaks::Clock.stub(:epoch, at) { [Busyyaks::ReadmeLoadDump.run(mode, db: db, env: env), true] }
  rescue Busyyaks::ReadmeLoadDump::Refused => e
    [e.message, false]
  end

  def db = Hanami.app["db.gateway"].connection

  def test_loads_every_table_with_its_ids_and_moves_every_time_by_one_shift
    out, status = load!
    assert status, out
    card = db[:cards].where(id: 9101).first
    refute_nil card, "the dumped card keeps its id"
    shift = SHIFT
    assert_equal AT - 500 + shift, card[:created_at]
    assert_equal({ updated_at: AT - 100, due_at: AT + 86_400, handoff_at: AT - 200 }.transform_values { _1 + shift },
                 card.slice(:updated_at, :due_at, :handoff_at))
    assert_equal AT - 300 + shift, db[:card_activity].where(id: 9101).get(:created_at)
    assert_equal [AT - 350 + shift, AT - 390 + shift], db[:checklist_items].where(id: 9101).get(%i[done_at created_at])
    assert_equal AT - 3600 + shift, db[:gh_merged_prs].where(number: 7, repo: "dev-example/busyyaks").get(:merged_at)
    assert_equal %w[todo doing done], db[:board_columns].where(project_slug: SLUG).order(:position).select_map(:key)
    pic = db[:card_attachments].where(id: 9101).first
    assert_equal PNG, File.binread(File.join(@attachments, pic[:stored_path]))
    assert_equal AT - 250 + shift, pic[:created_at]
  end

  # every *_at epoch column of the tables the loader writes moved: none of the dump's times stays at its dump value
  def test_no_epoch_column_of_a_loaded_row_keeps_its_dump_time
    _out, status = load!
    assert status
    dumped = board
    { cards: dumped[:cards], card_activity: dumped[:activity], checklists: dumped[:checklists],
      checklist_items: dumped[:items], card_attachments: dumped[:attachments], }.each do |table, rows|
      rows.each do |row|
        stored = db[table].where(id: row[:id]).first
        row.each do |k, v|
          next unless k.end_with?("_at") && v.is_a?(Integer)

          refute_equal v, stored[k], "#{table}.#{k} kept its dump time"
        end
      end
    end
  end

  def test_a_second_load_is_refused_and_touch_reads_the_pr_states_now
    assert load!.last
    out, status = load!
    refute status
    assert_match(/already holds #{SLUG} cards: load once per stack/, out)
    assert_equal AT - 60 + SHIFT, db[:gh_pr_states].where(ref: "pr:7").get(:checked_at)
    out, status = load!("touch", at: NOW + 30)
    assert status, out
    assert_equal [NOW + 30, NOW + 30], db[:gh_pr_states].where(ref: "pr:7").get(%i[requested_at checked_at])
  end

  def test_a_picture_whose_size_differs_from_its_row_is_refused
    File.binwrite(File.join(@dir, "attachments", "9101.png"), "short")
    out, status = load!
    refute status
    assert_match(/picture 9101 is not the size its row says/, out)
    assert_nil db[:cards].where(id: 9101).first, "nothing is loaded"
  end

  def test_a_mode_other_than_load_or_touch_is_refused
    out, status = load!("reload")
    refute status
    assert_equal 'load-dump: "reload" is not load or touch', out
  end
end
