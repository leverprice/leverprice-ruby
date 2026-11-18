# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"

module Leverprice
  # @api private
  module Util
    MAX_SAFE_INTEGER = 9_007_199_254_740_991
    ID_RE = /\A[A-Za-z0-9_-]{1,64}\z/
    B64URL_RE = /\A[A-Za-z0-9_-]*\z/
    JS_SPACE = '\s   -     　﻿'
    TRIM_RE = Regexp.new("\\A[#{JS_SPACE}]+|[#{JS_SPACE}]+\\z")
    ED25519_SPKI_PREFIX = ["302a300506032b6570032100"].pack("H*").freeze
    UTF_8 = Encoding::UTF_8
    JSON_OPTIONS =
      if Gem::Version.new(JSON::VERSION) >= Gem::Version.new("2.13.0")
        { allow_duplicate_key: true }.freeze
      else
        {}.freeze
      end

    module_function

    def utf8(value)
      str = value.is_a?(String) ? value : value.to_s
      encoding = str.encoding
      return str if encoding == UTF_8 && str.valid_encoding?

      if str.valid_encoding? && ![UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(encoding)
        begin
          return str.encode(UTF_8)
        rescue EncodingError
          nil
        end
      end
      forced = str.dup.force_encoding(UTF_8)
      forced.valid_encoding? ? forced : str.dup.force_encoding(Encoding::ISO_8859_1).encode(UTF_8)
    end

    def trim(value)
      utf8(value).gsub(TRIM_RE, "")
    end

    def js_length(str)
      str = utf8(str)
      str.ascii_only? ? str.bytesize : str.encode(Encoding::UTF_16LE).bytesize / 2
    end

    def text(bytes)
      str = bytes.to_s.dup.force_encoding(UTF_8)
      str = str.scrub("�") unless str.valid_encoding?
      str.delete_prefix("﻿")
    end

    def str_match?(regexp, value)
      value.is_a?(String) && regexp.match?(value)
    rescue ArgumentError, EncodingError
      false
    end

    def id?(value)
      str_match?(ID_RE, value)
    end

    def number?(value)
      value.is_a?(Integer) || value.is_a?(Float)
    end

    def finite_number?(value)
      number?(value) && value.to_f.finite?
    end

    def safe_int(value)
      case value
      when Integer
        value.abs <= MAX_SAFE_INTEGER ? value : nil
      when Float
        value.finite? && value == value.floor && value.abs <= MAX_SAFE_INTEGER ? value.to_i : nil
      end
    end

    def js_round(value)
      floor = value.floor
      value - floor >= 0.5 ? floor + 1 : floor
    end

    def parse_json(text)
      JSON.parse(text, **JSON_OPTIONS)
    end

    def b64url_encode(bytes)
      [bytes].pack("m0").tr("+/", "-_").delete("=")
    end

    def b64url_decode(str)
      raise ArgumentError, "invalid base64url" unless str_match?(B64URL_RE, str) && str.length % 4 != 1

      standard = str.tr("-_", "+/")
      standard << ("=" * ((4 - (standard.length % 4)) % 4))
      standard.unpack1("m")
    end

    def decode_json_b64(str)
      parse_json(text(b64url_decode(str)))
    end

    def hex(bytes)
      bytes.unpack1("H*")
    end

    def sha256(bytes)
      OpenSSL::Digest::SHA256.digest(bytes)
    end

    def hmac(key, data)
      OpenSSL::HMAC.digest("SHA256", key, utf8(data).b)
    end

    def hmac_hex(key, data, chars)
      hex(hmac(key, data))[0, chars]
    end

    def secure_equal?(left, right)
      left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
    end

    def random_hex(bytes)
      SecureRandom.hex(bytes)
    end

    def bucket_for(salt, visitor_id)
      sha256(utf8(salt).b + ":".b + utf8(visitor_id).b).unpack1("N") % 10_000
    end

    def pick_variant(variants, bucket, weights = nil)
      accumulated = 0
      variants.each_with_index do |variant, index|
        accumulated += weights ? weights.fetch(index, 0) : variant.weight
        return variant if bucket < accumulated
      end
      variants.last
    end

    def ed25519_verify(public_key, signature, data)
      return false unless public_key.is_a?(String) && signature.is_a?(String) && data.is_a?(String)

      raw = b64url_decode(public_key)
      sig = b64url_decode(signature)
      return false unless raw.bytesize == 32 && sig.bytesize == 64

      OpenSSL::PKey.read(ED25519_SPKI_PREFIX + raw).verify(nil, sig, utf8(data).b) == true
    rescue StandardError
      false
    end

    def iso_time(millis)
      Time.at(millis.to_r / 1000).utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    rescue StandardError
      millis.to_s
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wall_millis
      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    end
  end
end
