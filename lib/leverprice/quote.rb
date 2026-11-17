# frozen_string_literal: true

module Leverprice
  # The price to show and charge, and why.
  #
  # `reason` is one of "experiment", "base_price", "bot", "disabled", "no_config", "pinned_fallback",
  # "unknown_product", "currency_mismatch" or "out_of_bounds".
  Quote = Struct.new(
    :product_key, :price, :currency, :is_fallback, :reason, :experiment_id, :variant_id, :visitor_id,
    :metadata, :set_cookie, :checkout_url, :exposure_logged,
    keyword_init: true
  ) do
    # @return [Boolean] true when `price` is the product's `fallback_price`
    def fallback?
      is_fallback
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
