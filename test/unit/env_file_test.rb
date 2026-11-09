# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../lib/busyyaks/env_file"

# The one .env reader of the host programs (bin/launcher, bin/render-deploy, bin/env for the shell scripts): what compose,
# the shell and a plain split would each read differently is refused, naming the line — never read one way here and
# another way by compose.
class EnvFileTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  E = Busyyaks::EnvFile

  def parse(text) = E.parse(text, path: ".env")

  def test_plain_and_quoted_values
    env = parse(%(# c\n\nA="x y"\nB='z'\nC=1=2\nF=a#b\nG=""\nH=https://t.test/#s={session}\r\n))
    assert_equal({ "A" => "x y", "B" => "z", "C" => "1=2", "F" => "a#b", "G" => "", "H" => "https://t.test/#s={session}" }, env)
  end

  def test_what_a_reader_would_rewrite_is_refused_with_its_line
    {
      "A=1\nB=127.0.0.1:${WEB_HOST_PORT}\n" => [/\.env:2: B: a `\$`/],
      "A=$X\n" => [/\.env:1: A: a `\$`/],
      "A=dash.test # host\n" => [/A: an inline comment/],
      %(A="a" # c\n) => [/A: an unclosed quote, a quote inside the value, or text after the closing quote/],
      %(A="unterminated\n) => [/unclosed quote/],
      %(A="a"b"\n) => [/unclosed quote/],
      %(A="\\n"\n) => [/A: a backslash inside double quotes/],
      "A=x y\n" => [/A: an unquoted value with spaces/],
      "export A=1\n" => [/"export A" is not a variable name/],
      "A =1\n" => [/"A " is not a variable name/],
      "A=1\nA=2\n" => [/\.env:2: A is set twice/],
      "just text\n" => [/\.env:1: not KEY=value/],
    }.each do |text, (msg)|
      err = assert_raises(E::Invalid, text) { parse(text) }
      assert_match msg, err.message, text
    end
  end

  def test_the_examples_and_the_compose_file_agree
    env = E.read(File.join(ROOT, ".env.example"))
    compose = File.readlines(File.join(ROOT, "docker-compose.yml")).reject { |l| l.lstrip.start_with?("#") }.join
    compose.scan(/\$\{([A-Z0-9_]+):\?\}/).flatten.uniq.each do |k|
      assert env.key?(k), "#{k}: compose needs it, .env.example lacks it"
    end
  end

  def test_shell_exports_quote_every_value_and_refuse_a_missing_key
    assert_equal "export A='it'\\''s'\nexport B='x y'", E.shell_exports({ "A" => "it's", "B" => "x y" }, %w[A B])
    err = assert_raises(E::Invalid) { E.shell_exports({ "A" => "", "B" => "1" }, %w[A B C]) }
    assert_equal ".env: missing or empty A, C", err.message
  end

  # MCP_HOST is loopback wherever it is read (bin/env for the host scripts, mcp.ru at the MCP server's boot)
  def test_mcp_host_must_be_ipv4_loopback
    %w[127.0.0.1 127.0.0.2].each { |v| assert_equal v, E.shape!("MCP_HOST", v) }
    ["0.0.0.0", "10.0.0.1", "::1", "localhost", "127.0.0.1/8", "", "x"].each do |v|
      e = assert_raises(E::Invalid, v) { E.shape!("MCP_HOST", v) }
      assert_match(/\AMCP_HOST must be an IPv4 loopback address/, e.message)
    end
    assert_raises(E::Invalid) { E.shell_exports({ "MCP_HOST" => "0.0.0.0" }, %w[MCP_HOST]) }
    assert_equal "x", E.shape!("OTHER", "x")
    assert_includes File.read(File.join(ROOT, "mcp.ru")), 'Busyyaks::EnvFile.shape!("MCP_HOST", ENV.fetch("MCP_HOST"))'
  end

  # bin/env on a temp copy (never the real .env): eval-able exports, or exit 1 naming what is wrong
  def bin_env(env_text, *keys)
    Dir.mktmpdir do |dir|
      %w[bin/env lib/busyyaks/env_file.rb].each do |f|
        FileUtils.mkdir_p(File.join(dir, File.dirname(f)))
        FileUtils.cp(File.join(ROOT, f), File.join(dir, f))
      end
      File.write(File.join(dir, ".env"), env_text) if env_text
      Open3.capture3(RbConfig.ruby, File.join(dir, "bin/env"), *keys)
    end
  end

  def test_bin_env_prints_exports_a_shell_can_eval
    out, err, st = bin_env(%(A="x y"\nB=it's\n), "A", "B")
    assert st.success?, err
    shell, = Open3.capture2("bash", "-c", "#{out}\nprintf '%s|%s' \"$A\" \"$B\"")
    assert_equal "x y|it's", shell
  end

  def test_bin_env_refuses_a_malformed_or_incomplete_env
    [[%(A=1 # c\n), /\.env:1: A: an inline comment/], ["A=1\n", /missing or empty B/], [nil, /no \.env at/]].each do |text, msg|
      out, err, st = bin_env(text, "A", "B")
      assert_equal 1, st.exitstatus
      assert_empty out
      assert_match msg, err
    end
    _, err, st = bin_env("A=1\n")
    assert_equal 1, st.exitstatus
    assert_match(/usage/, err)
  end
end
