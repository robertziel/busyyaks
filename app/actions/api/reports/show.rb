# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Reports
        # GET /api/reports/:id — one report rendered server-side, its headings, and its older/newer neighbours.
        class Show < Busyyaks::APIAction
          def handle(req, res)
            report = store.report(req.params[:id].to_i)
            error!(res, 404, "no report #{req.params[:id]}") unless report

            older, newer = store.neighbours(report)
            json(res, { report: Busyyaks::API.report(report, store),
                        older: older && Busyyaks::API.report_row(older, store),
                        newer: newer && Busyyaks::API.report_row(newer, store), })
          end
        end
      end
    end
  end
end
