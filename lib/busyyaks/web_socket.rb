# frozen_string_literal: true

require "base64"
require "digest"

module Busyyaks
  # The server side of RFC 6455, as much as the terminal needs: the handshake, text messages each way,
  # ping → pong, close. Over a hijacked Puma socket (TerminalEndpoint). What it does not take it refuses with a close
  # code, never guesses: a fragmented or binary message (1003); an unmasked client frame, RSV bits (no extension is
  # negotiated), a fragmented or over-125-byte control frame, a 64-bit length with its top bit set (1002); text that is
  # not UTF-8 (1007); a reserved opcode (1002); a message over `max` bytes (1009). No extensions, no subprotocols.
  class WebSocket
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    TEXT = 0x1
    BINARY = 0x2
    CLOSE = 0x8
    PING = 0x9
    PONG = 0xA
    OPCODES = [0x0, TEXT, BINARY, CLOSE, PING, PONG].freeze # the rest are reserved (RFC 6455 § 5.2): 1002

    class Closed < StandardError; end

    # The upgrade request's key when it is a WebSocket upgrade (RFC 6455 § 4.2.1), else nil.
    def self.key(env)
      return nil unless env["REQUEST_METHOD"] == "GET" && env["HTTP_UPGRADE"].to_s.casecmp?("websocket")
      return nil unless env["HTTP_CONNECTION"].to_s.split(",").any? { |t| t.strip.casecmp?("upgrade") }
      return nil unless env["HTTP_SEC_WEBSOCKET_VERSION"] == "13"

      key = env["HTTP_SEC_WEBSOCKET_KEY"].to_s
      (Base64.strict_decode64(key).bytesize == 16 && key) || nil
    rescue ArgumentError
      nil
    end

    def self.accept(key) = Base64.strict_encode64(Digest::SHA1.digest("#{key}#{GUID}"))

    def self.handshake(key)
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
        "Sec-WebSocket-Accept: #{accept(key)}\r\n\r\n"
    end

    def initialize(io, max:)
      @io = io
      @max = max
      @write = Mutex.new
    end

    def text(str) = frame(TEXT, str.to_s.b)

    # Close with a code and a reason (≤ 120 bytes), then the socket. Safe to call twice and on a dead socket.
    def close(code = 1000, reason = "")
      frame(CLOSE, [code].pack("n") + reason.to_s.b[0, 120])
    rescue Closed
      nil
    ensure
      @io.close unless @io.closed?
    end

    # The next text message (UTF-8), or nil once the peer closed. Pings are answered on the way.
    def read
      loop do
        fin, op, payload = read_frame
        return nil if op.nil?

        case op
        when TEXT
          return refuse(1003, "fragmented messages are not accepted") unless fin

          text = payload.force_encoding(Encoding::UTF_8)
          return refuse(1007, "a text message must be valid UTF-8") unless text.valid_encoding?

          return text
        when PING then frame(PONG, payload)
        when PONG then next
        when CLOSE
          close(1000)
          return nil
        else
          return refuse(1003, "only text messages are accepted")
        end
      end
    end

    private

    def refuse(code, why)
      close(code, why)
      nil
    end

    def read_frame
      head = @io.read(2)
      return nil if head.nil? || head.bytesize < 2

      b0, b1 = head.unpack("CC")
      fin = b0.anybits?(0x80)
      op = b0 & 0x0f
      return refuse(1002, "client frames must be masked") if b1.nobits?(0x80)
      return refuse(1002, "RSV bits set with no extension negotiated") if b0.anybits?(0x70)
      return refuse(1002, "reserved opcode #{op}") unless OPCODES.include?(op)

      len = b1 & 0x7f
      # a control frame (close, ping, pong) is never fragmented and carries at most 125 bytes (RFC 6455 § 5.5)
      return refuse(1002, "a control frame must be final and at most 125 bytes") if op >= CLOSE && (!fin || len > 125)

      len = read_len(len == 126 ? 2 : 8) if len >= 126
      return nil if len.nil?
      return refuse(1002, "a 64-bit length must have its top bit clear") if len >= 2**63
      return refuse(1009, "message over #{@max} bytes") if len > @max

      mask = @io.read(4)
      data = len.zero? ? +"" : @io.read(len)
      return nil if mask.nil? || mask.bytesize < 4 || data.nil? || data.bytesize < len

      [fin, op, unmask(data, mask)]
    rescue IOError, SystemCallError
      nil
    end

    def read_len(n)
      raw = @io.read(n)
      return nil if raw.nil? || raw.bytesize < n

      n == 2 ? raw.unpack1("n") : raw.unpack1("Q>")
    end

    # XOR with the 4-byte mask, a 32-bit word at a time (a 256 KB paste = 64K word steps), the tail byte-wise
    def unmask(data, mask)
      key = mask.unpack1("N")
      whole = data.bytesize / 4 * 4
      out = data.byteslice(0, whole).unpack("N*").map { |w| w ^ key }.pack("N*")
      m = mask.bytes
      data.byteslice(whole, data.bytesize - whole).bytes.each_with_index { |b, i| out << (b ^ m[i]).chr }
      out.b
    end

    def frame(op, payload)
      len = payload.bytesize
      head = [0x80 | op].pack("C")
      head << if len < 126 then [len].pack("C")
              elsif len < 65_536 then [126, len].pack("Cn")
              else [127, len].pack("CQ>")
              end
      @write.synchronize { @io.write(head, payload) }
    rescue IOError, SystemCallError => e
      raise Closed, e.message
    end
  end
end
