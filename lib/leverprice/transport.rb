# frozen_string_literal: true

require "net/http"
require "uri"

module Leverprice
  # An HTTP response as returned by a transport.
  Response = Struct.new(:status, :headers, :body) do
    # @param name [String] case-insensitive header name
    # @return [String, nil]
    def header(name)
      value = find_header(name)
      value.is_a?(Array) ? value.join(", ") : value
    end

    private

    def find_header(name)
      source = headers
      return nil if source.nil?
      return source[name] unless source.is_a?(Hash)
      return source[name] if source.key?(name)

      lower = name.downcase
      source.each_pair { |key, value| return value if key.to_s.downcase == lower }
      nil
    end
  end

  # Default transport: Net::HTTP with a new connection per request.
  #
  # A transport is any object with `call(method:, url:, headers:, body:, timeout:)` returning a
  # {Response} (or anything with `status`, `headers` and `body`, or a Rack-style `[status, headers, body]`).
  class NetHTTPTransport
    # @return [Response]
    def call(method:, url:, headers:, body: nil, timeout: 10)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout
      http.ssl_timeout = timeout
      request = (method == "POST" ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      headers.each { |name, value| request[name] = value }
      request.body = body if body
      response = http.start { |connection| connection.request(request) }
      Response.new(response.code.to_i, response.each_header.to_h, response.body.to_s)
    end
  end
end
