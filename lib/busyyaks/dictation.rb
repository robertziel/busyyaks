# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module Busyyaks
  # Dictation: the card dialog's mic sends 16 kHz mono 16-bit WAV windows to POST /api/dictation, which
  # forwards each to the deployment's speech server — any OpenAI-compatible POST /v1/audio/transcriptions (a vLLM
  # fleet's load balancer serving whisper or parakeet, vexa's transcription service, a faster-whisper server) — and
  # answers {text, words}. The server's URL and token stay on the server side; the browser never sees the token.
  #
  # All of it is Settings → Dictation (Busyyaks::DictationSettings, card 634: on/off, the server's URL + token, model,
  # timeout_seconds, max_seconds — revisions in the database). Nothing about the server is env any more: the old
  # .env DICTATION_URL / DICTATION_TOKEN are refused by bin/setup check, naming the move.
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

    # url = the endpoint (URI, endpoint!), token = the bearer or nil (token!) — set by DictationSettings.settings!
    Settings = Struct.new(:model, :timeout_seconds, :max_seconds, :url, :token, keyword_init: true) do
      def max_bytes = HEADER + (max_seconds * SAMPLE_RATE * 2)
    end

    module_function

    # {model, timeout_seconds, max_seconds} (a Settings → Dictation revision's, DictationSettings) → Settings
    def parse!(value)
      unless value.is_a?(Hash) && value.keys.sort == KEYS.sort
        raise Invalid, "dictation needs exactly #{KEYS.join(', ')}"
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

    # → Client for these settings (their url + token); nil = dictation is off.
    def client(settings, http: nil)
      return nil if settings.nil?

      Client.new(settings, url: settings.url, token: settings.token, http: http)
    end

    # The model ids the server at `url` lists (OpenAI-compatible GET /v1/models, next to the transcription endpoint) —
    # what Settings → Dictation offers and checks a save against. Unreachable, an error answer or no list →
    # Unavailable with the reason.
    def models(url:, token:, timeout:, http: nil)
      uri = url.dup
      uri.path = "#{uri.path.delete_suffix(PATH)}/v1/models"
      status, body = (http || method(:get)).call(uri, token, timeout)
      raise Unavailable, "speech server answered #{status} to GET #{uri.path}" unless status == 200

      data = JSON.parse(body)["data"] if body.start_with?("{")
      ids = Array(data).map { |m| m["id"] if m.is_a?(Hash) }
      raise Unavailable, "speech server's GET #{uri.path} answered no model list" unless data.is_a?(Array) && ids.all?(String)

      ids
    rescue JSON::ParserError
      raise Unavailable, "speech server's GET /v1/models answered no JSON"
    end

    def get(uri, token, timeout)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout) do |h|
        req = Net::HTTP::Get.new(uri.request_uri)
        req["Authorization"] = "Bearer #{token}" if token
        req["Accept"] = "application/json"
        r = h.request(req)
        [r.code.to_i, r.body.to_s]
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise Unavailable, "speech server timed out after #{timeout} s"
    rescue Net::HTTPBadResponse, Net::ProtocolError, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise Unavailable, "speech server unreachable: #{e.class}: #{e.message}"
    end

    # One second of silence in the mic's WAV (Settings → Dictation's Test: the chosen model answers with its word timings)
    def silence(seconds = 1)
      data = "\0".b * (seconds * SAMPLE_RATE * 2)
      ["RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16, "data", data.bytesize]
        .pack("a4 V a4 a4 V v v V V v v a4 V") + data
    end

    # the base (https://host) or the full endpoint (https://host/v1/audio/transcriptions) → the endpoint
    def endpoint!(raw)
      uri = URI.parse(raw.to_s.strip.chomp("/"))
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise Invalid, "url must be an http(s) URL without credentials, query or fragment"
      end

      uri.path = uri.path.end_with?(PATH) ? uri.path : "#{uri.path}#{PATH}"
      uri
    rescue URI::InvalidURIError
      raise Invalid, "url is not a URL"
    end

    # nil = no Authorization header (the speech server takes none)
    def token!(raw)
      t = raw.to_s
      return nil if t.empty?
      raise Invalid, "token has whitespace or control characters" if t.match?(/[\s[:cntrl:]]/)

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

        { text: j["text"].strip, words: spaced(words_of(j).filter_map { |w| word(w) }, j["text"]) }
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

      # Each word carries the space before it, as the answer's text has it (the mic joins the words as given:
      # lib/dictation.ts joinWords). Whisper servers send " word"; OpenAI and NeMo/Parakeet servers send "word" — read
      # from the text, never assumed. The words must spell the text in order, only whitespace between them: an empty
      # word, or one the text does not hold right after the word before → refused, never guessed.
      def spaced(words, text)
        at = 0
        words.map do |w|
          bare = w[:word].strip
          i = bare.empty? ? nil : text.index(bare, at)
          unless i && text[at...i].match?(/\A\s*\z/)
            raise Unavailable, "speech server's word #{bare.inspect} does not follow in its text #{detail(text).inspect}"
          end

          gap = text[at...i]
          at = i + bare.length
          w.merge(word: (gap.empty? ? "" : " ") + bare)
        end
      end

      def word(w)
        return nil unless w.is_a?(Hash) && w["word"].is_a?(String) && w["start"].is_a?(Numeric) && w["end"].is_a?(Numeric)

        { word: w["word"], start: w["start"].to_f, end: w["end"].to_f }
      end
    end
  end
end
