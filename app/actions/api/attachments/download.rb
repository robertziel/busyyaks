# frozen_string_literal: true

require_relative "show"

module Busyyaks
  module Actions
    module API
      module Attachments
        # GET /api/attachments/:id/download — always Content-Disposition: attachment (pictures too).
        class Download < Show
          def handle(req, res) = serve(req, res, download: true)
        end
      end
    end
  end
end
