# frozen_string_literal: true

require "socket"

module Busyyaks
  # bin/launcher's unix socket, owner-only from the moment it exists: bound under umask 077 (a bind-then-chmod leaves a
  # window in which another local user could connect), mode 0600 said outright, and the process umask restored before
  # the caller starts any child (tmux, git). Pure Ruby: the host launcher requires this file alone.
  module PrivateSocket
    def self.bind(path)
      umask = File.umask(0o077)
      server = UNIXServer.new(path)
      File.chmod(0o600, path)
      server
    ensure
      File.umask(umask) if umask
    end
  end
end
