# frozen_string_literal: true

require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Cards
        # POST /api/cards/:id/attachments — multipart: file, comment_id? → 201 {attachment} (with its markdown snippet).
        # The type is read from the bytes; a name/bytes mismatch or a type outside ATTACHMENT_TYPES → 422, too big → 413.
        class Attach < Busyyaks::Action
          include KanbanAPI

          def handle(req, res)
            f = req.params[:file]
            io = f.is_a?(Hash) && (f[:tempfile] || f["tempfile"])
            filename = f.is_a?(Hash) ? (f[:filename] || f["filename"]).to_s : ""
            answer(res, api(req).attach(id(req), filename: filename, io: io || nil,
                                        by: req.session[:email], comment_id: req.params[:comment_id]))
          end
        end
      end
    end
  end
end
