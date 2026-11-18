# frozen_string_literal: true

require "erb"
require "busyyaks/kanban_api"

module Busyyaks
  module Actions
    module API
      module Attachments
        # GET /api/attachments/:id — a picture (png/jpeg/gif/webp) or a video (mp4/webm) inline; anything else (SVG and
        # HTML included) only as a download (Content-Disposition: attachment). Every response: nosniff + a CSP that allows
        # nothing and sandboxes, so even a file opened directly can never run. Content never changes for an id → cached
        # by its sha256, immutable. A single byte range (`Range: bytes=a-b`, `a-`, `-n`) answers 206 with only those
        # bytes — the video player seeks with it. Any other Range is refused 416 with the file's size: a range
        # past the end, another unit, and also several ranges (`bytes=0-1,4-5`). RFC 9110 § 14.2 would let a server
        # ignore those and send the whole file (200), or answer multipart/byteranges; the first hands a client that
        # asked for parts something else in their place (the no-fallbacks rule), and no client of this route sends
        # several ranges (the browsers' media players and download managers send one), so multipart is not built.
        # A matching If-None-Match answers 304 before any range is read.
        class Show < Busyyaks::Action
          include KanbanAPI

          def handle(req, res) = serve(req, res, download: false)

          RANGE = /\Abytes=(\d*)-(\d*)\z/

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
            res.headers["Accept-Ranges"] = "bytes"
            range = req.env["HTTP_RANGE"]
            return res.body = File.binread(found[:path]) unless range

            size = File.size(found[:path])
            first, last = byte_range(range.strip, size)
            unless first
              res.headers["Content-Range"] = "bytes */#{size}"
              return json(res, { error: "unsatisfiable range #{range[0, 80].inspect} (#{size} bytes)" }, status: 416)
            end

            res.status = 206
            res.headers["Content-Range"] = "bytes #{first}-#{last}/#{size}"
            res.body = File.open(found[:path], "rb") do |f|
              f.seek(first)
              f.read(last - first + 1)
            end
          end

          # [first, last] (inclusive) of ONE range inside a file of size bytes, or nil.
          def byte_range(header, size)
            return nil if size.zero? # no byte to name (the policy refuses empty files; a range of one is never 206)

            m = header.match(RANGE) or return nil
            a = m[1]
            b = m[2]
            return nil if a.empty? && b.empty?

            if a.empty?
              n = Integer(b, 10)
              return nil if n.zero?

              [[size - n, 0].max, size - 1]
            else
              first = Integer(a, 10)
              last = b.empty? ? size - 1 : [Integer(b, 10), size - 1].min
              first < size && first <= last ? [first, last] : nil
            end
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
