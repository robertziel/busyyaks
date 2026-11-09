# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Projects
        # POST /api/notes {slug, body} → the note, authored by the signed-in email.
        class Note < Busyyaks::APIAction
          def handle(req, res)
            slug = req.params[:slug].to_s
            error!(res, 404, "no project #{slug}") unless store.project(slug)
            body = req.params[:body].to_s.strip
            error!(res, 400, "body is empty") if body.empty?

            id = store.add_note(body: body, author: req.session[:email], project_slug: slug)
            json(res, { note: Busyyaks::API.note(store.notes(project_slug: slug).find { |n| n[:id] == id }) }, status: 201)
          end
        end
      end
    end
  end
end
