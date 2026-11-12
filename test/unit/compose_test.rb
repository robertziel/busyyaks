# frozen_string_literal: true

require "test_helper"
require "yaml"

# The compose file is deployment wiring: the `test` service must build its OWN image. Building and tagging
# the live stack's image (busyyaks:local) from it would mean that running the suite on a branch
# re-tags the live image with untested code, and bin/web migrates on start: a live recreate would migrate the
# live DB with a branch's migration.
class ComposeTest < Minitest::Test
  COMPOSE = YAML.safe_load_file(File.expand_path("../../docker-compose.yml", __dir__), aliases: true)

  # `yaks` names the stack's services in one constant: exactly the compose services without a profile
  def test_the_cli_services_are_the_profile_less_compose_services
    require_relative "../../cli/yaks"
    live = COMPOSE.fetch("services").reject { |_, s| s.key?("profiles") }.keys
    assert_equal live.sort, Busyyaks::CLI::SERVICES.sort
  end

  def test_the_test_service_never_tags_the_live_image
    services = COMPOSE.fetch("services")
    test = services.fetch("test")
    live = services.values_at("web", "mcp", "scanner", "github", "notifier").compact.map { |s| s["image"] }.uniq
    assert_equal ["busyyaks:local"], live, "the live services share one image"
    assert_equal "busyyaks:test", test["image"]
    refute_includes live, test["image"], "the test service must not tag the live image"
    assert_includes test.fetch("profiles"), "test"
  end

  # The live services run as the host user (.env HOST_UID/HOST_GID), never root: ./data stays the operator's, and the
  # launcher's 0600 socket is reachable from the containers that mount it.
  def test_live_services_run_as_the_host_user
    services = COMPOSE.fetch("services").values_at("web", "mcp", "scanner", "github", "notifier")
    assert_equal ["${HOST_UID:?}:${HOST_GID:?}"], services.map { |s| s["user"] }.uniq
    example = File.read(File.expand_path("../../.env.example", __dir__))
    assert_match(/^HOST_UID=\d+$/, example)
    assert_match(/^HOST_GID=\d+$/, example)
  end

  # .env PROJECTS_MOUNT is the one place the container's projects path is set: the mount, the env every service reads
  # (Config.load checks the roots against it, the launcher maps it back to PROJECTS_ROOT) and git's trust are all it.
  # git trusts a repo owned by another uid only under it — never every directory (no system-wide safe.directory '*').
  def test_projects_mount_is_single_sourced_and_the_only_trusted_path
    app = COMPOSE.fetch("x-app")
    env = app.fetch("environment")
    assert_includes app.fetch("volumes"), "${PROJECTS_ROOT:?}:${PROJECTS_MOUNT:?}:ro"
    assert_equal "${PROJECTS_MOUNT:?}", env.fetch("PROJECTS_MOUNT")
    # the host side of the mount, for the host paths git writes into a linked worktree's files (card #268)
    assert_equal "${PROJECTS_ROOT:?}", env.fetch("PROJECTS_ROOT")
    git = { "GIT_CONFIG_COUNT" => "11", "GIT_CONFIG_KEY_0" => "safe.directory",
            "GIT_CONFIG_VALUE_0" => "${PROJECTS_MOUNT:?}/*", }
    assert_equal(git, env.slice("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"))
    refute_match(/git config .*safe\.directory/, File.read(File.expand_path("../../Dockerfile", __dir__)))
  end

  # the MCP port's host address is .env MCP_HOST, the same value the host scripts call it on
  def test_mcp_host_is_single_sourced
    assert_equal ["${MCP_HOST:?}:${MCP_HOST_PORT:?}:${MCP_CONTAINER_PORT:?}"], COMPOSE.dig("services", "mcp", "ports")
    root = File.expand_path("../..", __dir__)
    %w[bin/daily-report deploy/install-daily-timer.sh].each do |f|
      src = File.read(File.join(root, f))
      refute_includes src, "127.0.0.1", f
      assert_match(/\$\{?MCP_HOST\b/, src, f)
    end
  end

  # the Hosts the web app answers (lib/busyyaks/host_guard.rb) come from .env, and the healthcheck asks with an allowed
  # one — the container port is not (card #253)
  def test_allowed_hosts_are_env_and_the_healthcheck_sends_one
    env = COMPOSE.dig("x-app", "environment")
    assert_equal ["${WEB_HOST_PORT:?}", "${PUBLIC_HOST?}"], env.values_at("WEB_HOST_PORT", "PUBLIC_HOST")
    check = COMPOSE.dig("services", "web", "healthcheck", "test").join(" ")
    assert_includes check, %("Host" => "127.0.0.1:\#{ENV.fetch('WEB_HOST_PORT')}")
  end

  # The launcher socket (whoever reaches it launches sessions and types into them) lives in its own host dir, .env
  # LAUNCHER_RUN_DIR, mounted only into the services that ask the launcher; never under ./data, which every service mounts.
  def test_launcher_socket_reaches_only_web_mcp_and_notifier
    services = COMPOSE.fetch("services")
    base = COMPOSE.dig("x-app", "volumes")
    mount = { "type" => "bind", "source" => "${LAUNCHER_RUN_DIR:?}", "target" => "/launcher",
              "bind" => { "create_host_path" => false }, }
    refute_includes base, mount
    %w[web mcp notifier].each do |name|
      s = services.fetch(name)
      assert_equal base + [mount], s.fetch("volumes"), name
      assert_equal "/launcher/launcher.sock", s.fetch("environment").fetch("LAUNCHER_SOCKET"), name
    end
    %w[scanner github].each do |name|
      s = services.fetch(name)
      assert_equal base, s.fetch("volumes"), "#{name} gets x-app's volumes only"
      refute s.fetch("environment").key?("LAUNCHER_SOCKET"), name
    end
    root = File.expand_path("../..", __dir__)
    src = File.read(File.join(root, "bin/launcher"))
    refute_includes src, "data/run", "the launcher keeps nothing under ./data"
    assert_includes src, 'SOCKET = File.join(RUN_DIR, "launcher.sock")'
    refute_includes File.read(File.join(root, "deploy/install-launcher.sh")), "data/run"
    assert_match(/^LAUNCHER_RUN_DIR=/, File.read(File.join(root, ".env.example")))
  end

  # the daily report's bearer is its own, scoped token: the MCP service takes both, the host scripts send only that one
  def test_daily_report_uses_the_report_token
    env = COMPOSE.dig("services", "mcp", "environment")
    assert_equal ["${MCP_TOKEN:?}", "${MCP_REPORT_TOKEN:?}"], env.values_at("MCP_TOKEN", "MCP_REPORT_TOKEN")
    root = File.expand_path("../..", __dir__)
    %w[bin/daily-report deploy/install-daily-timer.sh].each do |f|
      src = File.read(File.join(root, f))
      assert_includes src, "MCP_REPORT_TOKEN", f
      refute src.match?(/\bMCP_TOKEN\b/), "#{f} names MCP_TOKEN"
      refute_match(/-H "Authorization: Bearer \$/, src, "#{f}: a bearer in curl's argv is readable in /proc")
    end
  end

  # every git in the containers never fetches on demand (defence in depth: busyyaks runs no git CLI on scanned repos)
  def test_container_git_never_lazy_fetches
    %w[web mcp scanner notifier github].each do |name|
      env = COMPOSE.dig("services", name, "environment")
      assert_equal "1", env["GIT_NO_LAZY_FETCH"], name
      n = Integer(env.fetch("GIT_CONFIG_COUNT"))
      pairs = (0...n).to_h { |i| [env.fetch("GIT_CONFIG_KEY_#{i}"), env.fetch("GIT_CONFIG_VALUE_#{i}")] }
      assert_equal "${PROJECTS_MOUNT:?}/*", pairs.delete("safe.directory"), name
      assert_equal "never", pairs.delete("protocol.allow"), name
      assert pairs.all? { |k, v| k.match?(/\Aprotocol\.[a-z0-9]+\.allow\z/) && v == "never" }, name
    end
  end

  # bin/launcher refuses a LAUNCHER_STATE_DIR inside (or around) anything a container mounts; its `mounted:` list must
  # cover every host source compose binds — a new kind of source fails here until the launcher checks it too
  def test_the_launchers_mounted_list_covers_every_compose_bind
    # (a bare container path, e.g. the test service's "/app/public/app", is an anonymous volume: no host source)
    sources = COMPOSE.fetch("services").values.flat_map { |svc| Array(svc["volumes"]) }.filter_map do |v|
      v.is_a?(Hash) ? v.fetch("source") : v[/\A(\$\{[^}]+\}|[^:]+):/, 1]
    end.uniq
    kinds = sources.map do |src|
      case src
      when ".", %r{\A\./} then "the busyyaks checkout"
      when "${PROJECTS_ROOT:?}" then "PROJECTS_ROOT"
      when "${LAUNCHER_RUN_DIR:?}" then "the launcher socket dir"
      else flunk "compose binds #{src}, which bin/launcher's LAUNCHER_STATE_DIR check does not know"
      end
    end.uniq
    launcher = File.read(File.expand_path("../../bin/launcher", __dir__))
    mounted = launcher[/mounted: \{(.*?)\}/m, 1]
    refute_nil mounted
    { "PROJECTS_ROOT" => "PROJECTS_ROOT", "the busyyaks checkout" => "ROOT", "./data" => 'File.join(ROOT, "data")',
      "the launcher socket dir" => "RUN_DIR", }.each { |k, v| assert_includes mounted, %("#{k}" => #{v}) }
    kinds.each { |k| assert_includes mounted, %("#{k}" =>) }
  end
end
