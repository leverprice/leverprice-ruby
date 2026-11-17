# frozen_string_literal: true

module Leverprice
  # @api private
  module Request
    PURPOSE_HEADERS = %w[sec-purpose purpose x-purpose x-moz].freeze
    PURPOSE_RE = /prefetch|prerender|preview/
    COOKIE_SEPARATOR_RE = /[;,]/
    HEX_PAIR_RE = /\A\h\h\z/
    RACK_ENV_MARKERS = %w[REQUEST_METHOD rack.version SERVER_NAME].freeze

    Info = Struct.new(:cookie_input, :assignment_cookies, :pinned, :user_agent, :prefetch, keyword_init: true)

    module_function

    def read(request:, cookie:, user_agent:, cookie_name:)
      explicit = cookie.is_a?(String) ? Util.utf8(cookie) : nil
      cookie_input = explicit || header(request, "cookie")
      pinned = false
      if explicit && !explicit.include?("=")
        value = Util.trim(explicit)
        assignment_cookies = value.empty? ? [] : [value]
      else
        assignment_cookies = cookie_values(cookie_input, cookie_name)
        pinned = !cookie_values(cookie_input, "#{cookie_name}_f").empty?
      end
      Info.new(
        cookie_input: cookie_input,
        assignment_cookies: assignment_cookies,
        pinned: pinned,
        user_agent: user_agent.is_a?(String) ? Util.utf8(user_agent) : header(request, "user-agent"),
        prefetch: prefetch?(request)
      )
    end

    def header(request, name)
      value = lookup(request, name)
      case value
      when String
        Util.utf8(value)
      when Array
        parts = value.grep(String).map { |v| Util.utf8(v) }
        if parts.empty?
          nil
        else
          parts.join(name == "cookie" ? "; " : ", ")
        end
      end
    end

    def cookie_values(header, name)
      return [] if header.nil? || header.empty?

      header.split(COOKIE_SEPARATOR_RE).each_with_object([]) do |part, values|
        eq = part.index("=")
        next if eq.nil? || eq.zero? || Util.trim(part[0, eq]) != name

        value = Util.trim(part[(eq + 1)..])
        value = value[1..-2] if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
        value = percent_decode(value) || value if value.include?("%")
        values << value unless value.empty?
      end
    end

    def prefetch?(request)
      return false if request.nil?

      PURPOSE_HEADERS.each do |name|
        value = header(request, name)
        return true if value && PURPOSE_RE.match?(value.downcase(:ascii))
      end
      header(request, "next-router-prefetch") == "1"
    end

    def scope_holder(request)
      case request
      when Hash
        request
      when nil, String, Symbol, Numeric, true, false
        nil
      else
        stable_env(request) || request
      end
    end

    def stable_env(request)
      env = rack_env(request)
      return nil unless env

      env.equal?(rack_env(request)) ? env : nil
    end

    def lookup(source, name)
      case source
      when nil
        nil
      when Hash
        hash_lookup(source, name)
      else
        object_lookup(source, name)
      end
    rescue StandardError
      nil
    end

    def object_lookup(source, name)
      env = rack_env(source)
      return hash_lookup(env, name) if env
      return source.get_header(rack_key(name)) if source.respond_to?(:get_header)

      if source.respond_to?(:headers)
        headers = source.headers
        return lookup(headers, name) unless headers.equal?(source)
      end
      return nil unless source.respond_to?(:[])

      source[name] || source[canonical(name)]
    end

    def rack_env(source)
      return nil unless source.respond_to?(:env)

      env = source.env
      env.is_a?(Hash) ? env : nil
    rescue StandardError
      nil
    end

    def hash_lookup(hash, name)
      return hash[name] if hash.key?(name)

      key = rack_key(name)
      return hash[key] if hash.key?(key)
      return nil if RACK_ENV_MARKERS.any? { |marker| hash.key?(marker) }

      hash.each { |k, v| return v if key_matches?(k, name) }
      nil
    end

    def key_matches?(key, name)
      case key
      when String
        key.length == name.length && key.downcase(:ascii) == name
      when Symbol
        normalized = key.to_s.downcase(:ascii)
        normalized == name || normalized.tr("_", "-") == name
      else
        false
      end
    end

    def rack_key(name)
      "HTTP_#{name.upcase.tr("-", "_")}"
    end

    def canonical(name)
      name.split("-").map(&:capitalize).join("-")
    end

    # Same contract as JavaScript's decodeURIComponent: nil when an escape is malformed or the
    # decoded bytes are not valid UTF-8.
    def percent_decode(value)
      bytes = value.b
      out = String.new(capacity: bytes.bytesize, encoding: Encoding::BINARY)
      index = 0
      while index < bytes.bytesize
        byte = bytes.getbyte(index)
        if byte == 0x25
          pair = bytes.byteslice(index + 1, 2)
          return nil unless pair && HEX_PAIR_RE.match?(pair)

          out << pair.to_i(16)
          index += 3
        else
          out << byte
          index += 1
        end
      end
      out.force_encoding(Encoding::UTF_8).valid_encoding? ? out : nil
    end
  end
end
