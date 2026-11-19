# frozen_string_literal: true

require "busyyaks/kanban_api"
require "busyyaks/writer_client"

module Busyyaks
  module Actions
    module API
      module Workflow
        # DELETE /api/projects/*slug/workflow → the template board again for this project, through the writer service like
        # Save (the file written too; card #429); refused while cards sit in a column the template lacks
        class Reset < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) do
              answer(res, WriterClient.workflow_reset(slug(req), by: req.session[:email]))
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
