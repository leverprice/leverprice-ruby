# frozen_string_literal: true

module Leverprice
  # @api private
  module Wire
    PROTOCOL_VERSION = 2
    CONFIG_VERSION_HEADER = "Leverprice-Config-Version"
    MAX_EVENTS_PER_REQUEST = 500
    MAX_MINOR_UNITS = 10_000_000_000
    PROVIDERS = %w[stripe polar lemonsqueezy dodo other].freeze
    FINGERPRINT_RE = /\A[0-9a-f]{16}\z/
    SIGNATURE_RE = /\A[0-9a-f]{16}\z/
    CURRENCY_RE = /\A[A-Za-z]{3}\z/
    WIRE_CURRENCY_RE = /\A[a-z]{3}\z/
    URL_BODY_RE = Regexp.new("\\A[^#{Util::JS_SPACE}]+\\z")

    Variant = Struct.new(:id, :price, :weight, :checkout_url, keyword_init: true)
    Experiment = Struct.new(:id, :salt, :variants, keyword_init: true)
    Product = Struct.new(:id, :currency, :price, :min_price, :max_price, :checkout_url, :experiment,
                         keyword_init: true)
    Config = Struct.new(:project_id, :version, :issued_at, :expires_at, :assignment_key, :key_fingerprints,
                        :products, keyword_init: true)

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
        products: parsed
      )
      [config, dropped]
    end

    def parse_product(raw)
      return nil unless raw.is_a?(Hash)

      currency = raw["currency"]
      return nil unless Util.str_match?(CURRENCY_RE, currency)

      price = Util.safe_int(raw["price"])
      min_price = Util.safe_int(raw["minPrice"])
      max_price = Util.safe_int(raw["maxPrice"])
      return nil if price.nil? || min_price.nil? || max_price.nil?

      experiment = nil
      unless raw["experiment"].nil?
        experiment = parse_experiment(raw["experiment"])
        return nil unless experiment
      end

      Product.new(
        id: raw["id"].is_a?(String) ? raw["id"] : "",
        currency: currency.downcase,
        price: price,
        min_price: min_price,
        max_price: max_price,
        checkout_url: https_url(raw["checkoutUrl"]),
        experiment: experiment
      )
    end

    def parse_experiment(raw)
      return nil unless raw.is_a?(Hash) && Util.id?(raw["id"]) && raw["salt"].is_a?(String) &&
                        raw["variants"].is_a?(Array)

      variants = raw["variants"].map do |variant|
        return nil unless variant.is_a?(Hash) && Util.id?(variant["id"])

        price = Util.safe_int(variant["price"])
        weight = Util.safe_int(variant["weight"])
        return nil if price.nil? || weight.nil? || weight.negative?

        Variant.new(id: variant["id"], price: price, weight: weight, checkout_url: https_url(variant["checkoutUrl"]))
      end
      Experiment.new(id: raw["id"], salt: raw["salt"], variants: variants)
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

      if event["type"] == "exposure"
        valid = Util.id?(event["experimentId"]) && Util.id?(event["variantId"]) && Util.id?(event["visitorId"])
        return valid ? nil : "invalid experiment/variant/visitor id"
      end
      return %(unknown provider "#{event["provider"]}") unless PROVIDERS.include?(event["provider"])
      return "orderId must be a string of 1–255 characters" unless text?(event["orderId"])
      return "currency must be a 3-letter ISO 4217 code" unless Util.str_match?(WIRE_CURRENCY_RE, event["currency"])

      event["type"] == "purchase" ? purchase_problem(event) : refund_problem(event)
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
