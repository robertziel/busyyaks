# frozen_string_literal: true

require "open3"

module Busyyaks
  module CLI
    # The one place `yaks` spawns: argv arrays only (never a shell string), each program found on PATH first (or given
    # as an absolute path to an executable: a desktop entry's browser) — one not there → Refused naming it, nothing run.
    # Tests inject a recording fake with the same methods.
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

      # → [stdout, stderr, exit status] (the caller reports the program's own reason). env: added to ours. timeout:
      # seconds — past it the program's whole process group is killed and Refused names it (a stalled network call
      # never holds the caller forever)
      def capture_all(*argv, env: {}, timeout: nil)
        return capture3(env, argv) unless timeout

        Open3.popen3(env, resolve(argv), *argv.drop(1), pgroup: true) do |stdin, stdout, stderr, wait|
          stdin.close
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }
          unless wait.join(timeout)
            kill_group(wait.pid)
            wait.join
            raise Refused, "#{argv.first(4).join(' ')} did not finish within #{timeout} s: killed"
          end
          [out.value, err.value, wait.value.exitstatus || 1]
        end
      end

      # the program's stdin / stdout to the block (its stderr stays ours: ssh's own messages reach the operator);
      # → the block's value, the program ended when the block returns
      def stream(*argv)
        Open3.popen2(resolve(argv), *argv.drop(1)) do |w, r, wait|
          yield w, r
        ensure
          w.close unless w.closed?
          Process.kill("TERM", wait.pid) if wait.alive?
          wait.value
        end
      rescue Errno::ESRCH
        nil
      end

      # started in a process group of its own, its stdin on /dev/null, its stdout / stderr to `out` / `err` (an IO, or
      # the null device) → its pid; the caller waits for it (Process.wait2) or detaches it
      def spawn(*argv, out: File::NULL, err: File::NULL)
        Process.spawn(resolve(argv), *argv.drop(1), in: File::NULL, out: out, err: err, pgroup: true)
      end

      # replaces this process (a command whose output is the program's own: logs -f)
      def exec(*argv) = Kernel.exec(resolve(argv), *argv.drop(1))

      def which(name)
        @path.split(File::PATH_SEPARATOR).map { |d| File.join(d, name) }
             .find { |f| File.file?(f) && File.executable?(f) }
      end

      private

      def capture3(env, argv)
        out, err, status = Open3.capture3(env, resolve(argv), *argv.drop(1))
        [out, err, status.exitstatus || 1]
      end

      def kill_group(pid)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def resolve(argv)
        name = argv.first
        return name if name.start_with?("/") && File.file?(name) && File.executable?(name)

        which(name) || raise(Refused, "#{name} not on PATH")
      end
    end
  end
end
