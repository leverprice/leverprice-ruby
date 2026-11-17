# frozen_string_literal: true

require_relative "leverprice/version"

# Server-side SDK for Leverprice price experiments.
module Leverprice
  # Raised for invalid options; also the class of every error passed to `on_error`.
  class Error < StandardError; end

  # Leverprice's offline root public keys (raw Ed25519, base64url) by id.
  ROOT_PUBLIC_KEYS = { "r1" => "5FmNzXvPMPZEuDnFT_fFd_VVNsUrWwWTKLerMWbSdcg" }.freeze

  # Keysets below this version are refused even by a fresh process.
  MIN_KEYSET_VERSION = 1

  class << self
    # @param user_agent [String, nil]
    # @return [Boolean] true for crawlers, link previewers, headless browsers, monitors and HTTP tools
    def bot?(user_agent)
      Bots.bot?(user_agent)
    end

    # Appends a quote's `Set-Cookie` values to a Rails, Sinatra or Rack response, or to a Rack headers Hash.
    # Works with Rack 2 (newline-joined) and Rack 3 (array) headers.
    # @param target [#headers, Hash]
    # @param quote [Quote, Array<String>]
    # @return [Object] target
    def write_cookies(target, quote)
      ResponseCookies.write(target, quote)
    end

    # @return [Boolean] true when the environment variable LEVERPRICE_DISABLED is "1" or "true"
    def env_disabled?
      value = ENV.fetch("LEVERPRICE_DISABLED", nil)
      !value.nil? && %w[1 true].include?(Util.trim(value).downcase)
    rescue StandardError
      false
    end
  end
end

require_relative "leverprice/util"
require_relative "leverprice/bots"
require_relative "leverprice/wire"
require_relative "leverprice/trust"
require_relative "leverprice/cookie"
require_relative "leverprice/request"
require_relative "leverprice/transport"
require_relative "leverprice/quote"
require_relative "leverprice/process"
require_relative "leverprice/client"
require_relative "leverprice/rack"
