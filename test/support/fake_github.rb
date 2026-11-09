# frozen_string_literal: true

require "json"

# A fake api.github.com: every URL answers its current body with an ETag derived from it; If-None-Match on the
# current ETag → 304. Records every request. `fail_with` makes every request answer that status (rate limit, 401).
class FakeGithub
  attr_reader :requests
  attr_accessor :fail_with

  def initialize
    @pages = {}
    @requests = []
    @remaining = 5000
  end

  def set(path, body, link: nil) = @pages["https://api.github.com#{path}"] = [body, link]

  def get(url, headers)
    @requests << [url, headers["If-None-Match"], headers["Accept"]]
    raise "no Authorization header" unless headers["Authorization"]&.start_with?("Bearer ")

    if fail_with
      st, msg = fail_with
      limits = { "x-ratelimit-remaining" => (st == 403 ? "0" : "4999"), "x-ratelimit-limit" => "5000",
                 "x-ratelimit-reset" => "1800000000", }
      return [st, limits, JSON.generate(message: msg)]
    end
    body, link = @pages[url] || (url.match?(/following\?per_page=100&page=\d+\z/) ? [[], nil] : nil)
    return [404, rate, JSON.generate(message: "Not Found #{url}")] unless body

    json = JSON.generate(body)
    etag = %(W/"#{json.hash.abs}")
    return [304, rate.merge("etag" => etag), ""] if headers["If-None-Match"] == etag

    @remaining -= 1
    h = rate.merge("etag" => etag)
    h["link"] = %(<https://api.github.com#{link}>; rel="next") if link
    [200, h, json]
  end

  def rate = { "x-ratelimit-limit" => "5000", "x-ratelimit-remaining" => @remaining.to_s, "x-ratelimit-reset" => "1800000000" }
  def counted = @requests.size
end
