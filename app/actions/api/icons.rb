# frozen_string_literal: true

require "busyyaks/icons"

module Busyyaks
  module Actions
    module API
      # GET /api/icons/*slug — the repo's icon file (Busyyaks::Icons picked it at scan time), from the read-only
      # mount. Only that one recorded path, resolved inside the repo; an SVG is sandboxed (no script, no fetches)
      # so even opened directly it is a picture, not a document.
      class Icons < Busyyaks::APIAction
        def handle(req, res)
          p = store.project(req.params[:slug].to_s)
          error!(res, 404, "no project") unless p
          error!(res, 404, "no icon file in this repo") unless p[:icon_path]

          root = File.realpath(p[:path])
          file = File.realpath(File.join(p[:path], p[:icon_path]))
          error!(res, 404, "icon outside the repo") unless file.start_with?("#{root}/")
          error!(res, 413, "icon larger than #{Busyyaks::Icons::MAX_BYTES} bytes") if File.size(file) > Busyyaks::Icons::MAX_BYTES

          type = Busyyaks::Icons.type(file)
          res.headers["Content-Type"] = type
          res.headers["Cache-Control"] = "private, max-age=604800, immutable"
          res.headers["X-Content-Type-Options"] = "nosniff"
          if type == "image/svg+xml"
            res.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'; sandbox"
          end
          res.body = File.binread(file)
        rescue Errno::ENOENT, Errno::EACCES
          error!(res, 404, "icon file is gone (rescan pending)")
        end
      end
    end
  end
end
