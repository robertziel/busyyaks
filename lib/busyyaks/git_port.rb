# frozen_string_literal: true

require "json"
require "monitor"
require "set"
require_relative "git_read"

module Busyyaks
  # The vendored engine's `git:` port (AgentsKanban::CardLinks, SPEC § 1) and the PR flags' branch reader. No git runs
  # in the web process:
  #   branches / default_ref  what the scanner stored at its last read of the repo (projects.branches, .default_ref)
  #   files_at                one GitRead child (libgit2, its limits) per question, the answer kept per scan — a card
  #                           or report asks again only after the repo was scanned again
  # A project the scanner never read, or a read that fails, is Unavailable with the reason: the card shows it beside
  # the links it could build, never a branch list or file link that was guessed.
  class GitPort
    class Unavailable < StandardError; end

    CACHE_MAX = 2_000

    def initialize(root:)
      @root = root
      @cache = {}
      @lock = Monitor.new
    end

    def branches(project)
      raw = project[:branches] or raise Unavailable, "#{project[:slug]} has not been read by the scanner yet"

      JSON.parse(raw).to_set
    end

    def default_ref(project)
      project[:default_ref] or raise Unavailable, "#{project[:slug]} has not been read by the scanner yet"
    end

    def files_at(project, refs, files)
      key = [project[:path], project[:scanned_at], refs, files]
      @lock.synchronize { return @cache[key] if @cache.key?(key) }
      found = GitRead.call("files_at", path: project[:path], root: @root, refs: refs, files: files)["found"]
      @lock.synchronize do
        @cache.shift while @cache.size >= CACHE_MAX
        @cache[key] = found
      end
    rescue GitRead::Failed => e
      raise Unavailable, e.message
    end

    # The Links rail row that says why the checkout's links are missing or old (a tag + the reason on hover).
    def self.warning(project, why)
      { kind: "repo", label: "checkout", url: "/projects/#{project[:slug]}",
        tags: [{ text: "git", tone: "info" }, { text: "unknown", tone: "warn" }],
        detail: [{ label: "Why", value: why.to_s }], }
    end
  end
end
