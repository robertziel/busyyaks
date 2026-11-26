# frozen_string_literal: true

require "busyyaks/dictation"
require "busyyaks/dictation_settings"
require "busyyaks/kanban"

module Busyyaks
  module Actions
    module API
      module Dictation
        # POST /api/dictation — multipart: audio = one window of the card dialog's mic (16 kHz mono 16-bit WAV), prompt =
        # the text so far → {text, words: [{word, start, end}]} from the speech server (Busyyaks::Dictation). Multipart,
        # not a raw body: the router reads a raw body as a query string.
        # off (Settings → Dictation) → 404; not that WAV → 400; longer than max_seconds → 413; the server unreachable,
        # timed out or answering an error → 502 with its reason; a stored revision refused → 503 with the reason.
        class Transcribe < Busyyaks::Action
          def handle(req, res)
            client = Busyyaks::Dictation.client(Busyyaks::DictationSettings.get(Busyyaks::Kanban.db))
            return json(res, 404, error: "dictation is off: Settings → Dictation") unless client

            wav = read(req.params[:audio], client.settings.max_bytes + 1)
            json(res, 200, client.transcribe(wav, prompt: req.params[:prompt].to_s))
          rescue Busyyaks::Dictation::Refused => e
            json(res, e.message.start_with?("recording too long") ? 413 : 400, error: e.message)
          rescue Busyyaks::Dictation::Unavailable => e
            json(res, 502, error: e.message)
          rescue Busyyaks::Dictation::Invalid, Busyyaks::DictationSettings::Refused => e
            json(res, 503, error: "dictation is misconfigured: #{e.message}")
          end

          private

          # the uploaded part, at most `limit` bytes: one byte past max_bytes is enough to refuse it as too long
          def read(part, limit)
            io = part.is_a?(Hash) && (part[:tempfile] || part["tempfile"])
            raise Busyyaks::Dictation::Refused, "no audio part (multipart field `audio`)" unless io.respond_to?(:read)

            io.rewind
            io.read(limit).to_s.b
          end

          def json(res, status, body)
            res.status = status
            res.headers["Content-Type"] = "application/json"
            res.body = JSON.generate(body)
          end
        end
      end
    end
  end
end
