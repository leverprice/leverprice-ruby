# frozen_string_literal: true

module Leverprice
  # @api private
  module ResponseCookies
    module_function

    def write(target, quote)
      values = quote.respond_to?(:set_cookie) ? quote.set_cookie : Array(quote)
      return target if values.nil? || values.empty?

      headers = !target.is_a?(Hash) && target.respond_to?(:headers) ? target.headers : target
      key = header_key(headers)
      existing = headers[key]
      lines = existing.is_a?(Array) ? existing.dup : existing.to_s.split("\n")
      values.each do |value|
        prefix = value[0, value.index("=").to_i + 1]
        lines.reject! { |line| line.start_with?(prefix) }
        lines << value
      end
      headers[key] = existing.is_a?(Array) || rack3? ? lines : lines.join("\n")
      target
    end

    def header_key(headers)
      return "set-cookie" if headers.key?("set-cookie")
      return "Set-Cookie" if headers.key?("Set-Cookie")

      rack3? ? "set-cookie" : "Set-Cookie"
    end

    def rack3?
      defined?(::Rack::RELEASE) ? ::Rack::RELEASE.to_s.split(".").first.to_i >= 3 : false
    end
  end
end
