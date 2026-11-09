# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Agents
        # POST /api/agents/answer {session, socket, hash, key} — the operator (web only, no MCP tool) answers the dialog
        # a session shows in the sidebar: the launcher presses `key` (an option digit / esc) ONLY while the screen still
        # shows the dialog with this hash (422 with the reason otherwise, nothing typed; 503 launcher down).
        class Answer < Busyyaks::APIAction
          def handle(req, res)
            p = req.params
            session = p[:session].to_s
            socket = p[:socket].to_s
            hash = p[:hash].to_s
            key = p[:key].to_s
            error!(res, 400, "session, socket, hash and key are required") if [session, socket, hash, key].any?(&:empty?)

            r = LauncherClient.answer(session: session, socket: socket, hash: hash, key: key)
            store.agent_seen!("#{socket}/#{session}")
            json(res, { pressed: r["pressed"] })
          end
        end
      end
    end
  end
end
