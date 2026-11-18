# frozen_string_literal: true

module Leverprice
  # @api private
  module Request
    PURPOSE_HEADERS = %w[sec-purpose x-sec-purpose purpose x-purpose x-moz].freeze
    PURPOSE_RE = /prefetch|prerender|preview/
    COOKIE_SEPARATOR_RE = /[;,]/
    HEX_PAIR_RE = /\A\h\h\z/
    RACK_ENV_MARKERS = %w[REQUEST_METHOD rack.version SERVER_NAME].freeze
    NOT_A_COUNTRY = %w[XX ZZ T1 A1 A2 AP EU].freeze
    COUNTRY_INPUT_RE = /\A[ \t\n\x0B\x0C\r]*([A-Za-z]{2})[ \t\n\x0B\x0C\r]*\z/
    # Headers every browser or client sends itself: never a source for the visitor's country.
    VISITOR_SET_PREFIX_RE = /\A(?:sec-|accept|content-|if-|x-forwarded-|proxy-)/
    VISITOR_SET_HEADERS = %w[
      authorization cache-control connection cookie dnt forwarded host origin pragma priority purpose range referer
      te upgrade-insecure-requests user-agent via x-real-ip x-requested-with
    ].freeze
    # Headers proxies and hosts set to the visitor's address, in the order they are read.
    ADDRESS_HEADERS = %w[
      cf-connecting-ip true-client-ip fastly-client-ip fly-client-ip x-real-ip x-forwarded-for
    ].freeze
    IPV4_RE = /\A(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\z/
    HEX_GROUP_RE = /\A[0-9A-Fa-f]{1,4}\z/
    ADDRESS_BLANKS_RE = /\A[ \t]+|[ \t]+\z/
    BRACKET_PORT_RE = /\A:[0-9]{1,5}\z/
    IPV4_PORT_RE = /\A[0-9.]+:[0-9]{1,5}\z/

    Info = Struct.new(:cookie_input, :assignment_cookies, :pinned, :user_agent, :prefetch, :country,
                      keyword_init: true)

    module_function

    def read(request:, cookie:, user_agent:, cookie_name:, country:, country_header:)
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
        prefetch: prefetch?(request),
        country: country_of(request, country, country_header)
      )
    end

    # A country passed in is final even when it is invalid: the header is never consulted instead.
    def country_of(request, explicit, country_header)
      explicit = explicit.to_s if explicit.is_a?(Symbol)
      return normalize_country(explicit) if explicit.is_a?(String)

      country_header ? normalize_country(header(request, country_header)) : nil
    end

    def normalize_country(value)
      return nil unless value.is_a?(String)

      code = value.b[COUNTRY_INPUT_RE, 1]
      return nil unless code

      code = code.upcase.force_encoding(Util::UTF_8)
      NOT_A_COUNTRY.include?(code) ? nil : code
    end

    def visitor_set_header?(name)
      return false unless name.is_a?(String)

      lower = name.b.downcase
      VISITOR_SET_PREFIX_RE.match?(lower) || VISITOR_SET_HEADERS.include?(lower)
    end

    # The visitor's address: the first address header that holds one, else the connection's.
    def client_address(request)
      return nil if request.nil?

      ADDRESS_HEADERS.each do |name|
        value = header(request, name)
        next if value.nil?

        address = normalize_address(value.split(",", 2).first)
        return address if address
      end
      normalize_address(connection_address(request))
    end

    # `REMOTE_ADDR` of a Rack env, or of the env behind a Rack or ActionDispatch request.
    def connection_address(request)
      env = request.is_a?(Hash) ? request : rack_env(request)
      if env
        return nil unless RACK_ENV_MARKERS.any? { |marker| env.key?(marker) }

        return env["REMOTE_ADDR"]
      end
      request.respond_to?(:get_header) ? request.get_header("REMOTE_ADDR") : nil
    rescue StandardError
      nil
    end

    # IPv4 in decimal, IPv6 cut to its /64 network as four lowercase hex groups, IPv4-mapped IPv6 as IPv4;
    # brackets, a port and a zone are dropped. nil for anything else.
    def normalize_address(value)
      return nil unless value.is_a?(String)

      text = Util.utf8(value).b.gsub(ADDRESS_BLANKS_RE, "")
      if text.start_with?("[")
        close = text.index("]")
        return nil if close.nil?

        rest = text[(close + 1)..]
        return nil unless rest.empty? || BRACKET_PORT_RE.match?(rest)

        text = text[1...close]
      elsif IPV4_PORT_RE.match?(text)
        text = text[0, text.index(":")]
      end
      zone = text.index("%")
      text = text[0, zone] if zone
      v4 = ipv4(text)
      return v4.join(".") if v4

      groups = ipv6(text)
      return nil unless groups
      if groups[0, 5].all?(&:zero?) && groups[5] == 0xffff
        return [groups[6] >> 8, groups[6] & 255, groups[7] >> 8, groups[7] & 255].join(".")
      end

      groups[0, 4].map { |group| group.to_s(16) }.join(":")
    end

    def ipv4(text)
      match = IPV4_RE.match(text)
      return nil unless match

      parts = match.captures.map(&:to_i)
      parts.all? { |part| part <= 255 } ? parts : nil
    end

    def ipv6(text)
      if text.include?(".")
        colon = text.rindex(":")
        v4 = colon && ipv4(text[(colon + 1)..])
        return nil unless v4

        text = "#{text[0..colon]}#{((v4[0] << 8) | v4[1]).to_s(16)}:#{((v4[2] << 8) | v4[3]).to_s(16)}"
      end
      halves = text.split("::", -1)
      return nil if halves.empty? || halves.size > 2

      head = halves[0].split(":", -1)
      tail = halves[1]&.split(":", -1)
      groups = head + (tail || [])
      return nil unless groups.all? { |group| HEX_GROUP_RE.match?(group) }

      values = groups.map { |group| group.to_i(16) }
      return values.size == 8 ? values : nil if tail.nil?
      return nil if groups.size > 7

      head_values = values.first(head.size)
      head_values + ([0] * (8 - groups.size)) + values.drop(head.size)
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
