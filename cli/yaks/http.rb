# frozen_string_literal: true

require "json"
require "net/http"

module Busyyaks
  module CLI
    # The HTTP calls of `server status`: → [code, body] or raises Http::Down with the reason (refused, timeout).
    module Http
      class Down < StandardError; end

      TIMEOUT = 5

      module_function

      def get(host, port, path, headers)
        call(host, port) { |h| h.get(path, headers) }
      end

      def post(host, port, path, headers, body)
        call(host, port) { |h| h.post(path, body, headers) }
      end

      def call(host, port)
        res = Net::HTTP.start(host, Integer(port), open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |h| yield h }
        [res.code.to_i, res.body.to_s]
      rescue SystemCallError, IOError, Timeout::Error, SocketError => e
        raise Down, "#{host}:#{port}: #{e.message}"
      end
    end
  end
end
