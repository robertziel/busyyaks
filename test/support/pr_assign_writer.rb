# frozen_string_literal: true

# One agent PROCESS for test/unit/pr_assign_test.rb's concurrent-assign test — its own boot of the app and its own
# connection, like a service. Assigns `url` as the `local` PR of card `id` through the engine (kanban_pr_assign's path).
# With a hold file: inside the writer's transaction (the roles port is asked there) it writes the hold file and waits
# for the release file, holding the write lock. Prints "ready" once booted, then one JSON line:
# {"ok" => true} or {"refused" => "<the engine's reason>"}; any other error raises (exit 1, the test shows it).
#   ruby test/support/pr_assign_writer.rb <card id> <pr url> <agent name> <hold file | -> <release file | ->
require "json"

id, url, name, hold, release = ARGV
ENV["HANAMI_ENV"] ||= "test"
require "hanami/prepare"
require_relative "wait"

conn = Hanami.app["db.gateway"].connection
roles = Busyyaks::Kanban.pr_roles(conn)
port = Object.new
port.define_singleton_method(:pr_roles) do |card|
  if hold != "-"
    File.write(hold, "")
    Wait.for("the test's release file", seconds: 120, every: 0.01) { File.exist?(release) }
  end
  roles.pr_roles(card)
end
store = AgentsKanban::Store.new(conn, config: Busyyaks::Kanban.config(conn), markdown: Busyyaks::Kanban.markdown,
                                      boards: ->(s) { conn[:projects].where(slug: s).any? },
                                      ci: Busyyaks::Kanban.ci_port(conn), prs: port)
conn.test_connection
$stdout.sync = true
puts "ready"
begin
  store.assign_pr(Integer(id), url: url, role: "local", by: name)
  puts JSON.generate("ok" => true)
rescue AgentsKanban::Invalid => e
  puts JSON.generate("refused" => e.message)
end
