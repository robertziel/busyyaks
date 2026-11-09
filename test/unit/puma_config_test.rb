# frozen_string_literal: true

require "test_helper"
require "yaml"

# puma's settings and the in-container ports are required env, never a default or a literal in code.
class PumaConfigTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  KEYS = %w[HANAMI_PORT HANAMI_ENV HANAMI_MAX_THREADS HANAMI_MIN_THREADS HANAMI_WEB_CONCURRENCY].freeze

  def read(path) = File.read(File.join(ROOT, path))

  def test_puma_rb_fetches_every_value_without_a_default
    src = read("config/puma.rb")
    fetches = src.scan(/ENV\.fetch\(([^)]*)\)(\s*\{)?/)
    assert_equal KEYS.sort, fetches.map { |args, _| args.delete('"') }.sort
    fetches.each { |args, block| assert(!args.include?(",") && block.nil?, "default in ENV.fetch(#{args})") }
  end

  def test_puma_rb_refuses_a_missing_value
    KEYS.each do |key|
      env = KEYS.to_h { |k| [k, k == "HANAMI_ENV" ? "production" : "1"] }.tap { |e| e.delete(key) }
      dsl = Class.new do
        %i[bind environment threads workers before_fork].each { |m| define_method(m) { |*| } }
      end.new
      with_env(env) do
        assert_raises(KeyError, key) { dsl.instance_eval(read("config/puma.rb")) }
      end
    end
  end

  def test_container_ports_come_from_env
    %w[docker-compose.yml Dockerfile bin/web bin/mcp].each do |f|
      refute_match(/\b(2300|2400)\b/, read(f), "#{f}: a literal in-container port")
    end
    env_example = read(".env.example").scan(/^([A-Z_]+)=/).flatten
    compose_vars = read("docker-compose.yml").scan(/\$\{([A-Z_]+):\?\}/).flatten.uniq
    %w[WEB_CONTAINER_PORT MCP_CONTAINER_PORT HANAMI_MAX_THREADS HANAMI_MIN_THREADS HANAMI_WEB_CONCURRENCY].each do |k|
      assert_includes compose_vars, k
      assert_includes env_example, k
    end
  end

  private

  def with_env(env)
    saved = KEYS.to_h { |k| [k, ENV[k]] }
    KEYS.each { |k| ENV.delete(k) }
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
