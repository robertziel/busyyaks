# frozen_string_literal: true

require "open3"
require "busyyaks/clock"
require "busyyaks/config"
require "busyyaks/kanban"
require "busyyaks/private_socket"
require "busyyaks/workflow_files"

# A writer service (bin/writer's socket side) on a thread of the test process, at this worker's WRITER_SOCKET, reading
# repos under `root` — the workflow editor's Save / Reset reach it through Busyyaks::WriterClient like the web does.
module WriterServer
  module_function

  # checkout: the busyyaks checkout whose launch budget a project save is checked against (this repo by default)
  def writer(root:, clock: -> { Busyyaks::Clock.epoch }, skills: -> { Busyyaks::Config.load.skills }, own_skills: nil,
             checkout: File.expand_path("../..", __dir__), log: ->(_) {})
    db = Hanami.app["db.gateway"].connection
    Busyyaks::WorkflowFiles::Writer.new(db: db, store: -> { Busyyaks::Kanban.store(db) },
                                        api: ->(st) { Busyyaks::Kanban.api(st) }, skills: skills, root: root,
                                        checkout: checkout, clock: clock, own_skills: own_skills, log: log)
  end

  # → the bound socket (close it to stop the server)
  def start(root:, skills: -> { Busyyaks::Config.load.skills }, own_skills: nil,
            checkout: File.expand_path("../..", __dir__))
    path = ENV.fetch("WRITER_SOCKET")
    File.unlink(path) if File.socket?(path)
    sock = Busyyaks::PrivateSocket.bind(path)
    w = writer(root: root, skills: skills, own_skills: own_skills, checkout: checkout)
    Busyyaks::WorkflowFiles::Server.new(w, sock).start
    sock
  end

  def stop(sock)
    sock&.close
    path = ENV.fetch("WRITER_SOCKET")
    File.unlink(path) if File.socket?(path)
  end

  # an empty git repo at dir (the writer reads its ignore rules through a GitRead child)
  def git_init(dir)
    _, err, st = Open3.capture3({ "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1" },
                                "git", "-C", dir, "init", "-q", "-b", "main")
    raise "git init #{dir}: #{err}" unless st.success?
  end
end
