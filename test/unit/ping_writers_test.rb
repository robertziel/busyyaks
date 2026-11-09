# frozen_string_literal: true

require "minitest/autorun"

# What is typed into an agent session is a card_pings row the notifier delivers. Rows are written only by the engine's
# Store (enqueue_ping and its delivery bookkeeping) — never by busyyaks code, so never by a collector (scanner, github)
# from the data it reads. A collector that is itself compromised can still write the shared DB: docs/DEPLOY.md
# "Remaining risks".
class PingWritersTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_only_the_engine_store_writes_card_pings
    host = Dir.glob(File.join(ROOT, "{lib,app,bin,config,auth}/**/*")).select { |f| File.file?(f) }
              .reject { |f| f.include?("/config/db/") } # migrations + the schema dump: table definitions, no writes
    hits = host.select { |f| File.read(f, encoding: "BINARY").match?(/card_pings|pings_t\b/) }
    assert_empty hits.map { |f| f.delete_prefix("#{ROOT}/") }
    engine = Dir.glob(File.join(ROOT, "vendor/agents_kanban/ruby/lib/**/*.rb"))
    writers = engine.select { |f| File.read(f).match?(/pings_t\.(?:insert|where\([^)]*\)\.update)/) }
    assert_equal ["vendor/agents_kanban/ruby/lib/agents_kanban/store.rb"], writers.map { |f| f.delete_prefix("#{ROOT}/") }
  end
end
