# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "rack/test"
require "busyyaks/config"
require "busyyaks/scanner"
require "busyyaks/mcp_server"

# card #262: a dry run of the daily report with the runner's tools only (the busyyaks MCP, no terminal, no git): a
# real repo is scanned, the report is drafted from daily_facts alone — shipped from subjects, the breaking flag from
# churn.commits' paths, uncommitted from dirty_paths — then check_report passes it and post_report stores it. A commit
# subject that looks like a command is only text in the facts.
class DailyReportDryRunTest < Minitest::Test
  include DBReset
  include Rack::Test::Methods

  TOKEN = "t" * 40
  HOSTILE = "fix $(touch /tmp/pwned) `id`"

  def app = Busyyaks::McpServer.new(token: TOKEN, report_token: "r" * 40, scan_interval: 60, store: store, config: nil)

  def tool(name, args = {})
    header "Authorization", "Bearer #{TOKEN}"
    post "/mcp", JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: args }),
         "CONTENT_TYPE" => "application/json"
    res = JSON.parse(last_response.body)["result"]
    refute res["isError"], res["content"][0]["text"]
    JSON.parse(res["content"][0]["text"])
  end

  def git(dir, *args)
    env = { "GIT_AUTHOR_NAME" => "n", "GIT_AUTHOR_EMAIL" => "me@x.io", "GIT_COMMITTER_NAME" => "n",
            "GIT_COMMITTER_EMAIL" => "me@x.io", }
    system(env, "git", "-C", dir, *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(' ')} failed"
  end

  def scan(root)
    config = Busyyaks::Config.new("roots" => [{ "path" => root, "prefix" => "" }], "search_depth" => 2,
                                  "owner_remotes" => ["github.com/me/"], "author_emails" => ["me@x.io"],
                                  "window_days" => 7, "reap_protect" => [], "auth" => { "provider" => "none" },
                                  "agents" => { "collector" => "none" },
                                  "launch" => { "trusted_paths" => [], "start_seconds" => 30 })
    Busyyaks::Scanner.new(config, store).run
  end

  def repo(root)
    d = File.join(root, "shop")
    Dir.mkdir(d)
    git(d, "init", "-q", "-b", "main")
    git(d, "remote", "add", "origin", "https://github.com/me/shop.git")
    FileUtils.mkdir_p("#{d}/db/migrate")
    File.write("#{d}/db/migrate/20260101_orders.rb", "x\n")
    git(d, "add", ".")
    git(d, "commit", "-qm", "Orders table")
    File.write("#{d}/README.md", "y\n")
    git(d, "add", ".")
    git(d, "commit", "-qm", HOSTILE)
    File.write("#{d}/wip.txt", "z")
  end

  # what the lead + children write, from the facts only (the prompt's steps 2 and 4)
  def draft(entry)
    migration = entry["churn"]["commits"].find { |c| c["paths"].any? { |p| p.start_with?("db/migrate/") } }
    shipped = entry["subjects"].map { |s| "- #{s}" }.join("\n")
    "```tl:stats\n- { label: Commits 24h, value: #{entry['commits']} }\n```\n\n" \
      "```tl:flags\n- { level: warn, kind: breaking, repo: #{entry['repo']}, sha: #{migration['sha']}, " \
      "text: \"migration\" }\n```\n\n`repo:#{entry['repo']}`\n\n#{shipped}\n\nUncommitted: #{entry['dirty_paths'].join(', ')}"
  end

  def test_a_report_from_the_mcp_data_alone
    mount = ENV.fetch("PROJECTS_MOUNT")
    Dir.mktmpdir do |root|
      ENV["PROJECTS_MOUNT"] = File.realpath(root) # churn reads repos under the mount only (GitRead)
      repo(root)
      assert_equal 1, scan(root)
      facts = tool("daily_facts", hours: 24, series: "Daily report")
      entry = facts["repos"].find { |r| r["repo"] == "shop" }
      assert_equal 2, entry["commits"]
      assert_equal ["?? wip.txt"], entry["dirty_paths"]
      assert_equal [["README.md"], ["db/migrate/20260101_orders.rb"]], entry["churn"]["commits"].map { |c| c["paths"] }.sort
      assert_equal entry["subjects"].map { |s| s[0, 9] }, entry["churn"]["commits"].map { |c| c["sha"] },
                   "churn.commits in the subjects' order"
      assert(entry["subjects"].any? { |s| s.end_with?(HOSTILE) }, "a subject is data, carried verbatim")

      body = draft(entry)
      check = tool("check_report", body_markdown: body)
      assert_empty check["broken"]
      assert_empty check["untracked_repos"]
      tool("post_report", title: "Daily report", body_markdown: body, author: "dry-run")
      assert_equal ["Daily report"], store.reports.map { |r| r[:title] }
      refute_path_exists "/tmp/pwned"
    end
  ensure
    ENV["PROJECTS_MOUNT"] = mount
  end
end
