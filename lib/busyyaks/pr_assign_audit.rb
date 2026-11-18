# frozen_string_literal: true

module Busyyaks
  # A one-off report, for the operator to confirm by hand: the engine's Store#unassigned_pr_mentions — on every
  # open card, the PR URLs its own text names (pr_url, description, comments, handoffs) that are not assigned to it —
  # as text. Reads only: a PR is assigned by the agent that opened it (kanban_pr_assign), never derived from text.
  module PrAssignAudit
    module_function

    # a header, one tab-separated line per row, a count
    def text(rows)
      lines = rows.map { |r| r.values_at(:card, :project, :column, :url, :seen).join("\t") }
      ["card\tproject\tcolumn\tPR named but not assigned\tfirst named in", *lines,
       "#{rows.size} PR(s) on #{rows.map { |r| r[:card] }.uniq.size} card(s) — confirm each: the card's agent " \
       "assigns it with kanban_pr_assign, nothing here writes",].join("\n")
    end
  end
end
