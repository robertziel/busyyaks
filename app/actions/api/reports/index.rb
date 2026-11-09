# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Reports
        # GET /api/reports — the 200 newest reports: title, author, date, excerpt (no bodies).
        class Index < Busyyaks::APIAction
          def handle(_req, res)
            ctx = Busyyaks::Markdown.report_ctx(store)
            json(res, { reports: store.reports(limit: 200).map { |r| Busyyaks::API.report_row(r, store, ctx) } })
          end
        end
      end
    end
  end
end
