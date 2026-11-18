# frozen_string_literal: true

module Leverprice
  # The price to show and charge, and why.
  #
  # `reason` is one of "experiment", "base_price", "bot", "disabled", "no_config", "pinned_fallback",
  # "unknown_product", "currency_mismatch" or "out_of_bounds". `country` is the visitor's country (ISO 3166-1
  # alpha-2) when known; with a regional price, `currency` is the region's currency.
  Quote = Struct.new(
    :product_key, :price, :currency, :is_fallback, :reason, :experiment_id, :variant_id,
    :visitor_id, :metadata, :set_cookie, :checkout_url, :exposure_logged, :country, :regional,
    keyword_init: true
  ) do
    # @return [Boolean] true when `price` is the product's `fallback_price`
    def fallback?
      is_fallback
    end

    # @return [Boolean] true when `price` is the regional price of `country`, charged in `currency`
    def regional?
      regional
    end

    # @return [Boolean] true when the price comes from a running experiment
    def experiment?
      reason == "experiment"
    end

    # @return [Boolean] an exposure for this visitor and experiment has been logged
    def exposure_logged?
      exposure_logged
    end
  end
end
