# frozen_string_literal: true

require "test_helper"
require "prism"

# A test that measures a window against the real clock passes on a 32-CPU host and fails on the public
# runner's 4 (an agents-snapshot window, PR #41). So:
# - the code reads the time only through Busyyaks::Clock, which a test stubs to stand still or to move. The code may
#   block with a timeout (a deadline is its behaviour, computed through the Clock);
# - a test never reads the real clock, and never waits on real time itself: no sleep, no Clock.pause, and no blocking
#   call given a timeout — Queue/SizedQueue pop/shift/deq/push/enq/<< with `timeout:`, Thread#join(limit),
#   IO#wait_readable/wait_writable/wait_priority(n), IO.select / Kernel#select with a timeout, Timeout.timeout,
#   ConditionVariable#wait(mutex, n) — a literal 0 is a non-blocking check, no wait. Every wait goes through
#   test/support/wait.rb (Wait.for / until? / pop / join / readable / read), the one caller of Clock.pause: it polls a
#   non-blocking check up to a COUNT, an upper bound that is a hang guard only. An absence ("no window") is asserted
#   after the event that decides it, never by waiting a while to see nothing; a duration only from below
#   (Elapsed.at_least).
# The vendored engine (vendor/agents_kanban, frontend/src/vendor) is another repo's code with its own checks.
class NoRealClockTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CODE = %w[lib/**/*.rb app/**/*.rb cli/**/*.rb config/**/*.rb scripts/**/*.rb auth/**/*.rb config.ru mcp.ru].freeze
  CODE_EXCEPT = %w[auth/*/test/**].freeze # the auth providers' tests are TESTS
  TESTS = %w[test/**/*.rb auth/*/test/**/*.rb].freeze
  CLOCK = "lib/busyyaks/clock.rb" # where Busyyaks::Clock lives: its own method bodies are the one reader
  WAIT = "test/support/wait.rb" # the suite's waits: the one caller of Busyyaks::Clock.pause

  # [receiver constant, method] pairs that read the real clock
  READS = [%w[Time now], %w[Date today], %w[DateTime now], %w[Process clock_gettime]].freeze
  CLOCKS = %w[Time Date DateTime Process].freeze # the constants whose methods read it
  READ_NAMES = %w[now today clock_gettime].freeze
  WAIT_NAMES = %w[sleep pause timeout].freeze # a test's waits called by name (Kernel.send(:sleep, 1), …)
  # a method named by a symbol or string is called through these (Time.send(:now), Time.method(:now).call, …)
  BY_NAME = %i[send public_send __send__ method public_method instance_method singleton_method].freeze
  CONST_BY_NAME = %i[const_get].freeze

  def rel(f) = f.delete_prefix("#{ROOT}/")

  def ruby_files(globs, except: [])
    files = globs.flat_map { |g| Dir.glob(File.join(ROOT, g)) }.select { |f| File.file?(f) }.uniq
    files.reject { |f| except.any? { File.fnmatch?(_1, rel(f), File::FNM_PATHNAME) } }
  end

  # bin/: every Ruby program (by shebang)
  def bin_files
    Dir.glob(File.join(ROOT, "bin/*")).select { |f|
 File.file?(f) && File.binread(f, 80).to_s.lines.first.to_s.match?(/\A#!.*\bruby\b/n) }
  end

  def const_name(node)
    node.slice.delete_prefix("::") if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
  end

  def literal_name(node)
    node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
  end

  # does this node read the real clock (or, sleeps: true, sleep)? Literal calls, calls by name, the constant fetched by
  # name, and the constant itself handed to a variable (an alias the literal check would not see)
  CLOCK_READS = %i[now epoch today monotonic].freeze

  def clock_read?(node) = node.is_a?(Prism::CallNode) && const_name(node.receiver).to_s.end_with?("Clock") &&
                          CLOCK_READS.include?(node.name)

  def subtree(node) = [node, *node.compact_child_nodes.flat_map { subtree(_1) }]

  # a read is the Clock itself only inside Busyyaks::Clock's method bodies IN lib/busyyaks/clock.rb, the one
  # implementation of the seam: both conditions. A reopening of Busyyaks::Clock anywhere else is flagged on every read
  # and every sleep
  def clock_body?(stack, file) = rel(file) == CLOCK && stack.include?(:clock_module) && stack.include?(:def)

  def reopened_sleep?(node, stack, file)
    stack.include?(:clock_module) && rel(file) != CLOCK && node.is_a?(Prism::CallNode) && node.name == :sleep
  end

  # the stack of what encloses a node: :busyyaks inside `module Busyyaks`, :clock_module inside its `Clock`
  # (`module Busyyaks; module Clock` or `module Busyyaks::Clock`), :def inside a method
  def enclose(node, stack)
    return stack + [:def] if node.is_a?(Prism::DefNode)
    return stack unless node.is_a?(Prism::ModuleNode)

    path = node.constant_path.slice.delete_prefix("::").split("::")
    path = %w[Busyyaks] + path if stack.include?(:busyyaks)
    return stack + %i[busyyaks clock_module] if path == %w[Busyyaks Clock]

    path.first == "Busyyaks" && path.size == 1 ? stack + [:busyyaks] : stack - %i[busyyaks clock_module]
  end

  # a test (*_test.rb: the files that assert) also may not measure real time (3.02 s against a
  # 3 s bound): no Clock.monotonic, no arithmetic or comparison on Clock.now (Clock.now.to_f - started, a deadline
  # Clock.now + n > x), and no alias of the Clock (C = Busyyaks::Clock; C.now) the checks would not see through.
  # Elapsed.at_least (test/support/wait.rb, lower bounds only) measures. A date or epoch as DATA (Clock.today - 7,
  # Clock.epoch - 10) is no measurement.
  TIME_OPS = %i[- + < > <= >= <=>].freeze

  def stopwatch?(node)
    if node.class.name.end_with?("WriteNode") && node.respond_to?(:value)
      return const_name(node.value).to_s.end_with?("Clock") # an alias of the Clock
    end
    return false unless node.is_a?(Prism::CallNode)
    return true if clock_read?(node) && node.name == :monotonic

    TIME_OPS.include?(node.name) &&
      [node.receiver, *node.arguments&.arguments].compact.flat_map { subtree(_1) }.any? { clock_read?(_1) && _1.name == :now }
  end

  # a test's blocking call given a timeout (see the header): a real-time wait outside test/support/wait.rb
  IO_WAITS = %i[wait_readable wait_writable wait_priority].freeze
  QUEUE_WAITS = %i[pop shift deq push enq <<].freeze

  def zero?(node) = (node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode)) && node.value.zero?

  def keyword(node, name)
    node.arguments&.arguments&.grep(Prism::KeywordHashNode)&.flat_map(&:elements)&.find do
      _1.is_a?(Prism::AssocNode) && literal_name(_1.key) == name
    end&.value
  end

  def blocks?(node)
    return false unless node.is_a?(Prism::CallNode)

    args = node.arguments&.arguments || []
    case node.name
    when *IO_WAITS then args.any? && !zero?(args.first)
    # Thread#join(limit); a String#join-like call (Array#join(sep), File.join) takes a string or a constant's receiver
    when :join then args.size == 1 && !const_name(node.receiver) && !args.first.is_a?(Prism::StringNode) &&
                    !args.first.is_a?(Prism::InterpolatedStringNode) && !zero?(args.first)
    when :timeout then const_name(node.receiver) == "Timeout"
    when :select then args.size == 4 && !zero?(args[3]) && !args[3].is_a?(Prism::NilNode) &&
                      [nil, "IO", "Kernel"].include?(const_name(node.receiver))
    when :wait then args.size == 2 # ConditionVariable#wait(mutex, timeout)
    when *QUEUE_WAITS then (t = keyword(node, "timeout")) && !zero?(t)
    else false
    end
  end

  def pause?(node, as) = as != WAIT && node.is_a?(Prism::CallNode) && node.name == :pause &&
                         const_name(node.receiver).to_s.end_with?("Clock")

  def only_keywords?(node) = node.arguments && node.arguments.arguments.all?(Prism::KeywordHashNode)

  def offense?(node, sleeps:, stopwatch: false, as: nil)
    return true if stopwatch && stopwatch?(node)
    return true if sleeps && (blocks?(node) || pause?(node, as))

    case node
    when Prism::CallNode
      recv = const_name(node.receiver)
      first = literal_name(node.arguments&.arguments&.first)
      # Time.new with no arguments or only keywords (Time.new(in: "UTC")) is the current time too
      return true if READS.include?([recv, node.name.to_s]) || (recv == "Time" && node.name == :new &&
                                                                 (node.arguments.nil? || only_keywords?(node)))
      return true if sleeps && node.name == :sleep
      return true if BY_NAME.include?(node.name) && (READ_NAMES.include?(first) || (sleeps && WAIT_NAMES.include?(first)))

      CONST_BY_NAME.include?(node.name) && CLOCKS.include?(first)
    else
      node.class.name.end_with?("WriteNode") && node.respond_to?(:value) && CLOCKS.include?(const_name(node.value))
    end
  end

  # every offense in the file; "path:line: source"
  # the test side (sleeps: true: tests and their support) may use real time only through Busyyaks::Clock.pause (a wait,
  # in test/support/wait.rb only) and Busyyaks::Clock.stopwatch (a measurement) — by those two names; a bare sleep, a
  # timeout wait or Clock.monotonic is flagged in every file, the support files' included
  # `as`: the repo path the file stands for (a copy in a tmp dir checked as test/support/wait.rb)
  def hits(file, sleeps:, as: rel(file))
    found = []
    visit = lambda do |node, stack|
      inner = enclose(node, stack)
      if !clock_body?(stack, file) &&
         (offense?(node, sleeps: sleeps, stopwatch: sleeps, as: as) || reopened_sleep?(node, stack, file))
        found << "#{rel(file)}:#{node.location.start_line}: #{node.slice.lines.first.strip}"
      else
        node.compact_child_nodes.each { visit.(_1, inner) } # an offense is reported once, not again for its parts
      end
    end
    result = Prism.parse_file(file)
    flunk "#{rel(file)}: #{result.errors.map(&:message).join('; ')}" unless result.success?
    visit.(result.value, [])
    found
  end

  def test_the_code_reads_the_time_only_through_busyyaks_clock
    files = ruby_files(CODE, except: CODE_EXCEPT) + bin_files
    assert_includes files.map { rel(_1) }, CLOCK, "the Clock itself is scanned too"
    assert_operator files.size, :>, 100, "the globs found the code"
    assert_empty files.flat_map { hits(_1, sleeps: false) }
  end

  def test_no_test_reads_the_real_clock_or_sleeps
    files = ruby_files(TESTS)
    assert_includes files.map { rel(_1) }, "test/support/wait.rb", "the waits are scanned too"
    assert_operator files.size, :>, 50, "the globs found the tests"
    assert_empty files.flat_map { hits(_1, sleeps: true) }
  end

  # the check itself: each forbidden form is found (by name, on any receiver, through an alias), and a
  # string naming one is not
  FORMS = {
    "Time.now" => :read, "::Time.now.to_i" => :read, "Time.new" => :read, "Date.today" => :read, "DateTime.now" => :read,
    "Process.clock_gettime(Process::CLOCK_MONOTONIC)" => :read,
    "Time.send(:now)" => :read, "Time.public_send(\"now\")" => :read, "Time.__send__(:now)" => :read,
    "Time.method(:now).call" => :read, "Date.public_method(:today).call" => :read,
    "Process.send(:clock_gettime, Process::CLOCK_MONOTONIC)" => :read,
    "Object.const_get(:Time).now" => :read, "Kernel.const_get(\"Process\")" => :read,
    "t = Time" => :read, "@d = ::Date" => :read, "CLOCK = Process" => :read, "$t ||= Time" => :read,
    "sleep 1" => :sleep, "Kernel.sleep(1)" => :sleep, "self.sleep 1" => :sleep, "Kernel.send(:sleep, 1)" => :sleep,
    "method(:sleep).call(1)" => :sleep, "obj.sleep" => :sleep,
    "\"sleep 300; Time.now\"" => nil, "Time.new(2026, 1, 1)" => nil, "Time.at(0)" => nil, "x.send(:other)" => nil,
    "Busyyaks::Clock.now" => nil, "Object.const_get(:String)" => nil,
    "Busyyaks::Clock.monotonic" => :sleep, "Busyyaks::Clock.now.to_f - started" => :sleep,
    "Busyyaks::Clock.epoch - 10" => nil, "Busyyaks::Clock.today - 7" => nil, "x = Busyyaks::Clock.epoch" => nil,
    "C = Busyyaks::Clock" => :sleep, "c = ::Busyyaks::Clock" => :sleep, "@clock = Clock" => :sleep,
    "Busyyaks::Clock.now + 5 > deadline" => :sleep, "deadline < Busyyaks::Clock.now" => :sleep,
    "Busyyaks::Clock.now <=> t" => :sleep, "Busyyaks::Clock.now.to_f" => nil,
    # Time.new reads the clock with no arguments or only keywords
    "Time.new(in: \"UTC\")" => :read, "::Time.new(in: \"+01:00\")" => :read, "Time.new(2026, 1, 1, in: \"UTC\")" => nil,
    # waits on real time outside test/support/wait.rb
    "Busyyaks::Clock.pause(0.1)" => :sleep, "Busyyaks::Clock.send(:pause, 1)" => :sleep,
    "q.pop(timeout: 5)" => :sleep, "q.pop(timeout: 0.2)" => :sleep, "q.shift(timeout: n)" => :sleep,
    "q.push(x, timeout: 1)" => :sleep, "q.pop(timeout: 0)" => nil, "q.pop(true)" => nil, "q.pop" => nil,
    "t.join(5)" => :sleep, "t.join(0.1)" => :sleep, "@thread&.join(limit)" => :sleep, "t.join" => nil, "t.join(0)" => nil,
    "parts.join(\", \")" => nil, "File.join(dir)" => nil, "File.join(dir, \"x\")" => nil,
    "io.wait_readable(5)" => :sleep, "io.wait_writable(n)" => :sleep, "io.wait_priority(1)" => :sleep,
    "io.wait_readable(0)" => nil, "io.wait_readable" => nil,
    "IO.select([io], nil, nil, 5)" => :sleep, "select([io], nil, nil, 1)" => :sleep, "Kernel.select([io], [], [], t)" => :sleep,
    "IO.select([io], nil, nil, 0)" => nil, "IO.select([io], nil, nil, nil)" => nil, "IO.select([io])" => nil,
    "Timeout.timeout(5) { x }" => :sleep, "::Timeout.timeout(1)" => :sleep, "Timeout.send(:timeout, 1)" => :sleep,
    "cv.wait(mutex, 1)" => :sleep, "Process.wait(pid)" => nil, "cv.wait(mutex)" => nil,
  }.freeze

  # review: no file is exempt. Busyyaks::Clock's own method bodies read the clock (allowed by where they are), the
  # waits use Clock.pause / Clock.stopwatch (allowed by name); the same reads anywhere else are flagged — in wait.rb too
  def test_only_the_clocks_own_bodies_read_and_only_pause_and_stopwatch_wait
    Dir.mktmpdir do |dir|
      at = ->(src, name = "x_test.rb") { File.join(dir, name).tap { File.write(_1, src) } }
      # Busyyaks::Clock reopened outside lib/busyyaks/clock.rb: every read and sleep flagged (delta check 3's probes)
      { "module Busyyaks\n  module Clock\n    def self.sneaky = Time.now\n  end\nend\n" => 1,
        "module Busyyaks\n  module Clock\n    def self.sneaky = sleep(5)\n  end\nend\n" => 1,
        "module Busyyaks::Clock\n  def self.m = Process.clock_gettime(Process::CLOCK_MONOTONIC)\nend\n" => 1,
        "module Clock\n  def now = Time.now\nend\n" => 1,
        "module Busyyaks\n  module Clock\n    T = Time.now\n  end\nend\n" => 1,
        "module Busyyaks\n  module Other\n    def now = Time.now\n  end\nend\n" => 1,
        "_, s = Busyyaks::Clock.stopwatch { 1 }\n" => 0,
        "Busyyaks::Clock.pause(0.1)\n" => 1, }.each do |src, n|
        assert_equal n, hits(at.(src), sleeps: true).size, src
      end
      %w[x.rb lib_x.rb].each do |code|
        assert_equal 1, hits(at.("module Busyyaks\n  module Clock\n    def self.sneaky = sleep(5)\n  end\nend\n", code),
                             sleeps: false).size, "#{code}: a reopening's sleep in code too"
        assert_equal 1, hits(at.("module Busyyaks\n  module Clock\n    def self.sneaky = Time.now\n  end\nend\n", code),
                             sleeps: false).size, "#{code}: a reopening's read in code too"
      end
      assert_empty hits(File.join(ROOT, CLOCK), sleeps: false), "the seam itself, in its own file"
      wait = File.read(File.join(ROOT, "test/support/wait.rb"))
      assert_empty hits(at.(wait, "wait.rb"), sleeps: true, as: WAIT), "wait.rb as it is"
      assert_equal 1, hits(at.(wait, "wait.rb"), sleeps: true).size, "its Clock.pause anywhere but wait.rb"
      bare = wait.sub("Busyyaks::Clock.pause(every)", "sleep every")
      refute_equal wait, bare
      assert_equal 1, hits(at.(bare, "wait.rb"), sleeps: true, as: WAIT).size, "a bare sleep in wait.rb"
      blocking = wait.sub("io.wait_readable(0) && io }", "io.wait_readable(every) && io }")
      refute_equal wait, blocking
      assert_equal 1, hits(at.(blocking, "wait.rb"), sleeps: true, as: WAIT).size, "a timeout wait in wait.rb"
      mono = wait.sub("value, took = Busyyaks::Clock.stopwatch { yield }",
"t = Busyyaks::Clock.monotonic\nvalue = yield\ntook = 0")
      refute_equal wait, mono
      assert_equal 1, hits(at.(mono, "wait.rb"), sleeps: true, as: WAIT).size, "Clock.monotonic in wait.rb"
    end
  end

  def test_the_check_finds_every_form
    Dir.mktmpdir do |dir|
      FORMS.each do |src, kind|
        f = File.join(dir, "x_test.rb")
        File.write(f, "#{src}\n")
        assert_equal kind ? 1 : 0, hits(f, sleeps: true).size, "#{src} (tests)"
        assert_equal kind == :read ? 1 : 0, hits(f, sleeps: false).size, "#{src} (code: a sleep is allowed there)"
      end
    end
  end
end
