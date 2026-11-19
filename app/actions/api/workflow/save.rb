# frozen_string_literal: true

require "busyyaks/kanban_api"
require "busyyaks/writer_client"

module Busyyaks
  module Actions
    module API
      module Workflow
        # POST /api/projects/*slug/workflow {columns, transitions} → the saved board shape, through the writer service: the
        # engine's boards tables replaced as a whole AND `<repo>/.busyyaks/workflow.yml` written, or neither (card #429);
        # 422 with the reason when it does not validate, drops a column that still holds cards or the file cannot be
        # written; 409 when the file changed on disk first (applied: reload) or during the write (left as it is); 503
        # when the writer is down; 504 when it took the request but did not answer in time (the save may still apply)
        class Save < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) do
              answer(res, WriterClient.workflow_save(slug(req), body(req), by: req.session[:email]))
            rescue WriterClient::Unavailable => e
              json(res, { error: e.message }, status: 503)
            rescue WriterClient::NoAnswer => e
              json(res, { error: e.message }, status: 504)
            end
          end
        end
      end
    end
  end
end
