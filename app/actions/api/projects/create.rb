# frozen_string_literal: true

require "busyyaks/scanner"

module Busyyaks
  module Actions
    module API
      module Projects
        # POST /api/create {root, name, url} → host launcher makes the dir (git init) or starts a clone.
        # A new dir is scanned at once and its slug returned; a clone shows in the jobs list and the next scan.
        class Create < Busyyaks::APIAction
          def handle(req, res)
            r = LauncherClient.create(root: req.params[:root].to_s, name: req.params[:name].to_s, url: req.params[:url].to_s)
            rel = r["path"].to_s.delete_prefix("#{ENV.fetch('PROJECTS_MOUNT')}/")
            # trusted: whether bin/launcher answers this repo's folder-trust prompt (a git init it recorded; a clone never)
            return json(res, { cloning: true, path: rel, trusted: r["trusted"] }, status: 202) if r["cloning"]

            Scanner.new(Config.load, store).run
            slug = store.projects.find { |p| p[:path] == r["path"] }&.fetch(:slug)
            json(res, { cloning: false, path: rel, slug: slug, trusted: r["trusted"], trust_error: r["trust_error"] },
                 status: 201)
          end
        end
      end
    end
  end
end
