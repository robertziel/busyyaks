# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Projects
        # POST /api/launch {slug, type, launcher?} → the engine's Api#launch: the cap checked on a fresh session list
        # (422 with who runs), the session registered with the board (a lead adopts the project's ownerless cards),
        # then started by bin/launcher under that name. The launcher's Remote Control verdict comes back as is in
        # `result` (remote_control "on" + remote_control_name, or "failed" + reason) — never presented as fine.
        class Launch < Busyyaks::APIAction
          def handle(req, res)
            slug = req.params[:slug].to_s
            error!(res, 404, "no project #{slug}") unless store.project(slug)
            body = { "type" => req.params[:type].to_s }
            body["launcher"] = req.params[:launcher].to_s unless req.params[:launcher].to_s.empty?
            error!(res, 400, "type is required (#{Kanban.config.agent_type_keys.join(', ')})") if body["type"].empty?

            status, out = Kanban.api.launch(slug, body, by: req.session[:email].to_s)
            json(res, out, status: status)
          end
        end
      end
    end
  end
end
