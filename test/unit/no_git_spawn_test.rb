# frozen_string_literal: true

require "test_helper"

# No long-lived process runs the git CLI on a scanned repo or loads libgit2 in-process (card #260): a repo's own config
# can make the CLI run programs, and a crafted repo can hang or bloat libgit2 — so every read is a GitRead child
# (bin/git-read) with its limits. This fails when a git spawn, an Open3 / system / backtick call or a `require "rugged"`
# appears in the code the web, mcp, scanner, github and notifier services run (and in the vendored engine).
class NoGitSpawnTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GLOBS = %w[lib/**/*.rb app/**/*.rb config/**/*.rb bin/scan bin/notifier bin/mcp bin/web bin/github bin/git-read
             config.ru mcp.ru vendor/agents_kanban/ruby/lib/**/*.rb].freeze
  SPAWN = Regexp.union(/\bOpen3\b|\bProcess\.spawn\b|\bsystem\(|\bexec\(|`[^`\n]*\bgit\b|%x[{(\[]/,
                       /\bIO\.popen\b|\bProcess\.fork\b|(?<![\w."':])fork\s*(?:\{|do\b|\(\))/)
  # the one spawner: GitRead runs the child (a Ruby VM on bin/git-read, never git)
  SPAWNERS = %w[lib/busyyaks/git_read.rb].freeze
  # the one file that loads libgit2: required only by bin/git-read (the child)
  RUGGED = %w[lib/busyyaks/git_reader.rb].freeze

  def files = GLOBS.flat_map { |g| Dir.glob(File.join(ROOT, g)) }.reject { |f| File.directory?(f) }.uniq
  def rel(f) = f.delete_prefix("#{ROOT}/")

  def code_lines(file) = File.readlines(file).each_with_index.reject { |l, _| l.lstrip.start_with?("#") }

  def test_no_process_spawn_outside_git_read
    hits = files.reject { |f| SPAWNERS.include?(rel(f)) }.flat_map do |f|
      code_lines(f).select { |l, _| l.match?(SPAWN) }.map { |l, i| "#{rel(f)}:#{i + 1}: #{l.strip}" }
    end
    assert_empty hits
    assert_match(/Process\.spawn\(CHILD_ENV, \*cmd, unsetenv_others: true/, File.read(File.join(ROOT, SPAWNERS.first)))
  end

  def test_rugged_is_loaded_only_by_the_child
    hits = files.reject { |f| RUGGED.include?(rel(f)) }.flat_map do |f|
      code_lines(f).select { |l, _|
 l.match?(/require\s*\(?\s*["']rugged["']|\bRugged::/) }.map { |l, i| "#{rel(f)}:#{i + 1}: #{l.strip}" }
    end
    assert_empty hits
    loaders = files.select { |f| code_lines(f).any? { |l, _|
 l.match?(%r{require(_relative)?\s+["'](busyyaks/|\./|\.\./lib/busyyaks/)?git_reader["']}) } }
    assert_equal ["bin/git-read"], loaders.map { |f| rel(f) }
  end
end
