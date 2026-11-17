# frozen_string_literal: true

# Standalone (no test_helper, no app): bin/setup is a host program (POSIX sh); this file runs on the oldest
# host Ruby (scripts/ci/test.sh host). The Ruby-free replay of the README Quickstart is scripts/ci/quickstart-test.
require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "etc"
require_relative "../../lib/busyyaks/env_file"

# bin/setup in a copy of the checkout's files it reads: what it copies, writes, lists, creates and refuses.
class SetupTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FILES = %w[bin/setup .env.example docker-compose.yml config/busyyaks.example.yml config/kanban.example.yml].freeze
  E = Busyyaks::EnvFile

  def setup
    # under this user's home, never /tmp: LAUNCHER_RUN_DIR's ancestors must not be writable by another user (bin/setup
    # check refuses that, as bin/launcher does)
    @tmp = File.realpath(Dir.mktmpdir("setup-test", Etc.getpwuid(Process.uid).dir))
    @dir = File.join(@tmp, "checkout")
    FILES.each do |f|
      FileUtils.mkdir_p(File.join(@dir, File.dirname(f)))
      FileUtils.cp(File.join(ROOT, f), File.join(@dir, f), preserve: true)
    end
    @bin = File.join(@tmp, "bin")
    @home = File.join(@tmp, "home")
    FileUtils.mkdir_p([@bin, @home])
    # docker: records its argv, exits DOCKER_EXIT (compose config's answer)
    File.write(File.join(@bin, "docker"), "#!/bin/sh\necho \"$*\" >> \"#{@tmp}/docker.log\"\nexit \"${DOCKER_EXIT:-0}\"\n")
    File.chmod(0o755, File.join(@bin, "docker"))
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def setup!(*args, docker: true, exit_code: 0)
    path = [(@bin if docker), "/usr/local/bin", "/usr/bin", "/bin"].compact.join(":")
    out, err, st = Open3.capture3({ "PATH" => path, "DOCKER_EXIT" => exit_code.to_s, "HOME" => @home },
                                  File.join(@dir, "bin/setup"), *args, chdir: @tmp)
    [st.exitstatus, out, err]
  end

  def env = E.read(File.join(@dir, ".env"))

  def fill(values)
    text = File.read(File.join(@dir, ".env"))
    values.each { |k, v| text = text.sub(/^#{k}=.*$/, "#{k}=#{v}") }
    File.write(File.join(@dir, ".env"), text)
  end

  def filled
    FileUtils.mkdir_p(projects = File.join(@tmp, "projects"))
    { "PROJECTS_ROOT" => projects, "LAUNCHER_RUN_DIR" => File.join(@tmp, "state/run"), "GITHUB_LOGIN" => "octocat",
      "GITHUB_TOKEN" => "ghp_x", "TEAM_TERMINAL_URL" => "http://127.0.0.1:8080/",
      "SSH_ATTACH_TEMPLATE" => '"ssh -t devbox tmux attach -t {session}"', }
  end

  def test_first_run_copies_writes_the_secrets_and_lists_exactly_the_empty_required_keys
    code, out, err = setup!
    assert_equal [0, ""], [code, err]
    %w[.env config/busyyaks.yml config/kanban.yml].each { |f| assert File.file?(File.join(@dir, f)), f }
    assert_equal 0o600, File.stat(File.join(@dir, ".env")).mode & 0o777, ".env holds the secrets"
    e = env
    assert_match(/\A\h{128}\z/, e["SESSION_SECRET"])
    assert_match(/\A\h{64}\z/, e["MCP_TOKEN"])
    assert_match(/\A\h{64}\z/, e["MCP_REPORT_TOKEN"])
    refute_equal e["MCP_TOKEN"], e["MCP_REPORT_TOKEN"]
    assert_equal [Process.uid.to_s, Process.gid.to_s], e.values_at("HOST_UID", "HOST_GID")
    # the same list as the Ruby side's reading of docker-compose.yml (EnvFile.compose_required)
    empty = E.compose_required(File.read(File.join(@dir, "docker-compose.yml"))).select { e[_1].to_s.empty? }
    assert_equal %w[GITHUB_LOGIN GITHUB_TOKEN LAUNCHER_RUN_DIR PROJECTS_ROOT SSH_ATTACH_TEMPLATE TEAM_TERMINAL_URL], empty
    assert_equal empty, out[/Fill in .env.*\z/m].lines.drop(1).map(&:strip)
  end

  # a second run keeps every file and every value already there; a set secret is never replaced
  def test_a_second_run_keeps_what_is_there
    setup!
    fill("HOST_UID" => "4242", "SESSION_SECRET" => "mine")
    before = File.read(File.join(@dir, ".env"))
    code, out, = setup!
    assert_equal 0, code
    assert_equal before, File.read(File.join(@dir, ".env"))
    assert_includes out, "kept     .env (already there)"
    assert_includes out, "kept     SESSION_SECRET (set)"
  end

  def test_check_names_every_empty_required_key_and_creates_nothing
    setup!
    code, _, err = setup!("check")
    assert_equal 1, code
    %w[GITHUB_LOGIN GITHUB_TOKEN LAUNCHER_RUN_DIR PROJECTS_ROOT SSH_ATTACH_TEMPLATE TEAM_TERMINAL_URL].each do |k|
      assert_includes err, "FAIL  #{k} is empty in .env"
    end
    assert_includes err, "6 problem(s)"
    refute File.exist?(File.join(@dir, "data"))
    refute File.exist?(File.join(@tmp, "docker.log")), "compose is not asked while .env is incomplete"
  end

  def test_check_with_every_value_creates_data_and_the_run_dir_then_asks_compose
    setup!
    fill(v = filled)
    code, out, err = setup!("check")
    assert_equal [0, ""], [code, err]
    assert_equal 0o700, File.stat(v["LAUNCHER_RUN_DIR"]).mode & 0o777
    assert File.directory?(File.join(@dir, "data"))
    assert_equal "compose config -q\n", File.read(File.join(@tmp, "docker.log"))
    assert_includes out, "Next: docker compose up -d --build --wait web mcp scanner github notifier"
  end

  def test_check_refuses_what_compose_or_the_launcher_would_trip_on
    setup!
    v = filled
    File.symlink(v["PROJECTS_ROOT"], link = File.join(@tmp, "link"))
    fill(v.merge("PROJECTS_ROOT" => link, "LAUNCHER_RUN_DIR" => "state/run", "HOST_UID" => Process.uid + 1))
    code, _, err = setup!("check")
    assert_equal 1, code
    assert_includes err, "HOST_UID:HOST_GID is #{Process.uid + 1}:#{Process.gid}, this user is #{Process.uid}:#{Process.gid}"
    assert_includes err, "PROJECTS_ROOT #{link} is not its real path: write #{v['PROJECTS_ROOT']}"
    assert_includes err, "LAUNCHER_RUN_DIR must be an absolute path, written out (got state/run)"
    fill(v.merge("PROJECTS_ROOT" => File.join(@tmp, "nope")))
    _, _, err = setup!("check")
    assert_includes err, "PROJECTS_ROOT #{@tmp}/nope is not a directory"
  end

  # the minimums the app refuses to boot under, refused before compose; an empty secret points at bin/setup
  def test_check_refuses_the_secrets_the_app_would_refuse
    setup!
    fill(filled.merge("SESSION_SECRET" => "a" * 63, "MCP_TOKEN" => "t" * 40, "MCP_REPORT_TOKEN" => "t" * 40))
    code, _, err = setup!("check")
    assert_equal 1, code
    assert_includes err, "SESSION_SECRET is 63 bytes, the web app needs at least 64: empty it in .env and run bin/setup"
    assert_includes err, "MCP_REPORT_TOKEN equals MCP_TOKEN"
    fill("SESSION_SECRET" => "a" * 64, "MCP_REPORT_TOKEN" => "r" * 31)
    _, _, err = setup!("check")
    assert_includes err, "MCP_REPORT_TOKEN is 31 characters, the MCP server needs at least 32"
    refute_includes err, "SESSION_SECRET"
    fill("MCP_REPORT_TOKEN" => "")
    _, _, err = setup!("check")
    assert_includes err, "FAIL  MCP_REPORT_TOKEN is empty in .env: run bin/setup (it writes the secrets)"
  end

  # bin/setup's minimums are the app's: read from the Ruby source (this file runs without the app)
  def test_the_minimums_are_the_apps
    setup = File.read(File.join(ROOT, "bin/setup"))
    { "MIN_SESSION_SECRET_BYTES" => ["lib/busyyaks/session_cookie.rb", "MIN_SECRET_BYTES"],
      "MIN_MCP_TOKEN_CHARS" => ["lib/busyyaks/mcp_server.rb", "MIN_TOKEN_CHARS"], }.each do |sh, (file, const)|
      ruby = File.read(File.join(ROOT, file))[/^\s*#{const} = (\d+)$/, 1]
      refute_nil ruby, "#{file} #{const}"
      assert_equal ruby, setup[/^#{sh}=(\d+)/, 1], sh
    end
  end

  # the services' timing is Settings → Runtime; a .env line left over would look like it still sets it
  def test_the_moved_runtime_keys_are_the_apps_and_a_leftover_is_refused
    ruby = File.read(File.join(ROOT, "lib/busyyaks/runtime_settings.rb")).scan(/^\s*"[a-z_]+" => \["([A-Z_]+)", /).flatten
    assert_equal 6, ruby.size
    assert_equal ruby, File.read(File.join(ROOT, "bin/setup"))[/^RUNTIME_MOVED="([A-Z_ ]+)"$/, 1].split
    ruby.each { |k| refute_match(/^#{k}=/, File.read(File.join(ROOT, ".env.example")), k) }
    setup!
    fill(filled)
    File.write(File.join(@dir, ".env"), "#{File.read(File.join(@dir, '.env'))}SCAN_INTERVAL_SECONDS=60\n")
    code, _, err = setup!("check")
    assert_equal 1, code
    # the import needs web, which compose starts without bin/setup check: the order is web alone → import → delete
    assert_includes err, "FAIL  SCAN_INTERVAL_SECONDS moved to Settings → Runtime: start web alone " \
                         "(docker compose up -d --wait web: it migrates), import your values " \
                         "(docker compose exec -T web bin/runtime-settings import-env < .env), then delete the line " \
                         "from .env (docs/DEPLOY.md § Runtime settings)"
    refute File.exist?(File.join(@tmp, "docker.log")), "refused before compose"
    text = File.read(File.join(@dir, ".env")).sub(/^SCAN_INTERVAL_SECONDS=60\n/, "export WATCHDOG_GRACE_SECONDS=60\n")
    File.write(File.join(@dir, ".env"), text)
    _, _, err = setup!("check")
    assert_match(/FAIL  \.env line \d+: not KEY=value/, err, "an export line is refused by the shape check, as EnvFile does")
  end

  def test_check_refuses_a_short_mcp_token_and_the_databases_empty_keys
    setup!
    fill(filled.merge("MCP_TOKEN" => "short"))
    code, _, err = setup!("check")
    assert_equal 1, code
    assert_includes err, "MCP_TOKEN is 5 characters, the MCP server needs at least 32"
    refute File.exist?(File.join(@tmp, "docker.log")), "refused before compose"
    fill("MCP_TOKEN" => "m" * 32, "DATABASE_ADAPTER" => "postgresql", "DICTATION_TOKEN" => '"a b"')
    _, _, err = setup!("check")
    assert_includes err, "POSTGRES_PASSWORD is empty in .env: DATABASE_ADAPTER=postgresql needs it"
    assert_includes err, "DICTATION_TOKEN has whitespace"
  end

  # LauncherRules.run_dir!'s rules, checked before anything is made: a world-writable ancestor (a sticky /tmp too), a
  # symlinked one, a dir inside PROJECTS_ROOT / the checkout; an existing dir open to others
  def test_check_refuses_a_run_dir_the_launcher_would_refuse
    setup!
    v = filled
    FileUtils.mkdir_p(open = File.join(@tmp, "open"))
    File.chmod(0o1777, open)
    File.symlink(@tmp, link = File.join(@tmp, "link"))
    [["#{open}/run", "its parent #{open} is writable by group / other (mode 1777)"],
     ["#{link}/state/run", "#{link} is a symlink"],
     ["#{v['PROJECTS_ROOT']}/run", "is inside #{v['PROJECTS_ROOT']}"],
     ["#{@dir}/run", "is inside #{@dir}"],].each do |run, why|
      fill(v.merge("LAUNCHER_RUN_DIR" => run))
      code, _, err = setup!("check")
      assert_equal 1, code, run
      assert_includes err, why
      refute File.exist?(run), "nothing made: #{run}"
    end
    FileUtils.mkdir_p(wide = File.join(@tmp, "wide/run"))
    File.chmod(0o755, wide)
    fill(v.merge("LAUNCHER_RUN_DIR" => wide))
    _, _, err = setup!("check")
    assert_includes err, "LAUNCHER_RUN_DIR #{wide} is mode 755: open to group / other"
  end

  # compose has the last word on .env; no docker → named, never skipped
  def test_check_fails_with_compose_or_without_docker
    setup!
    fill(filled)
    code, _, err = setup!("check", exit_code: 15)
    assert_equal 1, code
    assert_includes err, "docker compose config refused .env"
    code, _, err = setup!("check", docker: false)
    assert_equal 1, code
    assert_includes err, "docker is not on PATH"
  end

  # an existing .env gets 0600 from bin/setup; check refuses one others can read (it holds the secrets)
  def test_the_env_file_is_readable_by_its_user_only
    setup!
    fill(filled)
    File.chmod(0o644, File.join(@dir, ".env"))
    code, _, err = setup!("check")
    assert_equal 1, code
    assert_includes err, "FAIL  .env has mode 644 and holds the secrets: chmod 600 .env"
    code, out, = setup!
    assert_equal 0, code
    assert_includes out, "chmod    .env 600"
    assert_equal 0o600, File.stat(File.join(@dir, ".env")).mode & 0o777
    assert_equal 0, setup!("check").first
  end

  # the quoting EnvFile refuses — an unclosed quote, a quote inside, text after the closing quote, a backslash inside
  # double quotes — bin/setup check refuses too, each line named; the quoted shapes EnvFile takes pass
  def test_the_quotes_env_file_refuses_are_refused_here
    setup!
    fill(filled)
    path = File.join(@dir, ".env")
    good = File.read(path)
    bad = {
      "Q_UNCLOSED" => ['"open', "an unclosed quote"],
      "Q_INSIDE" => ["'it's'", "an unclosed quote"],
      "Q_AFTER" => ['"x"y', "an unclosed quote"],
      "Q_BACKSLASH" => ['"a\\b"', "a backslash inside double quotes"],
    }
    bad.each do |key, (raw, why)|
      File.write(path, "#{good}#{key}=#{raw}\n")
      assert_raises(Busyyaks::EnvFile::Invalid, key) { Busyyaks::EnvFile.read(path) }
      code, _, err = setup!("check")
      assert_equal 1, code, key
      assert_match(/line \d+: #{key}: #{why}/, err)
    end
    File.write(path, "#{good}Q_DOUBLE=\"a b # c\"\nQ_SINGLE='a\\b'\n")
    Busyyaks::EnvFile.read(path)
    assert_equal 0, setup!("check").first
  end

  # what lib/busyyaks/env_file.rb refuses, bin/setup refuses too: init writes nothing, check names each line
  def test_the_shapes_env_file_refuses_are_refused_here
    setup!
    fill(filled)
    path = File.join(@dir, ".env")
    good = File.read(path)
    File.write(path, "#{good}TZ=UTC\nWEIRD LINE\nDICTATION_URL=http://$HOST\nPUBLIC_HOST=x # a comment\n")
    code, _, err = setup!("check")
    assert_equal 1, code
    assert_includes err, "a key given twice: TZ"
    assert_match(/line \d+: not KEY=value/, err)
    assert_match(/line \d+: DICTATION_URL holds a dollar sign/, err)
    assert_match(/line \d+: PUBLIC_HOST: an unquoted value with a space or an inline " #" comment/, err)
    bad = File.read(path)
    code, _, err = setup!
    assert_equal 1, code
    assert_includes err, "a key given twice: TZ"
    assert_equal bad, File.read(path), "init writes nothing into a file it refuses"
    # the shapes it takes: quoted values with spaces, `#` and `{…}` inside quotes, comment lines
    File.write(path, good)
    assert_equal 0, setup!("check").first
  end

  # the compose PostgreSQL's binds (docker-compose.yml postgres) are the user's before its first start
  def test_check_creates_the_postgres_dirs_with_the_profile
    setup!
    fill(filled)
    assert_equal 0, setup!("check").first
    refute File.exist?(File.join(@dir, "data/postgres")), "no profile: nothing made for it"
    fill("COMPOSE_PROFILES" => "postgres")
    assert_equal 0, setup!("check").first
    %w[data/postgres data/postgres-run].each { assert File.directory?(File.join(@dir, _1)), _1 }
  end

  # a secret reaches the file through awk's environment, never a command line
  def test_secrets_never_go_on_a_command_line
    put = File.read(File.join(ROOT, "bin/setup"))[/^put\(\) \{.*?^\}/m]
    assert_includes put, 'SETUP_VALUE=$2 awk'
    refute_match(/\$2[^\n]*"\s*"\$env_file"/, put.sub("SETUP_VALUE=$2 awk", ""), "the value is only in the env")
  end

  def test_check_before_setup_and_a_bad_argument
    code, _, err = setup!("check")
    assert_equal 1, code
    assert_includes err, "FAIL  .env is missing: run bin/setup"
    assert_equal 2, setup!("bogus").first
  end

  def collector_paths = File.read(File.join(@dir, "config/busyyaks.yml"))[/^agents:\n(?:  .*\n)+/]

  # a fresh config/busyyaks.yml gets agents.collector's paths under this user's HOME (the example says /home/you);
  # a kept one is never rewritten
  def test_first_run_puts_the_collector_paths_under_home
    _, out, = setup!
    assert_includes out, "wrote    agents.collector paths under #{@home}"
    assert_includes collector_paths, "    snapshot: #{@home}/.local/state/busyyaks/collector/sessions.json\n"
    assert_includes collector_paths, "    read_socket: #{@home}/.local/state/busyyaks/collector/read.sock\n"
    refute_includes collector_paths, "/home/you/"
    _, out, = setup!
    refute_includes out, "agents.collector paths"
  end

  # check names a collector path deploy/install-collector.sh would stop on with a bare mkdir (card #479)
  def test_check_names_a_collector_path_it_cannot_use
    setup!
    fill(filled)
    cfg = File.join(@dir, "config/busyyaks.yml")
    good = File.read(cfg)
    File.write(cfg, good.gsub("#{@home}/", "/home/you/"))
    code, _, err = setup!("check")
    assert_equal 1, code
    assert_includes err, "agents.collector.snapshot is the example's /home/you/.local/state/busyyaks/collector/sessions.json"
    assert_includes err, "agents.collector.read_socket is the example's /home/you/"
    File.write(ro = File.join(@tmp, "a-file"), "") # a file where a dir should be (refused for root too)
    File.write(cfg, good.gsub("#{@home}/.local/state", ro).sub(/^    read_socket: \S+/, "    read_socket: rel/read.sock"))
    _, _, err = setup!("check")
    assert_includes err, "agents.collector.snapshot #{ro}/busyyaks/collector/sessions.json: " \
                         "its dir cannot be created by you (#{ro} is not a dir"
    assert_includes err, "agents.collector.read_socket must be an absolute path (got rel/read.sock)"
    File.write(cfg, good.sub(/^agents:\n(?:  .*\n)+/, "agents:\n  collector: none\n"))
    assert_equal 0, setup!("check").first
    File.write(cfg, good)
    assert_equal 0, setup!("check").first
  end
end
