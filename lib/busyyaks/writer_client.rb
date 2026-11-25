# frozen_string_literal: true

require "socket"
require "json"

module Busyyaks
  # The web's line to the writer service (bin/writer) over its unix socket at WRITER_SOCKET: the workflow editor's
  # Save / Reset, which write `<repo>/.busyyaks/workflow.yml` (WorkflowFiles; card #429), and the project Settings
  # tab's Save, which writes `<repo>/.busyyaks/skills/agents/<type>.md` (AgentRuleFiles). No socket = Unavailable (503:
  # the writer is down, nothing was saved); sent but unanswered (a timeout, or the writer died after the request) =
  # NoAnswer (504: it may still apply) — never a save into the database alone.
  module WriterClient
    class Unavailable < StandardError; end
    # the request reached the writer but no answer came in time: it may still apply — the outcome is unknown (504)
    class NoAnswer < StandardError; end

    TIMEOUT = 30 # s: a save waits behind at most one sync pass's project

    module_function

    def workflow_save(slug, board, by:) = call({ op: "workflow_save", slug: slug, board: board, by: by })
    def workflow_reset(slug, by:) = call({ op: "workflow_reset", slug: slug, by: by })
    # the project page's Settings tab: the repo's .busyyaks/skills/agents/<type>.md files (AgentRuleFiles)
    def agent_rules_save(slug, files, by:) = call({ op: "agent_rules_save", slug: slug, files: files, by: by })
    # Settings → Agent rules: busyyaks's own skills files (SkillFiles), in the checkout the WRITER finds itself
    def skills_save(files, by:) = call({ op: "skills_save", files: files, by: by })

    # → [status, body] (the writer's answer)
    def call(req, timeout: TIMEOUT)
      sock = ENV.fetch("WRITER_SOCKET")
      UNIXSocket.open(sock) do |s|
        s.puts(JSON.generate(req))
        answer(s, timeout)
      end
    rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES, Errno::EPIPE => e
      raise Unavailable, "writer not reachable at #{sock}: #{e.class}"
    end

    # Once the request is sent, every failure is an unknown outcome: the writer may have applied it (NoAnswer).
    def answer(sock, timeout)
      raise NoAnswer, "did not answer within #{timeout} s" unless sock.wait_readable(timeout)

      res = JSON.parse(sock.gets.to_s)
      [Integer(res.fetch("status")), res.fetch("body")]
    rescue JSON::ParserError, KeyError, TypeError, SystemCallError, IOError, NoAnswer => e
      raise NoAnswer, "the writer #{e.is_a?(NoAnswer) ? e.message : "gave no answer (#{e.class})"}: the change " \
                      "may still apply — reload the editor to see the board"
    end
  end
end
