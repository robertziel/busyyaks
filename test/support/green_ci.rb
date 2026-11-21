# frozen_string_literal: true

require "json"

# Whether an approval step waits for green CI is its GATE column's own setting (requires_green_ci, absent =
# false; was config/kanban.yml approval.requires_green_ci). The tests of the CI gate turn it on, board by board.
module GreenCi
  # the board hash (string keys) with requires_green_ci on every gate column
  def self.board(hash)
    hash.merge("columns" => hash["columns"].map { |c| c["type"] == "gate" ? c.merge("requires_green_ci" => true) : c })
  end

  # a vendored engine board fixture (vendor/agents_kanban/fixtures/boards/<name>.board.json), every gate requiring it
  # (on: false = as shipped: no gate asks CI)
  def self.fixture(name, on: true)
    raw = JSON.parse(File.read(File.expand_path("../../vendor/agents_kanban/fixtures/boards/#{name}.board.json", __dir__)))
    on ? board(raw) : raw
  end

  # the project's stored board (the template's copy on first use) saved again with every gate requiring green CI
  def self.on!(store, slug) = store.board_save(slug, board(store.board_of(slug).to_h), by: "operator")
end
