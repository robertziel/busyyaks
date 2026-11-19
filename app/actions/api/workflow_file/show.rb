# frozen_string_literal: true

require "busyyaks/kanban_api"
require "busyyaks/workflow_files"

module Busyyaks
  module Actions
    module API
      module WorkflowFile
        # GET /api/projects/*slug/workflow-file → the writer's sync state of `<repo>/.busyyaks/workflow.yml` (card #429):
        # {file, path (host), applied_at, error, error_at, checked_at, stale} — stale = the writer's last look is older
        # than 3 × writer_sync_seconds (Settings → Runtime; the writer is down: a file edited since is not applied).
        # Never read → every field null and `error` says so.
        class Show < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            row = kanban.db[:projects].where(slug: slug(req)).first or
              return json(res, { error: "no project #{slug(req)}" }, status: 404)

            json(res, Busyyaks::WorkflowFiles.state(kanban.db, row))
          end
        end
      end
    end
  end
end
