# frozen_string_literal: true

require "etc"

module Busyyaks
  module CLI
    # What `yaks` runs on: Linux only (bin/launcher reads /proc and runs under systemd --user; the containers reach
    # its unix socket through a bind mount, which Docker Desktop's VM does not carry), Ruby MIN_RUBY or newer.
    module Host
      module_function

      def os = Etc.uname.fetch(:sysname)

      def check!(ctx)
        unless ctx.os == "Linux"
          raise Refused, "busyyaks runs on Linux only (bin/launcher reads /proc and needs systemd --user); " \
                         "this is #{ctx.os}"
        end
        return unless Gem::Version.new(ctx.ruby) < Gem::Version.new(MIN_RUBY)

        raise Refused, "Ruby #{ctx.ruby} is older than #{MIN_RUBY}, the oldest yaks runs on"
      end
    end
  end
end
