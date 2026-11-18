# frozen_string_literal: true

require "set"

module Leverprice
  # A refused config. `code` says why ("malformed", "untrusted", "bad_signature", "expired", "wrong_key",
  # "wrong_project" or "rollback") and is reported to Leverprice with the next config request.
  class ConfigError < Error
    attr_reader :code

    def initialize(code, message)
      super(message)
      @code = code
    end
  end

  # @api private
  module Wire
    PROTOCOL_VERSION = 2
    CONFIG_VERSION_HEADER = "Leverprice-Config-Version"
    MAX_EVENTS_PER_REQUEST = 500
    MAX_MINOR_UNITS = 10_000_000_000
    MAX_REGIONS = 300
    MAX_SPLITS = 300
    MAX_SCOPE = 300
    # The level of a country without a regional price: the standard price.
    STANDARD_LEVEL = 10_000
    MAX_COUNTRY_HOLD = 90 * 86_400
    PROVIDERS = %w[stripe polar lemonsqueezy dodo paddle creem other].freeze
    FINGERPRINT_RE = /\A[0-9a-f]{16}\z/
    SIGNATURE_RE = /\A[0-9a-f]{16}\z/
    CURRENCY_RE = /\A[A-Za-z]{3}\z/
    WIRE_CURRENCY_RE = /\A[a-z]{3}\z/
    COUNTRY_RE = /\A[A-Z]{2}\z/
    HEADER_NAME_RE = /\A[!\#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
    URL_BODY_RE = Regexp.new("\\A[^#{Util::JS_SPACE}]+\\z")

    Variant = Struct.new(:id, :price, :weight, :checkout_url, :regional, keyword_init: true)
    Experiment = Struct.new(:id, :salt, :variants, :scope, :split_of, keyword_init: true)
    # `level`: the price as basis points of the standard price (10000 = the same), to compare countries.
    Region = Struct.new(:countries, :currency, :price, :level, keyword_init: true)
    Product = Struct.new(:id, :currency, :price, :min_price, :max_price, :checkout_url, :regions, :region_of,
                         :experiment, keyword_init: true)
    # `country_hold`: seconds a visitor keeps the price of a dearer country they were seen in; 0 is off.
    Config = Struct.new(:project_id, :version, :issued_at, :expires_at, :assignment_key, :key_fingerprints,
                        :country_header, :country_hold, :products, keyword_init: true)

    module_function

    def parse_config(payload)
      raw = decode(payload, "Leverprice config: payload is not base64url JSON")
      raise Error, "Leverprice config: payload is not an object" unless raw.is_a?(Hash)

      schema = raw["schema"]
      unless schema == PROTOCOL_VERSION
        raise Error, "Leverprice config: unsupported schema #{schema.inspect} " \
                     "(this SDK speaks schema #{PROTOCOL_VERSION})"
      end

      fingerprints = raw["keyFingerprints"]
      unless fingerprints.is_a?(Array) && fingerprints.all? { |f| Util.str_match?(FINGERPRINT_RE, f) }
        raise Error, "Leverprice config: bad keyFingerprints"
      end

      project_id = raw["projectId"]
      raise Error, "Leverprice config: no projectId" unless project_id.is_a?(String) && !project_id.empty?

      version = Util.safe_int(raw["version"])
      raise Error, "Leverprice config: bad version" unless version && version >= 0

      expires_at = raw["expiresAt"]
      raise Error, "Leverprice config: bad expiresAt" unless Util.finite_number?(expires_at)

      assignment_key = raw["assignmentKey"]
      unless assignment_key.is_a?(String) && key_length(assignment_key) >= 32
        raise Error, "Leverprice config: assignmentKey must be at least 32 bytes of base64url"
      end

      products = raw["products"]
      raise Error, "Leverprice config: no products" unless products.is_a?(Hash)

      parsed = {}
      dropped = []
      products.each do |key, value|
        product = parse_product(value)
        product ? parsed[key] = product : dropped << key
      end

      config = Config.new(
        project_id: project_id,
        version: version,
        issued_at: Util.number?(raw["issuedAt"]) ? raw["issuedAt"] : 0,
        expires_at: expires_at,
        assignment_key: assignment_key,
        key_fingerprints: fingerprints,
        country_header: header_name(raw["countryHeader"]),
        country_hold: country_hold(raw["countryHold"]),
        products: parsed
      )
      [config, dropped]
    end

    # A header visitors send themselves would let them pick their own price: never read.
    def header_name(value)
      return nil unless Util.str_match?(HEADER_NAME_RE, value) && !Request.visitor_set_header?(value)

      value.downcase(:ascii)
    end

    def country_hold(value)
      seconds = Util.safe_int(value)
      seconds&.positive? && seconds <= MAX_COUNTRY_HOLD ? seconds : 0
    end

    def parse_product(raw)
      return nil unless raw.is_a?(Hash)

      currency = raw["currency"]
      return nil unless Util.str_match?(CURRENCY_RE, currency)

      price = Util.safe_int(raw["price"])
      min_price = Util.safe_int(raw["minPrice"])
      max_price = Util.safe_int(raw["maxPrice"])
      return nil if price.nil? || min_price.nil? || max_price.nil?

      regions = parse_regions(raw["regions"])
      region_of = regions && index_regions(regions)
      return nil unless region_of

      # A product has at most one test: open to every visitor, or scoped to some countries.
      scoped = raw["experiment"].nil?
      return nil unless scoped || raw["scopedExperiment"].nil?

      experiment = nil
      test = raw[scoped ? "scopedExperiment" : "experiment"]
      unless test.nil?
        experiment = parse_experiment(test, regions.size, scoped: scoped)
        return nil unless experiment
      end

      Product.new(
        id: raw["id"].is_a?(String) ? raw["id"] : "",
        currency: currency.downcase,
        price: price,
        min_price: min_price,
        max_price: max_price,
        checkout_url: https_url(raw["checkoutUrl"]),
        regions: regions,
        region_of: region_of,
        experiment: experiment
      )
    end

    def parse_regions(raw)
      return [] if raw.nil?
      return nil unless raw.is_a?(Array) && raw.size <= MAX_REGIONS

      raw.map do |region|
        return nil unless region.is_a?(Hash) && country_list?(region["countries"])

        currency = region["currency"]
        price = Util.safe_int(region["price"])
        return nil unless Util.str_match?(CURRENCY_RE, currency) && price&.positive?

        # A level this SDK can't read compares as the standard price: it never holds a price.
        level = Util.safe_int(region["level"])
        Region.new(countries: region["countries"], currency: currency.downcase, price: price,
                   level: level&.positive? ? level : STANDARD_LEVEL)
      end
    end

    def country_list?(value)
      value.is_a?(Array) && !value.empty? && value.all? { |country| Util.str_match?(COUNTRY_RE, country) }
    end

    def index_regions(regions)
      region_of = {}
      regions.each_with_index do |region, index|
        region.countries.each do |country|
          return nil if region_of.key?(country)

          region_of[country] = index
        end
      end
      region_of
    end

    def parse_experiment(raw, region_count, scoped:)
      return nil unless raw.is_a?(Hash) && Util.id?(raw["id"]) && raw["salt"].is_a?(String) &&
                        raw["variants"].is_a?(Array)

      variants = raw["variants"].map do |variant|
        return nil unless variant.is_a?(Hash) && Util.id?(variant["id"])

        price = Util.safe_int(variant["price"])
        weight = parse_weight(variant["weight"])
        return nil if price.nil? || weight.nil?

        regional = regional_prices(variant["regional"], region_count)
        return nil unless regional

        Variant.new(id: variant["id"], price: price, weight: weight, checkout_url: https_url(variant["checkoutUrl"]),
                    regional: regional)
      end
      split_of = parse_splits(raw["splits"], variants.size)
      scope = parse_scope(raw["countries"]) if scoped
      return nil if split_of.nil? || (scoped && scope.nil?)

      Experiment.new(id: raw["id"], salt: raw["salt"], variants: variants, scope: scope, split_of: split_of)
    end

    def parse_weight(raw)
      weight = Util.safe_int(raw)
      weight unless weight.nil? || weight.negative?
    end

    def regional_prices(raw, region_count)
      return [] if region_count.zero?
      return nil unless raw.is_a?(Array) && raw.size == region_count

      prices = raw.map { |price| Util.safe_int(price) }
      prices.all? { |price| price&.positive? } ? prices : nil
    end

    def parse_splits(raw, variant_count)
      return {} if raw.nil?
      return nil unless raw.is_a?(Array) && raw.size <= MAX_SPLITS

      raw.each_with_object({}) do |split, split_of|
        return nil unless split.is_a?(Hash) && country_list?(split["countries"])

        weights = split_weights(split["weights"], variant_count)
        return nil unless weights

        split["countries"].each do |country|
          return nil if split_of.key?(country)

          split_of[country] = weights
        end
      end
    end

    def split_weights(raw, variant_count)
      return nil unless raw.is_a?(Array) && raw.size == variant_count

      weights = raw.map { |weight| parse_weight(weight) }
      weights.none?(&:nil?) ? weights : nil
    end

    def parse_scope(raw)
      return nil unless country_list?(raw) && raw.size <= MAX_SCOPE

      scope = raw.to_set
      scope.size == raw.size ? scope : nil
    end

    def https_url(value)
      return nil unless value.is_a?(String)

      url = Util.utf8(value)
      return nil unless url.length > 8 && url[0, 8].downcase(:ascii) == "https://"

      URL_BODY_RE.match?(url[8..]) ? url : nil
    end

    def key_length(str)
      Util.b64url_decode(str).bytesize
    rescue ArgumentError
      0
    end

    def decode(payload, message)
      Util.decode_json_b64(payload)
    rescue StandardError
      raise Error, message
    end

    def event_problem(event)
      timestamp = Util.safe_int(event["timestamp"])
      return "timestamp must be a positive integer (ms)" unless timestamp&.positive?
      return exposure_problem(event) if event["type"] == "exposure"
      return %(unknown provider "#{event["provider"]}") unless PROVIDERS.include?(event["provider"])
      return "orderId must be a string of 1–255 characters" unless text?(event["orderId"])
      return "currency must be a 3-letter ISO 4217 code" unless Util.str_match?(WIRE_CURRENCY_RE, event["currency"])

      event["type"] == "purchase" ? purchase_problem(event) : refund_problem(event)
    end

    def exposure_problem(event)
      unless Util.id?(event["experimentId"]) && Util.id?(event["variantId"]) && Util.id?(event["visitorId"])
        return "invalid experiment/variant/visitor id"
      end
      return nil if !event.key?("country") || Util.str_match?(COUNTRY_RE, event["country"])

      "country must be an ISO 3166-1 alpha-2 code"
    end

    def purchase_problem(event)
      return "amount must be a non-negative integer in minor units" unless minor_units?(event["amount"])

      attribution = event["attribution"]
      return nil if attribution.nil? || attribution == false

      attribution_valid?(attribution) ? nil : "invalid attribution"
    end

    def attribution_valid?(attribution)
      return false unless attribution.is_a?(Hash)
      return false unless Util.id?(attribution["experimentId"]) && Util.id?(attribution["variantId"]) &&
                          Util.id?(attribution["visitorId"])

      signature = attribution["signature"]
      (signature.nil? && attribution.key?("signature")) || Util.str_match?(SIGNATURE_RE, signature)
    end

    def refund_problem(event)
      return "refundId must be a string of 1–255 characters" if event.key?("refundId") && !text?(event["refundId"])
      return "amount must be a non-negative integer" if event.key?("amount") && !minor_units?(event["amount"])
      if event.key?("refundedTotal") && !minor_units?(event["refundedTotal"])
        return "refundedTotal must be a non-negative integer"
      end
      unless (event.key?("refundId") && event.key?("amount")) || event.key?("refundedTotal")
        return "refund needs refundId + amount, or refundedTotal"
      end

      nil
    end

    def minor_units?(value)
      amount = Util.safe_int(value)
      !amount.nil? && amount >= 0 && amount <= MAX_MINOR_UNITS
    end

    def text?(value)
      value.is_a?(String) && Util.js_length(value).between?(1, 255)
    end
  end
end
