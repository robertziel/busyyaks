# frozen_string_literal: true

# session_roles: what busyyaks started with kanban_spawn — the session's agent type and project role (a role
# of the repo's .busyyaks/agents.yml, null = none) — so a worker the lead hands a card later (kanban_assign_worker) is
# checked against the type or role the card's column takes (Busyyaks::BoardAgents). A row per session name (tmux keeps a
# running name unique; a new spawn of the name replaces it). down: the table goes; sessions spawned before it are "not
# recorded" (a mapped column refuses them, naming kanban_spawn).
ROM::SQL.migration do
  up do
    create_table(:session_roles) do
      primary_key :id
      String :session, null: false, unique: true
      String :project_slug, null: false
      String :type_key, null: false
      String :role
      Integer :created_at, null: false
    end
  end

  down do
    drop_table(:session_roles)
  end
end
