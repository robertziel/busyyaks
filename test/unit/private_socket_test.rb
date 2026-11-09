# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../../lib/busyyaks/private_socket"

# bin/launcher's socket: 0600 from the bind, and the process umask is the caller's again afterwards (its children
# — tmux sessions, git — must not inherit 077)
class PrivateSocketTest < Minitest::Test
  def test_bound_owner_only_and_the_umask_restored
    Dir.mktmpdir do |d|
      path = File.join(d, "s.sock")
      before = File.umask(0o022)
      begin
        server = Busyyaks::PrivateSocket.bind(path)
        assert_equal 0o022, File.umask, "umask restored"
        assert File.socket?(path)
        assert_equal 0o600, File.stat(path).mode & 0o777
        server.close
      ensure
        File.umask(before)
      end
    end
  end

  # the socket is created under umask 077 itself (not only chmodded afterwards): the umask seen by the bind call
  def test_the_bind_runs_under_umask_077
    seen = nil
    stub = UNIXServer.method(:new)
    UNIXServer.define_singleton_method(:new) do |path|
      seen = File.umask
      stub.call(path)
    end
    Dir.mktmpdir do |d|
      before = File.umask(0o022)
      begin
        Busyyaks::PrivateSocket.bind(File.join(d, "s.sock")).close
      ensure
        File.umask(before)
      end
    end
    assert_equal 0o077, seen
  ensure
    UNIXServer.singleton_class.send(:remove_method, :new)
  end

  def test_the_umask_is_restored_when_the_bind_fails
    before = File.umask(0o022)
    begin
      assert_raises(SystemCallError) { Busyyaks::PrivateSocket.bind("/nonexistent-dir/s.sock") }
      assert_equal 0o022, File.umask
    ensure
      File.umask(before)
    end
  end
end
