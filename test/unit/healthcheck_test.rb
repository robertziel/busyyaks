# frozen_string_literal: true

require "minitest/autorun"
require "open3"

# bin/healthcheck SECONDS (docker-compose.yml x-app) run for real against this machine's PID 1: it is healthy once
# PID 1 has run SECONDS, unhealthy before. The age it reads from /proc/1/stat sits between 0 and the machine's uptime.
class HealthcheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/healthcheck", __dir__)

  def check(seconds)
    _, _, status = Open3.capture3(BIN, seconds.to_s)
    status.exitstatus
  end

  def test_healthy_once_pid_1_is_old_enough
    assert_equal 0, check(0)
  end

  def test_unhealthy_before_that
    uptime = File.read("/proc/uptime").split.first.to_f
    assert_equal 1, check(uptime.ceil + 60), "PID 1 cannot be older than the machine"
  end

  def test_a_non_number_is_refused
    refute_equal 0, check("soon")
  end
end
