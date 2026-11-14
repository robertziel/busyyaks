# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module Busyyaks
  # Dictation: the card dialog's mic sends 16 kHz mono 16-bit WAV windows to POST /api/dictation, which
  # forwards each to the deployment's speech server — any OpenAI-compatible POST /v1/audio/transcriptions (a vLLM
  # fleet's load balancer serving whisper, vexa's transcription service, a faster-whisper server) — and answers
  # {text, words}. The server's URL and token stay in the web container; the browser never sees them.
  #
  # What it is lives in config/busyyaks.yml `dictation` (required): `none` = no mic anywhere, or
  # {model, timeout_seconds, max_seconds}. Where it is wired is env, only in the web service: DICTATION_URL (the base
  # or the full endpoint; required when on) + DICTATION_TOKEN (the bearer; empty = the server takes none, e.g. one
  # reached only inside docker). Both env keys must be declared — both empty with `none`: a mismatch stops the web
  # boot (config/puma.rb), never a guess.
  module Dictation
    class Invalid < StandardError; end
    class Refused < StandardError; end      # the recording itself: not a WAV we send, too long → 400 / 413
    class Unavailable < StandardError; end  # the speech server: unreachable, timed out, an error answer → 502

    PATH = "/v1/audio/transcriptions"
    KEYS = %w[model timeout_seconds max_seconds].freeze
    SAMPLE_RATE = 16_000
    HEADER = 44
    PROMPT_CHARS = 800
    # the mic's longest window (the engine's lib/dictation.ts MAX_WINDOW_SEC): a smaller max_seconds would refuse it
    MIN_WINDOW_SECONDS = 30

    Settings = Struct.new(:model, :timeout_seconds, :max_seconds, keyword_init: true) do
      def max_bytes = HEADER + (max_seconds * SAMPLE_RATE * 2)
    end

    module_function

    # config/busyyaks.yml `dictation` → Settings, or nil for `none`
    def parse!(value)
      return nil if value == "none"

      unless value.is_a?(Hash) && value.keys.sort == KEYS.sort
        raise Invalid, "dictation must be `none` or a mapping with exactly #{KEYS.join(', ')} (config/busyyaks.example.yml)"
      end
      model = value["model"]
      unless model.is_a?(String) && !model.strip.empty?
        raise Invalid, "dictation.model must be a non-empty string (the speech server's model id)"
      end

      Settings.new(model: model, timeout_seconds: int!(value, "timeout_seconds", 1..300),
                   max_seconds: int!(value, "max_seconds", MIN_WINDOW_SECONDS..600))
    end

    def int!(value, key, range)
      v = value[key]
      raise Invalid, "dictation.#{key} must be an integer in #{range}" unless v.is_a?(Integer) && range.cover?(v)

      v
    end

    # The web service's boot check: the env matches the config (both keys declared; set exactly when dictation is on).
    def boot!(settings, env)
      missing = %w[DICTATION_URL DICTATION_TOKEN].reject { |k| env.key?(k) }
      raise Invalid, "#{missing.join(', ')} not in the web service's env (.env.example § dictation)" if missing.any?

      if settings.nil?
        set = %w[DICTATION_URL DICTATION_TOKEN].reject { |k| env[k].to_s.empty? }
        if set.any?
          raise Invalid, "#{set.join(', ')} set but config/busyyaks.yml dictation is none: empty them or configure dictation"
        end

        return nil
      end
      client(settings, env)
    end

    # → Client for this deployment; nil = dictation is off
    def client(settings, env)
      return nil if settings.nil?

      Client.new(settings, url: endpoint!(env.fetch("DICTATION_URL")), token: token!(env.fetch("DICTATION_TOKEN")))
    end

    # the base (https://host) or the full endpoint (https://host/v1/audio/transcriptions) → the endpoint
    def endpoint!(raw)
      uri = URI.parse(raw.to_s.strip.chomp("/"))
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise Invalid, "DICTATION_URL must be an http(s) URL without credentials, query or fragment"
      end

      uri.path = uri.path.end_with?(PATH) ? uri.path : "#{uri.path}#{PATH}"
      uri
    rescue URI::InvalidURIError
      raise Invalid, "DICTATION_URL is not a URL"
    end

    # nil = no Authorization header (the speech server takes none)
    def token!(raw)
      t = raw.to_s
      return nil if t.empty?
      raise Invalid, "DICTATION_TOKEN has whitespace or control characters" if t.match?(/[\s[:cntrl:]]/)

      t
    end

    # 16 kHz, mono, 16-bit PCM, data chunk at 36 — what the mic sends (lib/dictation.ts pcmToWav); anything else is refused
    def wav!(bytes, settings)
      raise Refused, "recording too long: over #{settings.max_seconds} s" if bytes.bytesize > settings.max_bytes
      raise Refused, "empty recording" if bytes.bytesize <= HEADER

      riff, wave, fmt, pcm, channels, rate, bits, data = bytes.byteslice(0, HEADER).unpack("a4 x4 a4 a4 x4 v v V x6 v a4")
      ok = riff == "RIFF" && wave == "WAVE" && fmt == "fmt " && pcm == 1 && channels == 1 && rate == SAMPLE_RATE &&
           bits == 16 && data == "data"
      raise Refused, "not a 16 kHz mono 16-bit PCM WAV" unless ok

      bytes
    end

    # The speech server, one call per window.
    class Client
      attr_reader :settings, :url

      def initialize(settings, url:, token:, http: nil)
        @settings = settings
        @url = url
        @token = token
        @http = http || method(:post)
      end

      # wav bytes + the text so far → {text:, words: [{word, start, end}]}
      def transcribe(wav, prompt: "")
        Dictation.wav!(wav, settings)
        boundary = "busyyaks#{SecureRandom.hex(12)}"
        p = prompt.to_s
        p = p[-PROMPT_CHARS..] if p.length > PROMPT_CHARS # the end of the text so far: the words just before this window
        status, body = @http.call(url, multipart(wav, p, boundary), boundary)
        raise Unavailable, "speech server answered #{status}: #{detail(body)}" unless status == 200

        parse(body)
      end

      private

      def multipart(wav, prompt, boundary)
        # word timings in both spellings: OpenAI reads timestamp_granularities[], faster-whisper servers the bare name
        fields = [["model", settings.model], ["response_format", "verbose_json"], ["timestamp_granularities[]", "word"],
                  ["timestamp_granularities", "word"],]
        fields << ["prompt", prompt] unless prompt.empty?
        parts = fields.map do |k, v|
          "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n"
        end
        file = "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n" \
               "Content-Type: audio/wav\r\n\r\n"
        (parts.join + file).b + wav.b + "\r\n--#{boundary}--\r\n".b
      end

      def post(uri, body, boundary)
        t = settings.timeout_seconds
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: t, read_timeout: t,
                                            write_timeout: t) do |h|
          req = Net::HTTP::Post.new(uri.request_uri)
          req["Authorization"] = "Bearer #{@token}" if @token
          req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
          req["Accept"] = "application/json"
          req.body = body
          r = h.request(req)
          [r.code.to_i, r.body.to_s]
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
        raise Unavailable, "speech server timed out after #{t} s"
      rescue Net::HTTPBadResponse, Net::ProtocolError => e
        raise Unavailable, "speech server answered no HTTP: #{e.class}: #{e.message}"
      rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
        raise Unavailable, "speech server unreachable: #{e.class}: #{e.message}"
      end

      def detail(body)
        msg = begin
          j = JSON.parse(body)
          err = j.is_a?(Hash) ? j["error"] : nil
          (err.is_a?(Hash) ? err["message"] : err) || (j.is_a?(Hash) && j["detail"]) || body
        rescue JSON::ParserError
          body
        end
        msg.to_s.gsub(/\s+/, " ").strip[0, 300]
      end

      def parse(body)
        j = JSON.parse(body)
        raise Unavailable, "speech server answered no text" unless j.is_a?(Hash) && j["text"].is_a?(String)

        { text: j["text"].strip, words: words_of(j).filter_map { |w| word(w) } }
      rescue JSON::ParserError
        raise Unavailable, "speech server answered no JSON"
      end

      # The word timings, in the one place this answer has them: top-level `words` (OpenAI), or every segment's
      # `words` (faster-whisper servers; no segments = silence = no words). Neither → the server was not asked for
      # them or ignores the ask: refused, never read as "no words" (the mic's window would never move).
      def words_of(j)
        return j["words"] if j["words"].is_a?(Array)

        segs = j["segments"]
        if segs.is_a?(Array) && segs.all? { |s| s.is_a?(Hash) && s["words"].is_a?(Array) }
          return segs.flat_map { |s| s["words"] }
        end

        raise Unavailable, "speech server answered no word timings (verbose_json with timestamp_granularities=word)"
      end

      def word(w)
        return nil unless w.is_a?(Hash) && w["word"].is_a?(String) && w["start"].is_a?(Numeric) && w["end"].is_a?(Numeric)

        { word: w["word"], start: w["start"].to_f, end: w["end"].to_f }
      end
    end
  end
end
