# frozen_string_literal: true

require "busyyaks/setup_api"

module Busyyaks
  module Actions
    module API
      module Setup
        # POST /api/setup/projects-root {step: plan|apply, path, plan_id} → the checked plan, or the apply started
        class ProjectsRootChange < Busyyaks::APIAction
          def handle(req, res)
            step = req.params[:step].to_s
            error!(res, 400, "step must be plan or apply") unless %w[plan apply].include?(step)
            error!(res, 400, "path: give the directory") if req.params[:path].to_s.empty?
            error!(res, 400, "plan_id: check the plan first") if step == "apply" && req.params[:plan_id].to_s.empty?

            status, body = Busyyaks::SetupAPI.projects_root(step: step, path: req.params[:path].to_s,
                                                            plan_id: req.params[:plan_id]&.to_s)
            json(res, body, status: status)
          end
        end
      end
    end
  end
end
