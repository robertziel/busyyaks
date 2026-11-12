# frozen_string_literal: true

require "open3"

module Busyyaks
  module CLI
    # The one place `yaks` spawns: argv arrays only (never a shell string), each program found on PATH first — one not
    # there → Refused naming it, nothing run. Tests inject a recording fake with the same three methods.
    class Runner
      def initialize(env)
        @path = env.fetch("PATH") { raise Refused, "PATH is not set" }
      end

      # → true when the program exited 0
      def system(*argv) = Kernel.system(resolve(argv), *argv.drop(1)) == true

      # → [stdout, true when it exited 0]; stderr goes to /dev/null (the caller reports the failure)
      def capture(*argv)
        out, status = Open3.capture2(resolve(argv), *argv.drop(1), err: File::NULL)
        [out, status.success?]
      end

      # replaces this process (a command whose output is the program's own: logs -f)
      def exec(*argv) = Kernel.exec(resolve(argv), *argv.drop(1))

      def which(name)
        @path.split(File::PATH_SEPARATOR).map { |d| File.join(d, name) }
             .find { |f| File.file?(f) && File.executable?(f) }
      end

      private

      def resolve(argv)
        which(argv.first) || raise(Refused, "#{argv.first} not on PATH")
      end
    end
  end
end
