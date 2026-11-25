# frozen_string_literal: true

# What a coding-agent CLI loads by itself in the directory it is started in — the one list the tests check a
# project's directory against (a project's agent rules live in .busyyaks/, which none of them reads):
#   Claude Code   CLAUDE.md, CLAUDE.local.md, .claude/, .mcp.json
#   Codex         AGENTS.md, AGENTS.override.md, .codex/
#   Hermes        AGENTS.md, HERMES.md, .hermes.md, SOUL.md, .hermes/, .cursorrules
#   cross-CLI     .agents/, .cursor/
# The check is about NAMES, not location: Claude Code and Codex also read CLAUDE.md / AGENTS.md from every parent dir
# up to the root, and a rule file is safe there too — it lives under `.busyyaks/`, a name none of them reads anywhere.
AUTO_LOADED = %w[CLAUDE.md CLAUDE.local.md AGENTS.md AGENTS.override.md HERMES.md .hermes.md SOUL.md .cursorrules
                 .claude .mcp.json .codex .hermes .agents .cursor].freeze
