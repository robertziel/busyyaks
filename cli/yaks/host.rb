# frozen_string_literal: true

require "etc"

module Busyyaks
  module CLI
    # What `yaks` runs on: Ruby MIN_RUBY or newer, everywhere. The stack's commands (server, panel, env, doctor) run on
    # Linux only (bin/launcher reads /proc and runs under systemd --user; the containers reach its unix socket through a
    # bind mount, which Docker Desktop's VM does not carry): stack!. `yaks desktop` and `yaks help` run on any Unix with
    # a desktop (Desktop.family!: the machine the operator works at, e.g. a Mac reaching the dashboard over PUBLIC_HOST).
    module Host
      module_function

      def os = Etc.uname.fetch(:sysname)

      def check!(ctx)
        return unless Gem::Version.new(ctx.ruby) < Gem::Version.new(MIN_RUBY)

        raise Refused, "Ruby #{ctx.ruby} is older than #{MIN_RUBY}, the oldest yaks runs on"
      end

      def stack!(ctx)
        return if ctx.os == "Linux"

        raise Refused, "busyyaks runs on Linux only (bin/launcher reads /proc and needs systemd --user); " \
                       "this is #{ctx.os}"
      end
    end
  end
end
