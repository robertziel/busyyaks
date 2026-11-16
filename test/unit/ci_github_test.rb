# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "json"

# scripts/ci/github (the Jenkinsfile's default-branch + commit-status calls) against a fake curl that answers like
# GitHub: it writes the body to -o, prints -w's %{http_code}, keeps the Authorization header it read from the pipe and
# the posted data. The script runs by its own shebang, so one that loses `#!/usr/bin/env bash` (and `<(…)`) fails here.
class CiGithubTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "scripts/ci/github")
  TOKEN = "ghp_#{'t' * 36}".freeze
  SHA = "a" * 40
  REPO = { "id" => 1, "default_branch" => "local", "parent" => { "default_branch" => "main" } }.freeze

  def setup
    @dir = Dir.mktmpdir("ci-github")
    FileUtils.mkdir_p(File.join(@dir, "bin"))
    File.write(File.join(@dir, "bin", "curl"), <<~SH)
      #!/usr/bin/env bash
      n=$(( $(cat "#{@dir}/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "#{@dir}/calls"
      printf '%s\\n' "$@" > "#{@dir}/curl-argv"
      printf '%s\\n' "$@" > "#{@dir}/curl-argv.$n"
      out=/dev/null
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -o) out=$2; shift ;;
          -D) if [ -f "#{@dir}/headers.$n" ]; then cp "#{@dir}/headers.$n" "$2"; else : > "$2"; fi; shift ;;
          @/dev/fd/*) cat "${1#@}" > "#{@dir}/curl-header" ;;
          --data-binary) [ "$2" = @- ] && tee "#{@dir}/curl-data.$n" > "#{@dir}/curl-data"; shift ;;
        esac
        shift
      done
      [ "${FAKE_RC:-0}" = 0 ] || { echo "curl: (${FAKE_RC}) Failed to connect" >&2; printf '000'; exit "$FAKE_RC"; }
      if [ -f "#{@dir}/body.$n" ]; then cat "#{@dir}/body.$n" > "$out"; else cat "#{@dir}/body" > "$out"; fi
      if [ -f "#{@dir}/code.$n" ]; then cat "#{@dir}/code.$n"; else printf '%s' "$FAKE_CODE"; fi
    SH
    File.chmod(0o755, File.join(@dir, "bin", "curl"))
  end

  def teardown = FileUtils.rm_rf(@dir)

  def run_github(*args, body: "", code: 200, rc: 0, token: TOKEN)
    File.write(File.join(@dir, "body"), body)
    env = { "GH_TOKEN" => token, "GH_REPO" => "owner/repo", "GIT_SHA" => SHA, "BUILD_URL" => "https://ci/job/1/",
            "PATH" => "#{@dir}/bin:#{ENV.fetch('PATH')}", "FAKE_CODE" => code.to_s, "FAKE_RC" => rc.to_s, }
    out, err, status = Open3.capture3(env, SCRIPT, *args, chdir: @dir)
    refute_includes out + err, TOKEN, "the token was printed"
    argv = File.join(@dir, "curl-argv")
    refute_includes File.read(argv), TOKEN, "the token was on curl's command line" if File.exist?(argv)
    [out, err, status]
  end

  def header = File.read(File.join(@dir, "curl-header"))

  def test_runs_by_its_bash_shebang
    assert_equal "#!/usr/bin/env bash\n", File.open(SCRIPT, &:gets)
    assert File.executable?(SCRIPT)
  end

  def test_default_branch_reads_the_repo_s_own_branch_through_a_pipe
    out, _e, status = run_github("default-branch", body: JSON.pretty_generate(REPO))

    assert_predicate status, :success?
    assert_equal "local\n", out
    assert_equal "Authorization: Bearer #{TOKEN}", header
    assert_match(%r{^@/dev/fd/\d+$}, File.read(File.join(@dir, "curl-argv")))
  end

  def test_default_branch_of_a_fork_on_one_line_is_its_own_not_the_parent_s
    out, _e, status = run_github("default-branch", body: { "parent" => { "default_branch" => "main" },
                                                           "default_branch" => "local", }.to_json)

    assert_predicate status, :success?
    assert_equal "local\n", out
  end

  def test_default_branch_from_a_body_over_200_kb
    out, _e, status = run_github("default-branch", body: JSON.pretty_generate(REPO.merge("pad" => "x" * 300_000)))

    assert_predicate status, :success?
    assert_equal "local\n", out
  end

  def test_default_branch_missing_says_so
    _o, err, status = run_github("default-branch", body: { "id" => 1 }.to_json)

    refute_predicate status, :success?
    assert_match(%r{GitHub's answer for owner/repo holds no default_branch}, err)
  end

  def test_default_branch_not_json_says_so
    _o, err, status = run_github("default-branch", body: "<html>")

    refute_predicate status, :success?
    assert_match(/holds no default_branch/, err)
  end

  def test_default_branch_on_a_refused_token_says_so
    _o, err, status = run_github("default-branch", body: { "message" => "Bad credentials" }.to_json, code: 401)

    refute_predicate status, :success?
    assert_match(%r{HTTP 401 reading owner/repo \(Bad credentials\) — check credential github-pat}, err)
  end

  def test_default_branch_unreachable_says_so
    _o, err, status = run_github("default-branch", rc: 7)

    refute_predicate status, :success?
    assert_match(%r{cannot reach GitHub to read owner/repo — check the network}, err)
  end

  def test_a_token_that_is_not_token_shaped_is_refused_without_printing_it
    _o, err, status = run_github("default-branch", token: "ghp_x y\"z")

    refute_predicate status, :success?
    assert_match(/GH_TOKEN has characters a GitHub token never has — check credential github-pat/, err)
    refute_match(/x y/, err)
    refute_path_exists File.join(@dir, "curl-argv"), "GitHub was called with a bad token"
  end

  def test_status_posts_the_payload_as_json
    out, _e, status = run_github("status", "success", %(Gates "passed" — 100 %), body: "{}", code: 201)

    assert_predicate status, :success?
    assert_equal "github: status success posted for aaaaaaaa\n", out
    assert_equal({ "context" => "jenkins/ci", "description" => %(Gates "passed" — 100 %), "state" => "success",
                   "target_url" => "https://ci/job/1/", }, JSON.parse(File.read(File.join(@dir, "curl-data"))))
    assert_match(%r{^https://api\.github\.com/repos/owner/repo/statuses/#{SHA}$}, File.read(File.join(@dir, "curl-argv")))
    assert_equal "Authorization: Bearer #{TOKEN}", header
  end

  def test_status_refused_says_why
    _o, err, status = run_github("status", "failure", "x", body: { "message" => "Not Found" }.to_json, code: 404)

    refute_predicate status, :success?
    assert_match(%r{refused status failure for owner/repo@#{SHA} \(HTTP 404: Not Found\) — check credential github-pat},
                 err)
  end

  def test_status_unreachable_says_so
    _o, err, status = run_github("status", "pending", "x", rc: 6)

    refute_predicate status, :success?
    assert_match(/cannot reach GitHub to post status pending .* — check the network/, err)
  end

  def test_status_refuses_an_unknown_state
    _o, err, status = run_github("status", "green", "x")

    refute_predicate status, :success?
    assert_match(/'green' is not a GitHub status state/, err)
  end

  # — (3 bytes) catches a byte cut; é (U+00E9, which perl prints as one Latin-1 byte without ->utf8) a missing encode
  def test_status_cuts_the_description_at_140_characters_never_inside_one
    %w[— é].each do |char|
      _o, _e, status = run_github("status", "success", "#{'x' * 139}#{char} and more", body: "{}", code: 201)

      assert_predicate status, :success?
      sent = File.read(File.join(@dir, "curl-data"), encoding: "UTF-8")
      assert_predicate sent, :valid_encoding?, "#{char}: the payload is not UTF-8"
      assert_equal "#{'x' * 139}#{char}", JSON.parse(sent)["description"]
    end
  end

  def test_without_perl_json_pp_it_says_so
    File.write(File.join(@dir, "bin", "perl"), "#!/usr/bin/env bash\necho \"Can't locate JSON/PP.pm\" >&2\nexit 2\n")
    File.chmod(0o755, File.join(@dir, "bin", "perl"))
    %w[default-branch status].each do |cmd|
      _o, err, status = run_github(cmd, *(cmd == "status" ? %w[success x] : []))

      refute_predicate status, :success?
      assert_match(/perl with JSON::PP is needed to read and write GitHub's JSON/, err)
    end
    refute_path_exists File.join(@dir, "curl-argv"), "GitHub was called without a JSON parser"
  end

  # Every GitHub call goes through lib/github-api.sh's gh_curl: no other curl names a token or an Authorization header,
  # and the Jenkinsfile runs no curl at all. A Ruby script (libgit2-audit.rb) sets the header in-process with
  # Net::HTTP, where no argv sees it, and must spawn nothing: checked separately below.
  def test_no_token_reaches_curl_s_command_line_anywhere
    refute_match(/\bcurl\b|Authorization:/, File.read(File.join(ROOT, "Jenkinsfile")).gsub(%r{^\s*//.*$}, ""))
    Dir[File.join(ROOT, "scripts/ci/**/*")].select { |f| File.file?(f) }.each do |f|
      code = File.readlines(f).grep_v(/^\s*#/)
      # a Ruby script's in-process Net::HTTP header is the next test's; every other rule here covers .rb files too
      code.grep(/Authorization/).reject { f.end_with?(".rb") }.each do |l|
        assert_match(/^\s*curl -H @<\(printf 'Authorization: Bearer %s' "\$\{!var\}"\)/, l, "#{f}: #{l}")
      end
      code.grep(/(?<!gh_)\bcurl\b/).grep(/TOKEN/).each { |l| flunk("#{f}: a token next to a plain curl: #{l}") }
    end
  end

  # ── alert (the daily build's red reaches the maintainer as a GitHub issue notification) ──

  def answers(*list)
    list.each_with_index do |(body, code), i|
      File.write(File.join(@dir, "body.#{i + 1}"), body)
      File.write(File.join(@dir, "code.#{i + 1}"), code.to_s)
    end
  end

  def data(n) = JSON.parse(File.read(File.join(@dir, "curl-data.#{n}")))

  def test_alert_opens_an_issue_when_none_with_its_title_is_open
    answers([[{ "number" => 3, "title" => "Daily CI red on local", "pull_request" => {} },
              { "number" => 4, "title" => "other" },].to_json, 200,], ["{}", 201])
    out, err, status = run_github("alert", "Daily CI red on local", "audit exit 1")

    assert_predicate status, :success?, err
    assert_equal "github: alert opened as a new issue\n", out
    assert_match %r{repos/owner/repo/issues\?state=open}, File.read(File.join(@dir, "curl-argv.1"))
    assert_match %r{repos/owner/repo/issues$}, File.read(File.join(@dir, "curl-argv.2")).lines.last.strip
    assert_equal({ "title" => "Daily CI red on local", "body" => "audit exit 1\n\nBuild: https://ci/job/1/" }, data(2))
  end

  # GitHub pages the issue list (Link: rel="next"); an issue on page 2 is still found
  def test_alert_reads_every_page_of_open_issues
    page2 = "https://api.github.com/repositories/1/issues?state=open&per_page=100&page=2"
    answers([[{ "number" => 1, "title" => "a" }].to_json, 200],
            [[{ "number" => 9, "title" => "Daily CI red on local" }].to_json, 200], ["{}", 201])
    File.write(File.join(@dir, "headers.1"), "HTTP/2 200\r\nlink: <#{page2}>; rel=\"next\", <#{page2}>; rel=\"last\"\r\n\r\n")
    out, err, status = run_github("alert", "Daily CI red on local", "audit exit 1")

    assert_predicate status, :success?, err
    assert_equal "github: alert added to issue 9\n", out
    assert_equal page2, File.read(File.join(@dir, "curl-argv.2")).lines.last.strip
    assert_match %r{repos/owner/repo/issues/9/comments$}, File.read(File.join(@dir, "curl-argv.3")).lines.last.strip
  end

  def test_alert_comments_on_the_open_issue_with_its_title
    answers([[{ "number" => 7, "title" => "Daily CI red on local" }].to_json, 200], ["{}", 201])
    out, err, status = run_github("alert", "Daily CI red on local", "secrets exit 1")

    assert_predicate status, :success?, err
    assert_equal "github: alert added to issue 7\n", out
    assert_match %r{repos/owner/repo/issues/7/comments$}, File.read(File.join(@dir, "curl-argv.2")).lines.last.strip
    assert_equal({ "body" => "secrets exit 1\n\nBuild: https://ci/job/1/" }, data(2))
  end

  def test_alert_refused_or_unreadable_says_so
    answers(["{}", 200])
    _o, err, status = run_github("alert", "t", "x")
    assert_equal 1, status.exitstatus
    assert_match "github: GitHub's issue list for owner/repo is not a JSON array", err

    FileUtils.rm_f(Dir.glob(File.join(@dir, "{calls,body.*,code.*}")))
    answers(["[]", 200], [{ "message" => "Resource not accessible" }.to_json, 403])
    _o, err, status = run_github("alert", "t", "x")
    assert_equal 1, status.exitstatus
    assert_match "github: GitHub refused the alert on owner/repo (HTTP 403: Resource not accessible)", err
  end

  # ── fetch-base (the flake gate's base on a PR build, which checks out the PR head only) ──

  def test_fetch_base_fetches_the_branch_into_origin_s_remote_ref
    origin = File.join(@dir, "origin.git")
    git = ->(*a, chdir: @dir) {
 o, st = Open3.capture2e({ "GIT_CONFIG_GLOBAL" => "/dev/null" }, "git", *a, chdir: chdir); assert st.success?, o; o }
    git.("init", "-q", "--bare", "-b", "local", origin)
    work = File.join(@dir, "work")
    git.("clone", "-q", origin, work)
    git.("-c", "user.name=t", "-c", "user.email=t@x", "commit", "-q", "--allow-empty", "-m", "base", chdir: work)
    git.("push", "-q", "origin", "HEAD:local", chdir: work)
    sha = git.("rev-parse", "HEAD", chdir: work).strip
    pr = File.join(@dir, "pr")
    git.("init", "-q", pr)
    git.("remote", "add", "origin", origin, chdir: pr)

    env = { "GH_TOKEN" => TOKEN, "PATH" => ENV.fetch("PATH"), "GIT_CONFIG_GLOBAL" => "/dev/null" }
    out, status = Open3.capture2e(env, SCRIPT, "fetch-base", "local", chdir: pr)
    assert_predicate status, :success?, out
    assert_equal "github: base local at #{sha[0, 7]}\n", out
    assert_equal sha, git.("rev-parse", "refs/remotes/origin/local", chdir: pr).strip

    out, status = Open3.capture2e(env, SCRIPT, "fetch-base", "--upload-pack=x", chdir: pr)
    assert_equal 1, status.exitstatus
    assert_match "github: fetch-base: '--upload-pack=x' is not a branch name", out
  end
  def test_a_ruby_ci_script_sends_its_token_in_process_and_spawns_nothing
    Dir[File.join(ROOT, "scripts/ci/**/*.rb")].each do |f|
      code = File.readlines(f).grep_v(/^\s*#/).join
      next unless code.match?(/Authorization|TOKEN/)

      assert_includes code, "Net::HTTP",
"#{f}: an Authorization header only through Net::HTTP" if code.include?("Authorization")
      refute_match(/\b(system|spawn|exec|popen|capture[23]?e?)\b|`|%x/, code, "#{f}: a script holding a token spawns nothing")
    end
  end
end
