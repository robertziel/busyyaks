# frozen_string_literal: true

require "base64"
require "json"

module Busyyaks
  # The live terminal of an agent session: the operator sees an agent's tmux pane in the browser and, after
  # an explicit Take control, types into it. One stream, two carriers: bin/launcher's `attach` op serves it on the
  # launcher socket (a tmux client in a host PTY), the web's /api/terminal WebSocket (TerminalEndpoint) relays it to the
  # browser — and an ssh `--stdio` relay could carry the same lines over SSH.
  #
  # The stream: the first line is the launcher's answer — {ok:true, session, cols, rows, screen} (screen = the pane now,
  # `capture-pane -e -p`, base64) or {ok:false, error, status}. Then JSON lines both ways:
  #   launcher → client  {"o": b64}  output · {"size": {cols, rows}} the pane resized · {"control": bool} the control
  #                      state now · {"refused": why} a frame not acted on · {"exit": why} the stream ends
  #   client → launcher  {"i": b64}  keys (acted on only in control) · {"control": bool} take / release control
  #
  # What this deployment allows lives in config/busyyaks.yml `terminal` (required, no default):
  #   public_host: allow | deny  — whether a terminal opens through $PUBLIC_HOST (the tunnel); loopback always may
  #   max_open:    1..64         — terminals open at once in the web process; one more is refused (503)
  module Terminal
    class Invalid < StandardError; end

    SESSION = /\A[A-Za-z0-9._-]{1,100}\z/
    SOCKET = /\A[\w.-]{1,64}\z/
    MAX_INPUT = 64 * 1024     # decoded bytes in one {"i"} frame (a paste)
    MAX_LINE = 256 * 1024     # one JSON line / WebSocket message, either way
    NOT_IN_CONTROL = "input while not in control: nothing typed"
    KEYS = %w[public_host max_open].freeze
    PUBLIC_HOST = %w[allow deny].freeze

    Settings = Struct.new(:public_host, :max_open, keyword_init: true) do
      def public_allowed? = public_host == "allow"
    end

    module_function

    def parse!(value)
      unless value.is_a?(Hash) && value.keys.sort == KEYS.sort
        raise Invalid, "terminal must be a mapping with exactly #{KEYS.join(', ')} (config/busyyaks.example.yml)"
      end
      unless PUBLIC_HOST.include?(value["public_host"])
        raise Invalid, "terminal.public_host must be allow or deny (got #{value['public_host'].inspect}): whether an " \
                       "agent's terminal opens through PUBLIC_HOST"
      end
      max = value["max_open"]
      unless max.is_a?(Integer) && max.between?(1, 64)
        raise Invalid, "terminal.max_open must be an integer 1..64 (got #{max.inspect})"
      end

      Settings.new(public_host: value["public_host"], max_open: max)
    end

    def session!(name, socket)
      raise Invalid, "session must be a tmux session name (A-Z a-z 0-9 . _ -)" unless name.to_s.match?(SESSION)
      raise Invalid, "socket must be a tmux socket name" unless socket.to_s.match?(SOCKET)

      [name.to_s, socket.to_s]
    end

    # One client line → [:input, bytes] | [:control, true|false]; anything else → Invalid (with why).
    def client_frame(line)
      raise Invalid, "frame too long" if line.bytesize > MAX_LINE

      f = JSON.parse(line)
      raise Invalid, "a frame is a JSON object" unless f.is_a?(Hash) && f.size == 1

      if f.key?("i")
        bytes = Base64.strict_decode64(f["i"].to_s)
        raise Invalid, "input frame over #{MAX_INPUT} bytes" if bytes.bytesize > MAX_INPUT

        [:input, bytes]
      elsif f.key?("control")
        raise Invalid, "control must be true or false" unless [true, false].include?(f["control"])

        [:control, f["control"]]
      else
        raise Invalid, "unknown frame #{f.keys.first.inspect} (i, control)"
      end
    rescue JSON::ParserError, ArgumentError => e
      raise Invalid, "bad frame: #{e.message}"
    end

    def line(hash) = "#{JSON.generate(hash)}\n"
    def output(bytes) = line(o: Base64.strict_encode64(bytes))
    def refused(why) = line(refused: why)
  end
end
