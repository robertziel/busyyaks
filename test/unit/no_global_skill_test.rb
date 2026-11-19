# frozen_string_literal: true

require "minitest/autorun"

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
end
