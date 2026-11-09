# frozen_string_literal: true

require "json"
require "rbconfig"

module Busyyaks
  # Every read of a repo under the projects mount goes through ONE short-lived child: `bin/git-read` (libgit2 via the
  # rugged gem; lib/busyyaks/git_reader.rb). No long-lived process (web, mcp, scanner, notifier) ever loads rugged or
  # runs the git CLI on a scanned repo: a repo's own config can make the git CLI run programs (filter drivers,
  # textconv, fsmonitor, pager, hooks), and libgit2 runs none of them, but a crafted repo can still hang it (a FIFO
  # where a file should be) or make it allocate without end (a huge blob, a deep config include fan-out). So the child
  #   - has hard limits from the deployment's env — every key required, checked at boot (config/app.rb), no default:
  #       GIT_READ_TIMEOUT_SECONDS  wall clock; then the child's process group gets SIGKILL
  #       GIT_READ_CPU_SECONDS      RLIMIT_CPU
  #       GIT_READ_MEMORY_BYTES     RLIMIT_AS (address space; libgit2's pack windows are sized to fit inside it)
  #       GIT_READ_MAX_BLOB_BYTES   a blob larger than this is never loaded: it counts as binary, and the result says so
  #   - runs with an EMPTY environment (no MCP_TOKEN, no session or GitHub secret: a repo's config can make libgit2
  #     read any file the child can, /proc/self/environ included), cwd "/", stdin a pipe, no inherited fds
  #   - answers ONE JSON object on stdout (at most MAX_OUTPUT bytes).
  # A timeout, a limit, a crash or an answer that is not the protocol → Failed with the reason. The git CLI is never
  # run instead: a repo libgit2 cannot read is an error on that repo, shown where its data would be.
  module GitRead
    class Failed < StandardError; end
    class Invalid < StandardError; end

    LIMIT_KEYS = %w[GIT_READ_TIMEOUT_SECONDS GIT_READ_CPU_SECONDS GIT_READ_MEMORY_BYTES GIT_READ_MAX_BLOB_BYTES].freeze
    MIN_MEMORY_BYTES = 128 * 1024 * 1024 # the child is a Ruby VM: below this it cannot even start
    MAX_OUTPUT = 32 * 1024 * 1024
    # RLIMIT_CPU: SIGXCPU at the limit, SIGKILL this many CPU seconds later if the child got past it
    CPU_GRACE = 2
    BIN = File.expand_path("../../bin/git-read", __dir__)
    LIB = File.expand_path("..", __dir__)
    # what the child may know of the world: where the executables are and the locale. Nothing else.
    CHILD_ENV = { "PATH" => "/usr/local/bin:/usr/bin:/bin", "LANG" => "C.UTF-8", "HOME" => "/nonexistent" }.freeze

    module_function

    # {timeout:, cpu:, memory:, max_blob:} from env — every key a positive integer, memory ≥ MIN_MEMORY_BYTES.
    def limits(env = ENV)
      v = LIMIT_KEYS.to_h do |k|
        raw = env.fetch(k) { raise Invalid, "#{k} is not set (.env.example documents it)" }
        n = Integer(raw, exception: false)
        raise Invalid, "#{k} must be a whole number > 0 (got #{raw.inspect})" unless n&.positive?

        [k, n]
      end
      if v["GIT_READ_MEMORY_BYTES"] < MIN_MEMORY_BYTES
        raise Invalid, "GIT_READ_MEMORY_BYTES must be at least #{MIN_MEMORY_BYTES} (got #{v['GIT_READ_MEMORY_BYTES']})"
      end

      { timeout: v["GIT_READ_TIMEOUT_SECONDS"], cpu: v["GIT_READ_CPU_SECONDS"], memory: v["GIT_READ_MEMORY_BYTES"],
        max_blob: v["GIT_READ_MAX_BLOB_BYTES"], }
    end

    # The projects mount every listed repo lives under (compose PROJECTS_MOUNT) — the containment root of a read.
    def mount = ENV.fetch("PROJECTS_MOUNT")

    # One read: op (scan | head | churn | files_at) of the repo at path, which must resolve inside root. → the
    # answer Hash (string keys); Failed with the reason otherwise. (bin: the child's script — the tests run stand-in
    # children through the same spawn, limits and parsing.)
    def call(op, path:, root:, limits: self.limits, bin: BIN, **args)
      req = JSON.generate(args.merge(op: op, path: path.to_s, root: root.to_s, max_blob: limits[:max_blob],
                                     memory: limits[:memory]))
      out, status = run(req, limits, bin)
      answer = parse(out, status, limits)
      raise Failed, "#{path}: #{answer['error']}" unless answer["ok"]

      answer
    end

    def run(req, limits, bin)
      cmd = [RbConfig.ruby, "--disable-gems", *load_path.flat_map { |d| ["-I", d] }, bin]
      rd_in, wr_in = IO.pipe
      rd_out, wr_out = IO.pipe
      pid = Process.spawn(CHILD_ENV, *cmd, unsetenv_others: true, chdir: "/", pgroup: true,
                                           in: rd_in, out: wr_out, err: File::NULL, close_others: true,
                                           rlimit_as: limits[:memory], rlimit_cpu: [limits[:cpu], limits[:cpu] + CPU_GRACE],
                                           rlimit_core: 0)
      [rd_in, wr_out].each(&:close)
      begin
        wr_in.write(req)
      rescue Errno::EPIPE
        nil # the child died before it read its request: its status says why
      end
      wr_in.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limits[:timeout]
      out = read_until(rd_out, deadline)
      status = out.is_a?(String) ? exit_status(pid, deadline) : nil
      out = :timeout if status.nil? && out.is_a?(String)
      [out, status || kill!(pid)]
    ensure
      [rd_in, wr_in, rd_out, wr_out].each { |io| io&.close unless io&.closed? }
    end

    # stdout until EOF, the deadline or MAX_OUTPUT. :timeout / :too_big instead of the bytes when a bound was hit.
    def read_until(io, deadline)
      buf = +""
      loop do
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return :timeout if left <= 0
        return :timeout unless io.wait_readable(left)

        chunk = io.read_nonblock(65_536, exception: false)
        return buf if chunk.nil? # EOF
        next if chunk == :wait_readable

        buf << chunk
        return :too_big if buf.bytesize > MAX_OUTPUT
      end
    end

    # stdout is closed: the child's exit status once it exits — within the deadline (no more time than the read had),
    # else nil.
    def exit_status(pid, deadline)
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.005
      end
    end

    # A child still running (timed out, flooding stdout, or alive after EOF) is killed with its whole process group
    # (anything it started goes with it) → its status.
    def kill!(pid)
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      Process.wait2(pid).last
    end

    def parse(out, status, limits)
      raise Failed, "git-read timed out after #{limits[:timeout]} s (killed)" if out == :timeout
      raise Failed, "git-read answered more than #{MAX_OUTPUT} bytes (killed)" if out == :too_big
      if status.signaled?
        sig = Signal.signame(status.termsig)
        why = { "XCPU" => "CPU limit #{limits[:cpu]} s",
                "KILL" => "killed at the CPU hard limit #{limits[:cpu] + CPU_GRACE} s", }.fetch(sig, "signal #{sig}")
        raise Failed, "git-read stopped: #{why}"
      end

      answer = begin
        JSON.parse(out)
      rescue JSON::ParserError
        nil
      end
      unless answer.is_a?(Hash) && [true, false].include?(answer["ok"])
        raise Failed, "git-read exited #{status.exitstatus} without an answer " \
                      "(memory limit #{limits[:memory]} B, or it could not start)"
      end

      answer
    end

    # The child's load path: busyyaks's lib/ and the rugged gem's require paths (lib + its compiled extension), read
    # from the bundle this process runs with — the child starts with --disable-gems and no bundler, so it loads
    # nothing else. No rugged in the bundle = Failed (the image builds it; never the git CLI instead).
    def load_path
      spec = Gem.loaded_specs["rugged"] || Gem::Specification.find_by_name("rugged")
      [LIB, *spec.full_require_paths].uniq
    rescue Gem::MissingSpecError
      raise Failed, "the rugged gem is not installed (Gemfile; built against the image's libgit2)"
    end
  end
end
