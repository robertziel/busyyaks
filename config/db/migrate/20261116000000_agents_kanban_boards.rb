# frozen_string_literal: true

require "json"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/schema"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/host_config"
require_relative "../../../vendor/agents_kanban/ruby/lib/agents_kanban/board_repo"

# agents_kanban Schema v6: the BOARDS move into the database — `boards` / `board_columns` /
# `board_transitions`, one board per project (its columns with their TYPES, order and graph positions + its named
# transitions) and the template row (project_slug "") a new project is instantiated from. migrate!(to: 6) creates the
# tables; BoardRepo#seed! writes the template from the engine's coding board fixture (= the Backlog → … → Merged board
# every project ran on config/kanban.yml until now, column for column, with the same default workflow), then a board for
# every project in `projects` — the project's own `workflows` row (the first workflow version) becomes its transitions
# when it has one — and drops `workflows`. Idempotent: a template that exists is kept, projects with rows are skipped.
#
# down: the v5 shape back — `workflows` recreated and refilled from every project board whose transitions differ from
# the template's (main's code reads them again), the boards tables dropped. A board whose COLUMNS differ from the
# template's cannot be expressed in v5: the rollback then raises Sequel::Error naming the projects — restore the
# pre-migration backup instead (take one before deploying this migration).
ROM::SQL.migration do
  up do
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 6)
    root = File.expand_path("../../..", __dir__)
    host = AgentsKanban::HostConfig.load(ENV.fetch("KANBAN_CONFIG"))
    template = JSON.parse(File.read(File.join(root, "vendor/agents_kanban/fixtures/boards/coding.board.json")))
    repo = AgentsKanban::BoardRepo.new(self, tables: AgentsKanban::Schema.tables(""), host: host, known: ->(_) { true })
    report = repo.seed!(template: template, projects: self[:projects].select_map(:slug), by: "migration 20261116000000")
    puts "agents_kanban boards: template #{report[:template]}, #{report[:created].size} project boards created " \
         "(#{report[:from_workflows].size} from their workflows rows: #{report[:from_workflows].join(', ')}), " \
         "workflows table dropped: #{report[:dropped_workflows]}"
  end

  down do
    tpl = self[:board_transitions].where(project_slug: "").order(:position).all
    tpl_cols = self[:board_columns].where(project_slug: "").order(:position).all.map { |c| [c[:key], c[:label], c[:type]] }
    edge = ->(r) { [r[:name], r[:from_keys], r[:to_key], r[:by]] }
    rows = []
    reshaped = []
    self[:boards].exclude(project_slug: "").order(:project_slug).all.each do |b|
      slug = b[:project_slug]
      cols = self[:board_columns].where(project_slug: slug).order(:position).all.map { |c| [c[:key], c[:label], c[:type]] }
      reshaped << slug if cols != tpl_cols
      trs = self[:board_transitions].where(project_slug: slug).order(:position).all
      next if trs.map(&edge) == tpl.map(&edge)

      transitions = trs.map do |t|
        { "name" => t[:name], "from" => JSON.parse(t[:from_keys]), "to" => t[:to_key], "by" => t[:by] }
      end
      body = { "name" => "board", "transitions" => transitions }
      rows << { project_slug: slug, body: JSON.generate(body), updated_by: b[:updated_by], updated_at: b[:updated_at] }
    end
    unless reshaped.empty?
      raise Sequel::Error, "irreversible: the boards of #{reshaped.join(', ')} have columns the template has not " \
                           "(v5 keeps transitions only) — " \
                           "restore the pre-migration backup instead of rolling back (the copy taken before deploying)"
    end

    drop_table(:board_transitions)
    drop_table(:board_columns)
    drop_table(:boards)
    AgentsKanban::Schema.migrate!(self, prefix: "", to: 5) # `workflows` again, as v5 had it
    self[:workflows].multi_insert(rows) unless rows.empty?
    puts "agents_kanban boards rolled back: #{rows.size} project workflows restored, boards tables dropped"
  end
end
