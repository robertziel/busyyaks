# frozen_string_literal: true

require "open3"
require "busyyaks/clock"
require "busyyaks/kanban"
require "busyyaks/private_socket"
require "busyyaks/workflow_files"

# A writer service (bin/writer's socket side) on a thread of the test process, at this worker's WRITER_SOCKET, reading
# repos under `root` — the workflow editor's Save / Reset reach it through Busyyaks::WriterClient like the web does.
module WriterServer
  module_function

  def writer(root:, clock: -> { Busyyaks::Clock.epoch })
    db = Hanami.app["db.gateway"].connection
    Busyyaks::WorkflowFiles::Writer.new(db: db, store: -> { Busyyaks::Kanban.store(db) },
                                        api: ->(st) { Busyyaks::Kanban.api(st) }, root: root, clock: clock)
  end

  # → the bound socket (close it to stop the server)
  def start(root:)
    path = ENV.fetch("WRITER_SOCKET")
    File.unlink(path) if File.socket?(path)
    sock = Busyyaks::PrivateSocket.bind(path)
    Busyyaks::WorkflowFiles::Server.new(writer(root: root), sock).start
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
