# frozen_string_literal: true

# One writer PROCESS for test/unit/database_concurrency_test.rb — what each of the five services is: its own boot of
# the app, its own connection to the shared SQLite file. Waits for the go file (so every writer starts at once),
# then creates cards and comments through the kanban engine, the MCP kanban_create / kanban_comment path.
# Prints "ready" once booted and connected, then one JSON line: {"done" => n, "errors" => ["Class: message", ...]};
# exit 0 even with errors (the test reports them).
#   ruby test/support/database_writer.rb <go file> <slug> <iterations> <writer name>
require "json"

go, slug, iterations, name = ARGV
ENV["HANAMI_ENV"] ||= "test"
require "hanami/prepare"

store = Busyyaks::Kanban.store
store.db.test_connection
$stdout.sync = true
puts "ready"
sleep 0.01 until File.exist?(go)

done = 0
errors = []
Integer(iterations).times do |i|
  id = store.create(slug: slug, title: "#{name} #{i}", by: name)
  store.comment(id, body: "#{name} comment #{i}", author: name)
  done += 1
rescue StandardError => e
  errors << "#{e.class}: #{e.message}"
end
puts JSON.generate("done" => done, "errors" => errors)
