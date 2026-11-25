# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/auto_loaded"

# busyyaks's skills reach a session per launch only (Claude Code --plugin-dir, hermes
# ${BUSYYAKS_SKILLS_DIR}); nothing busyyaks runs installs a skill or a plugin for every session of the user. An
# independent `claude` / `hermes` on the host starts as it did before busyyaks.
class NoGlobalSkillTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CODE = %w[bin/* lib/**/*.rb cli/**/*.rb deploy/* scripts/**/* config/**/*.rb].freeze
  # what would put a skill in a user-wide place: Claude Code's user skills / plugins, hermes's user skills
  USER_WIDE = [%r{\.claude/skills}, %r{\.claude/plugins}, /plugin\s+install/, /plugin\s+marketplace/,
               %r{\.hermes/skills}, /skills\s+install/, /hermes\s+skills\s+(?:trust|add)/,].freeze

  def files
    CODE.flat_map { |g| Dir.glob(File.join(ROOT, g)) }.select { |f| File.file?(f) }.uniq
  end

  def test_no_code_installs_a_skill_user_wide
    hits = files.flat_map do |f|
      File.binread(f).force_encoding(Encoding::UTF_8).scrub.lines.each_with_index.filter_map do |l, i|
        "#{f.delete_prefix("#{ROOT}/")}:#{i + 1}: #{l.strip}" if USER_WIDE.any? { |re| l.match?(re) }
      end
    end
    assert_empty hits
  end

  # the stage is the launcher's own state dir, a copy per session — never the checkout, the repo or a home dir
  def test_the_launcher_stages_under_its_state_dir
    src = File.read(File.join(ROOT, "bin/launcher"))
    assert_includes src, 'STAGES = File.join(STATE_DIR, "skills")'
    assert_includes src, "stage = File.join(STAGES, name)"
    refute_match(/--plugin-dir.*ROOT/, src)
  end

  # busyyaks's skills live in its layers only (skills/busyyaks, the deployment's skills-local, a repo's
  # .busyyaks/skills) — never in a dir Claude Code or hermes loads on its own for whoever opens the repo
  def test_the_skills_live_only_in_the_launch_layers
    auto = Dir.glob(File.join(ROOT, "{.claude/skills,.claude/commands,.claude-plugin,.hermes,.agents/skills}"),
                    File::FNM_DOTMATCH)
    assert_empty auto.map { |f| f.delete_prefix("#{ROOT}/") }, "a dir a CLI loads by itself"
    skills = Dir.glob(File.join(ROOT, "**/SKILL.md"), File::FNM_DOTMATCH).map { |f| f.delete_prefix("#{ROOT}/") }
                .reject { |f| f.start_with?("node_modules/", "frontend/node_modules/", "vendor/", "test/fixtures/") }
    assert_equal [], skills.grep_v(%r{\A(skills/busyyaks|skills-local|\.busyyaks/skills)/})
    assert File.file?(File.join(ROOT, "skills/busyyaks/core/SKILL.md")), "every session's core skill"
    gi = File.read(File.join(ROOT, ".gitignore")).lines.map(&:strip)
    refute_includes gi, "/.busyyaks/", "the repo's .busyyaks/skills must be committable (only workflow.yml is ignored)"
    assert_includes gi, "/.busyyaks/workflow.yml"
  end

  # --- docs/USE-CASES-session-isolation.md U1 + U7, the repo's side (the live run grepped the host's own files) -------

  def rel(f) = f.delete_prefix("#{ROOT}/")

  # A developer's local, ignored files are not this repo's code: the root's data/, tmp/, coverage/ and .git — only at
  # the root (a dir of that name deeper down is the repo's own and is read) —, an agent's .claude/worktrees, installed
  # node_modules (generated, at any depth), CLAUDE.local.md and .claude/settings.local.json
  ROOT_LOCAL = %w[data tmp coverage .git].freeze
  LOCAL_FILES = %w[CLAUDE.local.md .claude/settings.local.json].freeze

  def local?(path)
    parts = path.split("/")
    ROOT_LOCAL.include?(parts.first) || path == ".claude/worktrees" || path.start_with?(".claude/worktrees/") ||
      parts.include?("node_modules") || LOCAL_FILES.any? { |l| path == l || path.end_with?("/#{l}") }
  end
  def text(f) = File.binread(f).force_encoding(Encoding::UTF_8).scrub
  def glob(*globs) = globs.flat_map { |g| Dir.glob(File.join(ROOT, g), File::FNM_DOTMATCH) }.select { |f| File.file?(f) }.uniq

  def hits(files, patterns)
    files.flat_map do |f|
      text(f).lines.each_with_index.filter_map do |l, i|
        "#{rel(f)}:#{i + 1}: #{l.strip[0, 160]}" if patterns.any? { |re| l.match?(re) }
      end
    end
  end

  # what a user or a script reads as "register busyyaks for every session": a harness's MCP registered at its user scope
  # (Claude Code `claude mcp add … --scope user` / `-s user`, `mcp add-json` alike), Hermes / Codex `mcp add` (theirs
  # are user-wide only)
  USER_SCOPE = /(?:--scope[\s=]+user|\s-s\s+user)\b/
  USER_SCOPE_MCP = [/mcp\s+add(?:-json)?\b.*#{USER_SCOPE}/, /#{USER_SCOPE}.*mcp\s+add/,
                    /\b(?:hermes|codex)\s+mcp\s+add\b/,].freeze

  # U7, the operator: "nothing busyyaks in any global harness setting" — no doc, README, skill or script of this repo
  # tells a user or a script to register busyyaks's MCP user-wide (the live run removed the one ~/.claude.json held)
  def test_nothing_tells_a_user_or_a_script_to_register_busyyaks_with_a_harness_user_wide
    files = glob("*.md", "docs/**/*", "skills/**/*", "skills-local/**/*", "bin/*", "cli/**/*", "deploy/*", "scripts/**/*",
                 "lib/**/*.rb", "config/**/*", ".env.example")
    assert_operator files.size, :>, 50, "the scan reads the repo"
    assert_empty hits(files, USER_SCOPE_MCP)
  end

  # U7 + U1: installing or running busyyaks (bin/setup, the deploy installers, the yaks CLI) never writes a harness's
  # user config (~/.claude*, ~/.hermes, ~/.codex, …) nor a file a CLI loads by itself into a project (AGENTS.md,
  # CLAUDE.md, .mcp.json, …): none of them even names one
  def test_no_installer_writes_a_harness_config_or_a_file_a_cli_loads_by_itself
    files = glob("bin/setup", "bin/yaks", "bin/render-deploy", "deploy/**/*", "cli/**/*")
    assert_includes files.map { rel(_1) }, "bin/setup"
    names = AUTO_LOADED.map { |n| /(?<![\w-])#{Regexp.escape(n)}(?![\w-])/ }
    assert_empty hits(files, names)
  end

  # U1, the operator: "a session started from the terminal, not from busyyaks, should have no idea about any rules we've
  # got related to busyyaks" — the board workflow (kanban_handoff, kanban_spawn, kanban_claim, the approval flow) is
  # written in the skills only, which a launch stages per session; no file a CLI loads by itself, anywhere in this repo
  # (this repo's own CLAUDE.md documents the system), holds a sentence of them
  def test_the_board_workflow_lives_only_in_the_skills_never_in_a_file_a_cli_loads_by_itself
    skills = glob("skills/**/*.md", "skills-local/**/*.md")
    workflow = skills.map { text(_1) }.join("\n")
    %w[kanban_handoff kanban_spawn kanban_claim kanban_ask].each { |t| assert_includes workflow, "`#{t}", t }
    assert_includes workflow, "Never merge before the operator approves"
    norm = ->(t) { t.gsub(/[`*_|>#]/, " ").gsub(/\s+/, " ").strip.downcase }
    sentences = workflow.split(/(?<=[.:;!?])\s+|\n+/).map(&norm).select { _1.length >= 40 }.uniq
    assert_operator sentences.size, :>, 100
    auto = Dir.glob(File.join(ROOT, "**/*"), File::FNM_DOTMATCH)
              .reject { |f| local?(rel(f)) }
              .select { |f| rel(f).split("/").intersect?(AUTO_LOADED) }
    loaded = auto.select { File.file?(_1) }
    copied = loaded.flat_map { |f| norm.(text(f)).then { |t| sentences.select { t.include?(_1) }.map { "#{rel(f)}: #{_1}" } } }
    assert_empty copied, "a sentence of the board workflow in a file a CLI loads by itself"
    assert_empty loaded.map { rel(_1) } - ["CLAUDE.md"], "the one auto-loaded file of this repo documents the system"
  end

  # only the ROOT's data/, tmp/, coverage/, .git are left out: the same names deeper down are this repo's own files
  def test_only_the_roots_local_dirs_are_skipped
    %w[data/x/CLAUDE.md tmp/AGENTS.md coverage/a .git/HEAD .claude/worktrees/w/CLAUDE.md frontend/node_modules/x/AGENTS.md
       CLAUDE.local.md sub/CLAUDE.local.md .claude/settings.local.json].each { |p| assert local?(p), p }
    %w[lib/data/CLAUDE.md skills/tmp/AGENTS.md docs/coverage/CLAUDE.md sub/.git/x sub/worktrees/CLAUDE.md
       .claude/settings.json CLAUDE.md].each { |p| refute local?(p), p }
  end
end
