# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Agents
        # POST /api/agents/seen {key} — the operator looked at this session (opened its row): its ended turn is no longer
        # unread (was "done").
        class Seen < Busyyaks::APIAction
          KEY = %r{\A[\w.-]{1,64}/[^\x00-\x1f]{1,200}\z}

          def handle(req, res)
            key = req.params[:key].to_s
            error!(res, 400, "key: <socket>/<session>") unless key.match?(KEY)

            store.agent_seen!(key)
            json(res, { key: key, seen: true })
          end
        end
      end
    end
  end
end
