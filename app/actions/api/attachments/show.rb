# frozen_string_literal: true

require "erb"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Attachments
        # GET /api/attachments/:id — a picture (png/jpeg/gif/webp) inline; anything else (SVG and HTML included) only as a
        # download (Content-Disposition: attachment). Every response: nosniff + a CSP that allows nothing and sandboxes,
        # so even a file opened directly can never run. Content never changes for an id → cached by its sha256, immutable.
        class Show < Busyyaks::Action
          include KanbanAPI

          def handle(req, res) = serve(req, res, download: false)

          private

          def serve(req, res, download:)
            status, found = api(req).attachment_file(id(req), download: download)
            return json(res, found, status: status) unless status == 200

            a = found[:row]
            inline = found[:inline]
            etag = %("#{a[:sha256]}")
            res.headers["ETag"] = etag
            res.headers["Cache-Control"] = "private, max-age=31536000, immutable"
            res.headers["X-Content-Type-Options"] = "nosniff"
            res.headers["Content-Security-Policy"] = "default-src 'none'; sandbox"
            res.headers["Content-Disposition"] = disposition(inline ? "inline" : "attachment", a[:filename])
            servable = inline || !%w[image/svg+xml text/html].include?(a[:content_type])
            res.headers["Content-Type"] = servable ? type_header(a[:content_type]) : "application/octet-stream"
            if req.env["HTTP_IF_NONE_MATCH"].to_s.split(/\s*,\s*/).include?(etag)
              res.status = 304
              res.body = ""
              return
            end
            res.body = File.binread(found[:path])
          end

          def type_header(t) = t.start_with?("text/") || t == "application/json" ? "#{t}; charset=utf-8" : t

          # RFC 6266: an ASCII fallback (quotes, backslashes, controls, non-ASCII → "_") and the exact name as filename*.
          def disposition(kind, name)
            ascii = name.encode("US-ASCII", invalid: :replace, undef: :replace, replace: "_").gsub(/[^\x20-\x7e]|["\\%;]/, "_")
            %(#{kind}; filename="#{ascii}"; filename*=UTF-8''#{ERB::Util.url_encode(name)})
          end
        end
      end
    end
  end
end
