# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Markdown
        # POST /api/markdown {body, inline?} → {html}: the editor's Preview tab — the engine's render, never a JS markdown lib
        class Preview < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            refusing(res) { answer(res, api(req).markdown_preview(body(req))) }
          end
        end
      end
    end
  end
end
