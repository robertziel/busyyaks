# frozen_string_literal: true

module Busyyaks
  module Actions
    module API
      module Reports
        # GET /api/reports/components — the component gallery: each tl:* example rendered server-side beside its source.
        class Components < Busyyaks::APIAction
          INLINE = "Repo `repo:blog` is `ok:pushed`, `repo:acme/shop` has `warn:69 dirty`, scan `bad:failed`, " \
                   "`info:note`, unknown `repo:nope`."

          def handle(_req, res)
            json(res, {
                   inline: { html: Busyyaks::Markdown.report(INLINE, store), source: INLINE },
                   components: ReportBlocks::CATALOG.map do |c|
                     src = "```tl:#{c[:name]}\n#{c[:example]}```\n"
                     { name: c[:name], summary: c[:summary], schema: c[:schema], source: src, html: Busyyaks::Markdown.report(src, store) }
                   end,
                 })
          end
        end
      end
    end
  end
end
