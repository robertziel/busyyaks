# frozen_string_literal: true

require "etc"

module Busyyaks
  module Collector
    # The processes bin/collector reads, out of a proc root (/proc on the host; a fake tree in the tests). One pass per
    # snapshot, races tolerated: a process that exits mid-read is absent, never an error. Only these files are read:
    # stat (pid, parent, comm, start time), cmdline (a family's match), the cwd and exe links. Never environ.
    class Procfs
      Process_ = Struct.new(:pid, :ppid, :comm, :start_ticks, :uid, keyword_init: true)

      attr_reader :root

      def initialize(root, clk_tck: Etc.sysconf(Etc::SC_CLK_TCK))
        @root = root
        @clk_tck = clk_tck
      end

      # {pid => Process_} of every process visible now
      def processes
        Dir.children(@root).grep(/\A\d+\z/).each_with_object({}) do |name, acc|
          p = stat(name.to_i)
          acc[p.pid] = p if p
        end
      end

      # one process now, or nil (gone, or its stat unreadable). comm is parenthesised and may hold spaces or ")": cut at
      # the LAST ")". The owner of /proc/<pid> is its real uid.
      def stat(pid)
        dir = File.join(@root, pid.to_s)
        raw = File.binread(File.join(dir, "stat")).force_encoding(Encoding::UTF_8).scrub
        lp = raw.index("(")
        rp = raw.rindex(")")
        return nil if lp.nil? || rp.nil? || rp < lp

        rest = raw[(rp + 2)..].to_s.split
        return nil if rest.size < 20

        Process_.new(pid: pid, ppid: Integer(rest[1], 10), comm: raw[(lp + 1)...rp], start_ticks: Integer(rest[19], 10),
                     uid: File.stat(dir).uid)
      rescue SystemCallError, ArgumentError
        nil
      end

      # {ppid => [pid, …]}
      def children(procs) = procs.values.group_by(&:ppid).transform_values { |ps| ps.map(&:pid) }

      def argv(pid)
        File.binread(File.join(@root, pid.to_s, "cmdline")).split("\0").map { |a| a.force_encoding(Encoding::UTF_8).scrub }
      rescue SystemCallError
        []
      end

      def cwd(pid) = link(pid, "cwd")
      def exe(pid) = link(pid, "exe")

      # the boot time (epoch seconds), from <root>/stat — nil when unreadable
      def btime
        line = File.foreach(File.join(@root, "stat")).find { |l| l.start_with?("btime ") }
        line && Float(line.split[1])
      rescue SystemCallError, ArgumentError
        nil
      end

      # a process's start, epoch seconds to 0.1 (nil = the boot time or the tick rate is unknown)
      def started(process, boot = btime)
        return nil if boot.nil? || !@clk_tck.is_a?(Integer) || @clk_tck <= 0

        (boot + (process.start_ticks.to_f / @clk_tck)).round(1)
      end

      private

      def link(pid, name)
        # a path is bytes: one that is not UTF-8 is shown with U+FFFD, never a snapshot JSON cannot write
        File.readlink(File.join(@root, pid.to_s, name)).force_encoding(Encoding::UTF_8).scrub
      rescue SystemCallError
        nil
      end
    end
  end
end
