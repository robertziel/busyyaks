# auto_register: false
# frozen_string_literal: true

require_relative "action"

module Busyyaks
  # Base for /api/*: JSON in, JSON out. A launcher that is down or refuses is an error with a status, never a
  # quiet substitute: 503 unreachable, 422 refused, 404 unknown, 400 bad input.
  class APIAction < Action
    handle_exception LauncherClient::Unavailable => :launcher_unavailable
    handle_exception LauncherClient::Refused => :launcher_refused
    # the current agent settings revision does not run on the engine (e.g. a type under no lead): 503 with the
    # engine's reason — nothing is launched or registered on a config the engine refuses
    handle_exception Kanban::Unrunnable => :agent_settings_unrunnable

    private

    def json(res, body, status: 200)
      res.status = status
      res.headers["Content-Type"] = "application/json; charset=utf-8"
      res.headers["Cache-Control"] = "no-store"
      res.body = JSON.dump(body)
    end

    def error!(res, status, message)
      res.headers["Content-Type"] = "application/json; charset=utf-8"
      res.headers["Cache-Control"] = "no-store"
      halt status, JSON.dump(error: message)
    end

    def launcher_unavailable(_req, res, e) = json(res, { error: e.message }, status: 503)
    def launcher_refused(_req, res, e) = json(res, { error: e.message }, status: 422)
    def agent_settings_unrunnable(_req, res, e) = json(res, { error: e.message }, status: 503)

    # The engine's launches (agent types + who runs against the cap; config/kanban.yml is the ONE place a launch is
    # defined) + live tmux sessions per project path. The launcher being down is reported (launcher_error, and the
    # engine's sessions_error inside launches) next to the data that does not need it, never hidden.
    def launch_state
      launches = Kanban.api.launches.last
      { launches: launches, sessions: LauncherClient.sessions.group_by { |s| s["project_path"] }, launcher_error: nil }
    rescue LauncherClient::Unavailable, LauncherClient::Refused => e
      { launches: launches || Kanban.api.launches.last, sessions: {}, launcher_error: e.message }
    end

    def launch_json(state) = { launches: state[:launches], launcher_error: state[:launcher_error] }
  end
end
