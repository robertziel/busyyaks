# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/busyyaks/agent_collector"

# the launcher unit's cgroup holds the box's tmux server (the first `tmux new-session` starts it), so a
# stop / restart of the unit must stop only the launcher, never every tmux session on the box.
class DeployUnitsTest < Minitest::Test
  UNIT = File.expand_path("../../deploy/busyyaks-launcher.service", __dir__)

  def test_launcher_unit_stops_only_the_launcher
    service = File.read(UNIT)[/^\[Service\]\n(.*?)(?=^\[|\z)/m, 1]
    assert_equal ["process"], service.scan(/^KillMode=(\S+)/).flatten
  end

  # A launcher that re-read config/kanban.yml per launch against the engine it loaded at start failed
  # every spawn once the checkout gained a key the old engine did not know. Config and engine are read together, once.
  def test_launcher_reads_the_board_config_once_at_start
    src = File.read(File.expand_path("../../bin/launcher", __dir__))
    loads = src.scan(/HostConfig\.load\(/).size
    assert_equal 1, loads
    assert_match(/^BOARD_CONFIG = AgentsKanban::HostConfig\.load\(/, src)
    refute_match(/\bdef board_config\b/, src)
  end

  # The socket goes through PrivateSocket.bind (test/unit/private_socket_test.rb); .env through the one reader.
  def test_launcher_binds_its_socket_privately_and_reads_env_once
    src = File.read(File.expand_path("../../bin/launcher", __dir__))
    assert_includes src, "server = Busyyaks::PrivateSocket.bind(SOCKET)"
    # a stale socket from the last run is replaced (RUN_DIR persists across restarts and reboots), nothing else is
    assert_operator src.index("File.unlink(SOCKET) if File.socket?(SOCKET)"), :<, src.index("PrivateSocket.bind(SOCKET)")
    assert_includes src, "if File.symlink?(SOCKET) || (File.exist?(SOCKET) && !File.socket?(SOCKET))"
    refute_includes src, "UNIXServer.new"
    assert_includes src, "Busyyaks::EnvFile.read(File.join(ROOT, \".env\"))"
    refute_match(/readlines\(File\.join\(ROOT, "\.env"\)\)/, src)
  end

  # The collector is a config/busyyaks.yml choice (agents.collector), never .env placeholder paths the launcher starts on:
  # an old .env key stops the start, and every op that reads the collector is gated on it.
  def test_launcher_takes_the_collector_from_config
    src = File.read(File.expand_path("../../bin/launcher", __dir__))
    refute_match(/env_file\.fetch\("AGENTS_/, src)
    assert_includes src, 'AgentCollector.parse(YAML.safe_load_file(File.join(ROOT, "config/busyyaks.yml"))["agents"])'
    assert_match(/AgentCollector\.check!/, src)
    assert_includes src, 'Busyyaks::AgentCollector.refusal(COLLECTOR, req["op"])'
    # the methods that read the collector are reached only through those ops
    { "agents" => "agents", "agent_tasks" => "agent_tasks(req)", "reap_preview" => "reap_preview", "reap" => "reap(req)",
      "notify" => "notify(req)", }.each do |op, call|
      assert_includes src, %(when "#{op}" then #{call})
      assert_includes Busyyaks::AgentCollector::OPS, op
    end
  end
end
