# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

# bin/entrypoint (every service's Dockerfile ENTRYPOINT): as a non-root uid, a DATA_DIR holding anything that uid does not
# own or cannot read stops the start with a one-time fix; the fix as printed (its root `sh -c` part, run here as root
# instead of through `docker compose run --user root`) makes the next start succeed. Run as that uid with setpriv, so the
# suite (the compose `test` service) must run as root.
class EntrypointTest < Minitest::Test
  ENTRYPOINT = File.expand_path("../../bin/entrypoint", __dir__)
  UID = 4321
  FIX = "docker compose run --rm --no-deps --user root web sh -c '"

  def setup
    assert_equal 0, Process.uid, "the entrypoint test switches uid with setpriv: run it in the root test container"
    @dir = Dir.mktmpdir
    @data = File.join(@dir, "data")
    Dir.mkdir(@data)
    FileUtils.chown_R(UID, UID, @dir)
  end

  def teardown
    FileUtils.chmod_R("u+rwX", @dir)
    FileUtils.rm_rf(@dir)
  end

  def start(env = { "DATA_DIR" => @data })
    Open3.capture3(env, "setpriv", "--reuid=#{UID}", "--regid=#{UID}", "--clear-groups", "sh", ENTRYPOINT, "echo", "started")
  end

  # the refusal names the fix; applying exactly that fix lets the service start
  def assert_refused_then_fixed(reason)
    out, err, st = start
    refute st.success?
    assert_empty out
    assert_match(reason, err)
    cmd = err[/#{Regexp.escape(FIX)}(.*)'$/, 1]
    assert_equal "chown -R #{UID}:#{UID} #{@data} && chmod -R u+rwX #{@data}", cmd, err
    _o, e, ok = Open3.capture3("sh", "-c", cmd)
    assert ok.success?, e
    out, err, st = start
    assert st.success?, err
    assert_equal "started\n", out
  end

  def test_a_clean_data_dir_runs_the_command
    out, err, st = start
    assert st.success?, err
    assert_equal "started\n", out
  end

  def test_a_root_owned_file_is_refused_and_the_printed_fix_works
    FileUtils.mkdir_p(File.join(@data, "attachments", "7"))
    FileUtils.chown(UID, UID, File.join(@data, "attachments")) # only the inner dir is foreign
    data = Regexp.escape(@data)
    assert_refused_then_fixed(/#{data} holds files not owned by uid #{UID} \(#{data}\/attachments\/7\)/)
  end

  # a dir the uid owns but cannot read: a chown alone would not help; the printed fix does
  def test_an_own_unreadable_subdir_is_refused_and_the_printed_fix_works
    locked = File.join(@data, "locked")
    Dir.mkdir(locked)
    File.chown(UID, UID, locked)
    File.chmod(0o000, locked)
    data = Regexp.escape(@data)
    assert_refused_then_fixed(/#{data} has a directory uid #{UID} cannot read \(find: .*locked.*Permission denied\)/)
  end

  def test_an_unwritable_data_dir_is_refused_and_the_printed_fix_works
    File.chown(0, 0, @data)
    assert_refused_then_fixed(/#{Regexp.escape(@data)} is not writable by uid #{UID}/)
  end

  def test_data_dir_is_required
    _out, err, st = start({})
    refute st.success?
    assert_match(/DATA_DIR \(the \.\/data mount\) is required/, err)
  end
end
