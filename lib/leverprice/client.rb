# frozen_string_literal: true

require "monitor"

module Leverprice
  # Prices products, logs exposures and reports purchases. Thread-safe and fork-safe; share one instance.
  class Client
    DEFAULT_API_URL = "https://api.leverprice.com"
    USER_AGENT = "leverprice-sdk-ruby/#{VERSION}".freeze
    SDK_INFO = { "name" => "leverprice-ruby", "version" => VERSION }.freeze
    KEY_RE = /\App_sk_(?:live|test)_[0-9A-Za-z]{40}\z/
    HEADER_NAME_RE = Wire::HEADER_NAME_RE
    COOKIE_NAME_RE = HEADER_NAME_RE
    ASCII_SPACE_ENDS_RE = /\A[ \t\n\x0B\x0C\r]+|[ \t\n\x0B\x0C\r]+\z/
    SIG_RE = /\A[0-9a-f]{16}\z/
    DIGITS_RE = /\A\d+\z/
    PIN_MAX_AGE_SECONDS = 1800
    REQUEST_TIMEOUT_MS = 10_000
    STALL_MS = REQUEST_TIMEOUT_MS + 5_000
    MAX_QUEUE = 5_000
    AUTO_FLUSH_AT = 100
    SEND_ATTEMPTS = 3
    MAX_BACKOFF_MS = 30_000
    CATCH_UP_GAP_MS = 5_000
    MAX_DEDUPE = 10_000
    IDLE_WAIT_SECONDS = 60

    Guard = Struct.new(:currency, :fallback_price)
    Region = Struct.new(:index, :currency, :price)
    Scope = Struct.new(:mutex, :cookie, :pinned)
    ScopeCookie = Struct.new(:input, :user_id, :assignment_key, :state)
    Context = Struct.new(:cookie, :user_agent, :user_id, :exposure, :bot, :country, keyword_init: true)
    private_constant :Guard, :Region, :Scope, :ScopeCookie, :Context

    # @api private
    class Flight
      attr_reader :started_at

      def initialize(started_at)
        @started_at = started_at
        @mutex = Mutex.new
        @finished = ConditionVariable.new
        @done = false
      end

      def finish
        @mutex.synchronize do
          @done = true
          @finished.broadcast
        end
      end

      def wait(seconds)
        deadline = Util.monotonic + seconds
        @mutex.synchronize do
          until @done
            remaining = deadline - Util.monotonic
            break unless remaining.positive?

            @finished.wait(@mutex, remaining)
          end
        end
        @done
      end
    end
    private_constant :Flight

    # @param products [Hash] product key => `{ currency:, fallback_price: }` in minor units; `min_price:` and
    #   `max_price:` are deprecated and ignored since 0.4: the price range is set in Leverprice
    # @param secret_key [String, nil] `pp_sk_live_…` or `pp_sk_test_…`; missing or malformed turns the SDK off
    # @param country_header [String, nil] request header your CDN or host sets to the visitor's country, such as
    #   `cf-ipcountry`; overrides the project's setting. Name only a header visitors cannot set
    # @param local_currencies [Boolean] serve regional prices in the visitor's currency, not only in each product's
    #   own; set it only when your checkout charges `quote.price` in `quote.currency`
    # @raise [ArgumentError] for invalid products, cookie_name or country_header
    def initialize(products:, secret_key: nil, disabled: false, api_url: nil, timeout_ms: nil,
                   refresh_interval_ms: nil, max_stale_ms: nil, cookie_name: nil, cookie_max_age_seconds: nil,
                   cookie_secure: nil, cookie_domain: nil, country_header: nil, local_currencies: false,
                   flush_interval_ms: nil, trusted_root_keys: nil, transport: nil, on_error: nil, logger: nil,
                   clock: nil, sleeper: nil)
      @guards = normalize_guards(products)
      @disabled = disabled == true
      @api_url = (api_url || DEFAULT_API_URL).to_s.sub(%r{/+\z}, "")
      @timeout_ms = timeout_ms || 500
      @refresh_interval_ms = refresh_interval_ms || 30_000
      @max_stale_ms = max_stale_ms || 86_400_000
      @cookie_name = cookie_name || "__pp"
      unless Util.str_match?(COOKIE_NAME_RE, @cookie_name)
        raise ArgumentError, "Leverprice: cookie_name is not a valid cookie name"
      end

      @cookie_max_age = Util.safe_int(cookie_max_age_seconds) || cookie_max_age_seconds || 15_552_000
      @cookie_secure = cookie_secure != false
      @cookie_domain = cookie_domain
      @country_header = normalize_country_header(country_header)
      @local_currencies = local_currencies == true
      @flush_interval_ms = flush_interval_ms || 2_000
      @transport = transport || NetHTTPTransport.new
      raise ArgumentError, "Leverprice: transport must respond to #call" unless @transport.respond_to?(:call)

      @on_error = on_error
      @logger = logger
      @clock = clock
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @trust = TrustChain.new(trusted_root_keys || ROOT_PUBLIC_KEYS, MIN_KEYSET_VERSION)
      key = secret_key.is_a?(String) ? Util.trim(secret_key) : ""
      @secret_key = Util.str_match?(KEY_RE, key) ? key : nil
      @acceptance = Acceptance.new(@trust, @secret_key)
      @exposed = {}
      @etag = nil
      @fetched_at = 0
      @failures = 0
      @retry_at = 0
      @server_version = 0
      @catch_up_at = 0
      @hmac_cache = nil
      @closed = false
      reset_runtime
      @scope_ivar = :"@__leverprice_scope_#{ForkTracker.register(self)}"
      return if key.empty? || @secret_key || @disabled || Leverprice.env_disabled?

      emit(Error.new("Leverprice: secret_key is not a pp_sk_live_… / pp_sk_test_… key; serving fallback prices."))
    end

    # Returns the price to show and charge. Raises only for a product key missing from `products`.
    # @param product_key [String, Symbol]
    # @param request [Object, nil] Rack env, Rack/ActionDispatch request, object with `#headers`, or a header Hash
    # @param cookie [String, nil] the Cookie header (or the bare `__pp` value); overrides `request`
    # @param user_agent [String, nil] overrides the request's User-Agent
    # @param user_id [String, Integer, nil] your signed-in user's id; only its HMAC leaves your server
    # @param exposure [:auto, :manual, nil] `:manual` assigns without logging; call {#log_exposure} later
    # @param bot [Boolean, nil] your own bot verdict, skipping the built-in check
    # @param country [String, Symbol, nil] the visitor's country (ISO 3166-1 alpha-2); overrides every country header
    # @return [Quote]
    # @raise [ArgumentError] when `product_key` is not configured
    def get_price(product_key, request: nil, cookie: nil, user_agent: nil, user_id: nil, exposure: nil, bot: nil,
                  country: nil)
      key = product_key.to_s
      guard = @guards[key]
      raise ArgumentError, %(Leverprice: unknown product "#{key}". Add it to the products option.) unless guard
      return fallback_quote(key, guard, "disabled") if off?

      check_fork
      context = Context.new(cookie: cookie, user_agent: user_agent, user_id: user_id, exposure: exposure, bot: bot,
                            country: country)
      scope = scope_for(request)
      return compute_quote(key, guard, request, context, nil) unless scope

      scope.mutex.synchronize { compute_quote(key, guard, request, context, scope) }
    end

    # Logs the exposure of a quote obtained with `exposure: :manual`. Never raises.
    # @param quote [Quote]
    # @return [Boolean] true when an exposure was queued
    def log_exposure(quote)
      return false if off?

      check_fork
      return false unless quote.respond_to?(:reason) && quote.reason == "experiment" && !quote.exposure_logged

      experiment_id = quote.experiment_id
      variant_id = quote.variant_id
      visitor_id = quote.visitor_id
      return false if [experiment_id, variant_id, visitor_id].any? { |id| id.nil? || id.empty? }

      country = quote.respond_to?(:country) ? Request.normalize_country(quote.country) : nil
      queued = record_exposure(experiment_id, variant_id, visitor_id, country)
      quote.exposure_logged = true
      queued
    rescue StandardError => e
      report(e)
      false
    end

    # Reports a completed purchase and sends it right away. Never raises.
    # @param provider [String, Symbol] "stripe", "polar", "lemonsqueezy", "dodo", "paddle", "creem" or "other"
    # @param order_id [String, Integer] the id your provider's webhook reports
    # @param amount [Integer] minor units, after discounts, excluding tax
    # @param currency [String]
    # @param metadata [Hash, nil] the checkout's metadata (pp_exp, pp_var, pp_vid, pp_sig)
    # @param timestamp [Integer, Time, nil] milliseconds or Unix seconds; defaults to now
    # @return [nil]
    def track_purchase(provider: nil, order_id: nil, amount: nil, currency: nil, metadata: nil, timestamp: nil,
                       **unknown)
      return nil if off?

      check_fork
      report_unknown("track_purchase", unknown)
      enqueue(
        "type" => "purchase",
        "provider" => Util.utf8(provider.to_s),
        "orderId" => id_of(order_id),
        "amount" => amount_of(amount),
        "currency" => Util.utf8(currency.to_s).downcase,
        "timestamp" => timestamp_of(timestamp),
        "attribution" => attribution_of(metadata)
      )
      flush
    rescue StandardError => e
      report(e)
      nil
    end

    # Reports a refund (one refund by id with its amount, or the order's cumulative refunded total). Never raises.
    # @param refund_id [String, Integer, nil] with `amount`
    # @param refunded_total [Integer, nil] instead of `refund_id` and `amount`
    # @return [nil]
    def track_refund(provider: nil, order_id: nil, currency: nil, refund_id: nil, amount: nil, refunded_total: nil,
                     timestamp: nil, **unknown)
      return nil if off?

      check_fork
      report_unknown("track_refund", unknown)
      event = {
        "type" => "refund",
        "provider" => Util.utf8(provider.to_s),
        "orderId" => id_of(order_id),
        "currency" => Util.utf8(currency.to_s).downcase,
        "timestamp" => timestamp_of(timestamp)
      }
      if refunded_total.nil?
        event["refundId"] = id_of(refund_id)
        event["amount"] = amount_of(amount)
      else
        event["refundedTotal"] = amount_of(refunded_total)
      end
      enqueue(event)
      flush
    rescue StandardError => e
      report(e)
      nil
    end

    # Sends queued events now and waits until done. Never raises.
    # @return [nil]
    def flush
      check_fork
      @lock.synchronize { @flush_due = nil }
      @drain_lock.synchronize { drain }
      nil
    rescue StandardError => e
      report(e)
      nil
    end

    # Fetches the config now and waits for it. Never raises.
    # @return [nil]
    def refresh
      return nil if off?

      check_fork
      previous = @lock.synchronize { @inflight }
      previous&.wait(STALL_MS / 1000.0)
      @lock.synchronize { start_fetch(force: true) }&.wait(STALL_MS / 1000.0)
      nil
    rescue StandardError => e
      report(e)
      nil
    end

    # Fetches the config unless one is usable, so the first visitors do not wait. Never raises.
    # @return [nil]
    def preload
      return nil if off?

      check_fork
      flight = @lock.synchronize { usable(now) ? nil : start_fetch(force: true) }
      return nil unless flight

      flight.wait(STALL_MS / 1000.0)
      @lock.synchronize { @retry_at = 0 unless usable(now) }
      nil
    rescue StandardError => e
      report(e)
      nil
    end

    # Flushes queued events and stops the background flush thread. Never raises.
    # @return [nil]
    def close
      check_fork
      flusher = @lock.synchronize do
        @closed = true
        @flush_due = nil
        @wakeup.broadcast
        @flusher
      end
      flush
      flusher&.join(1)
      nil
    rescue StandardError => e
      report(e)
      nil
    end

    # @return [Boolean] true while the kill switch is on or no valid secret key is configured
    def disabled?
      off?
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} api_url=#{@api_url.inspect} products=#{@guards.keys.inspect} disabled=#{off?}>"
    end

    # @api private
    def after_fork
      reset_runtime unless @pid == Process.pid
    end

    private

    def reset_runtime
      @lock = Monitor.new
      @wakeup = @lock.new_cond
      @drain_lock = Monitor.new
      @inflight = nil
      @queue = []
      @flusher = nil
      @flush_due = nil
      @flush_now = false
      @pid = Process.pid
    end

    def check_fork
      return if @pid == Process.pid

      ForkTracker.lock.synchronize { after_fork }
    end

    def off?
      @disabled || @secret_key.nil? || Leverprice.env_disabled?
    end

    def now
      @clock ? @clock.call : Util.wall_millis
    end

    def report(error)
      emit(error) unless off?
    end

    def emit(error)
      error = Error.new(error.to_s) unless error.is_a?(Exception)
      if @on_error
        @on_error.call(error)
      elsif @logger
        @logger.warn(error.message)
      else
        Kernel.warn(error.message)
      end
    rescue StandardError
      nil
    end

    def report_unknown(method, unknown)
      return if unknown.empty?

      report(Error.new("Leverprice: #{method} ignores unknown keywords #{unknown.keys.join(", ")}"))
    end

    def spawn(name)
      Thread.new do
        Thread.current.name = name
        Thread.current.report_on_exception = false
        yield
      end
    end

    def compute_quote(key, guard, request, context, scope)
      bot = false
      info = Request.read(request: request, cookie: context.cookie, user_agent: context.user_agent,
                          cookie_name: @cookie_name, country: context.country, country_header: @country_header)
      bot = [true, false].include?(context.bot) ? context.bot : Bots.bot?(info.user_agent)
      return bot_quote(key, guard) if bot

      if info.pinned || scope&.pinned
        @lock.synchronize { kick(now) }
        return fallback_quote(key, guard, "pinned_fallback", [pin_cookie])
      end

      config = current_config
      return no_config(key, guard, scope) unless config

      info.country = Request.country_of(request, context.country, config.country_header) unless @country_header
      product = config.products[key]
      return fallback_quote(key, guard, "unknown_product") unless product
      return fallback_quote(key, guard, "currency_mismatch") unless product.currency == guard.currency

      experiment = experiment_for(product, info.country)
      return base_quote(key, guard, product, info.country) unless experiment
      if experiment.variants.empty? || !experiment.variants.all? { |v| in_bounds?(product, v.price) }
        return fallback_quote(key, guard, "out_of_bounds")
      end

      region = region_for(guard, product, info.country)
      experiment_quote(key, guard, context, info, scope, config, product, experiment, region)
    rescue StandardError => e
      report(e)
      bot ? fallback_quote(key, guard, "bot") : no_config(key, guard, scope)
    end

    # The test the visitor is in. A scoped test runs only for visitors from its countries: everyone else,
    # and anyone whose country is unknown, is priced as if the product had no test.
    def experiment_for(product, country)
      experiment = product.experiment
      return experiment if experiment.nil? || experiment.scope.nil?

      experiment.scope.include?(country) ? experiment : nil
    end

    def base_quote(key, guard, product, country)
      return fallback_quote(key, guard, "out_of_bounds") unless in_bounds?(product, product.price)

      region = region_for(guard, product, country)
      quote = if region
                regional_quote(key, guard, region, "base_price")
              else
                price_quote(key, guard, product.price, "base_price", product.checkout_url)
              end
      quote.country = country
      quote
    end

    # The visitor's region when its price may be served: in the guard's currency, or in any with local currencies.
    def region_for(guard, product, country)
      return nil if country.nil?

      index = product.region_of[country]
      return nil unless index

      region = product.regions[index]
      return nil unless region.currency == guard.currency || @local_currencies

      Region.new(index, region.currency, region.price)
    end

    def bot_quote(key, guard)
      product = current_config&.products&.fetch(key, nil)
      if product && product.currency == guard.currency && in_bounds?(product, product.price)
        return price_quote(key, guard, product.price, "bot", product.checkout_url)
      end

      fallback_quote(key, guard, "bot")
    end

    def experiment_quote(key, guard, context, info, scope, config, product, experiment, region)
      hmac_key = hmac_key_for(config.assignment_key)
      user_id = normalize_user_id(context.user_id)
      state = prior_state(scope, info, user_id, config) || verified_state(hmac_key, info)
      changed = state.nil?
      state ||= Cookie.new_state(Util.random_hex(16))

      visitor_key = user_id ? "u:#{user_id}" : "a:#{state.v}"
      visitor_id = Util.hmac_hex(hmac_key, "pp:visitor:v1:#{visitor_key}", 32)
      assigned = state.a[experiment.id]
      sticky = assigned && experiment.variants.find { |v| v.id == assigned }
      variant = sticky || Util.pick_variant(experiment.variants, Util.bucket_for(experiment.salt, visitor_id),
                                            experiment.split_of[info.country])
      unless sticky
        Cookie.assign(state, experiment.id, variant.id)
        changed = true
      end

      logged = state.x.include?(experiment.id) || exposed?(experiment.id, visitor_id)
      if !logged && auto_exposure?(context.exposure) && !info.prefetch
        record_exposure(experiment.id, variant.id, visitor_id, info.country)
        logged = true
      end
      changed = true if logged && Cookie.mark_exposed(state, experiment.id)
      scope.cookie = ScopeCookie.new(info.cookie_input, user_id, config.assignment_key, state) if scope

      signature = Util.hmac_hex(hmac_key, "pp:attr:v1:#{experiment.id}:#{variant.id}:#{visitor_id}", 16)
      Quote.new(
        product_key: key,
        price: region ? variant.regional[region.index] : variant.price,
        currency: region ? region.currency : guard.currency,
        country: info.country,
        regional: !region.nil?,
        is_fallback: false,
        reason: "experiment",
        experiment_id: experiment.id,
        variant_id: variant.id,
        visitor_id: visitor_id,
        metadata: { "pp_exp" => experiment.id, "pp_var" => variant.id, "pp_vid" => visitor_id, "pp_sig" => signature },
        set_cookie: changed ? [assignment_cookie(hmac_key, state)] : [],
        checkout_url: region ? nil : (variant.checkout_url || product.checkout_url),
        exposure_logged: logged
      )
    end

    def prior_state(scope, info, user_id, config)
      prior = scope&.cookie
      return nil unless prior && prior.input == info.cookie_input && prior.user_id == user_id &&
                        prior.assignment_key == config.assignment_key

      Cookie.clone_state(prior.state)
    end

    def verified_state(hmac_key, info)
      info.assignment_cookies.first(4).each do |raw|
        state = Cookie.verify(hmac_key, raw)
        return state if state
      end
      nil
    end

    def no_config(key, guard, scope)
      scope.pinned = true if scope
      fallback_quote(key, guard, "no_config", [pin_cookie])
    end

    def assignment_cookie(hmac_key, state)
      Cookie.header(@cookie_name, Cookie.sign(hmac_key, state), @cookie_max_age,
                    secure: @cookie_secure, domain: @cookie_domain)
    end

    def pin_cookie
      Cookie.header("#{@cookie_name}_f", "1", PIN_MAX_AGE_SECONDS, secure: @cookie_secure, domain: @cookie_domain)
    end

    def fallback_quote(key, guard, reason, set_cookie = [])
      Quote.new(
        product_key: key,
        price: guard.fallback_price,
        currency: guard.currency,
        country: nil,
        regional: false,
        is_fallback: true,
        reason: reason,
        experiment_id: nil,
        variant_id: nil,
        visitor_id: nil,
        metadata: {},
        set_cookie: set_cookie,
        checkout_url: nil,
        exposure_logged: false
      )
    end

    def price_quote(key, guard, price, reason, checkout_url)
      quote = fallback_quote(key, guard, reason)
      quote.price = price
      quote.is_fallback = false
      quote.checkout_url = checkout_url
      quote
    end

    def regional_quote(key, guard, region, reason)
      quote = fallback_quote(key, guard, reason)
      quote.price = region.price
      quote.currency = region.currency
      quote.regional = true
      quote.is_fallback = false
      quote
    end

    def in_bounds?(product, price)
      value = Util.safe_int(price)
      !value.nil? && value.positive? && value >= product.min_price && value <= product.max_price
    end

    def auto_exposure?(exposure)
      exposure.nil? || exposure.to_s == "auto"
    end

    def hmac_key_for(assignment_key)
      cached = @hmac_cache
      return cached[1] if cached && cached[0] == assignment_key

      key = Util.b64url_decode(assignment_key)
      @hmac_cache = [assignment_key, key].freeze
      key
    end

    def scope_for(request)
      holder = Request.scope_holder(request)
      return nil if holder.nil? || holder.frozen?

      @lock.synchronize do
        holder.instance_variable_get(@scope_ivar) ||
          holder.instance_variable_set(@scope_ivar, Scope.new(Mutex.new, nil, false))
      end
    rescue StandardError
      nil
    end

    def normalize_guards(products)
      products ||= {}
      raise ArgumentError, "Leverprice: products must be a Hash" unless products.is_a?(Hash)

      products.each_with_object({}) do |(key, guard), guards|
        guards[key.to_s] = normalize_guard("Leverprice: products.#{key}", guard)
      end.freeze
    end

    def normalize_guard(where, guard)
      currency = option(guard, :currency)
      unless Util.str_match?(Wire::CURRENCY_RE, currency)
        raise ArgumentError, %(#{where}.currency must be an ISO 4217 code such as "usd")
      end

      fallback_price = Util.safe_int(option(guard, :fallback_price, :fallbackPrice))
      unless fallback_price&.positive?
        raise ArgumentError, "#{where}.fallback_price must be a positive integer (minor units)"
      end

      Guard.new(currency.downcase, fallback_price).freeze
    end

    def normalize_country_header(value)
      return nil if value.nil?

      name = value.is_a?(String) ? value.b.gsub(ASCII_SPACE_ENDS_RE, "") : value
      return nil if name == ""
      return name.downcase.force_encoding(Util::UTF_8) if Util.str_match?(HEADER_NAME_RE, name)

      raise ArgumentError, "Leverprice: country_header is not a valid header name"
    end

    def option(hash, *names)
      return nil unless hash.is_a?(Hash)

      names.each do |name|
        return hash[name] if hash.key?(name)
        return hash[name.to_s] if hash.key?(name.to_s)
      end
      nil
    end

    def normalize_user_id(value)
      case value
      when String then value.empty? ? nil : Util.utf8(value)
      when Integer then value.to_s
      when Float then Util.safe_int(value)&.to_s
      end
    end

    def current_config
      started = now
      flight = nil
      @lock.synchronize do
        ready = usable(started)
        kick(started)
        return ready if ready

        flight = live_flight(started)
      end
      return nil unless flight

      remaining = @timeout_ms - (started - flight.started_at)
      flight.wait(remaining / 1000.0) if remaining.positive?
      @lock.synchronize { usable(now) }
    end

    def usable(at)
      loaded = @acceptance.loaded
      return nil unless loaded

      config = loaded.config
      return nil if at >= config.expires_at || at - @fetched_at >= @max_stale_ms
      return nil unless @trust.trusted?(loaded.signing_key)

      config
    end

    def loaded_version
      @acceptance.config&.version || 0
    end

    def kick(at)
      return if live_flight(at)

      if @server_version > loaded_version && at >= @catch_up_at
        @catch_up_at = at + CATCH_UP_GAP_MS
        start_fetch(unconditional: true)
      elsif !usable(at) || at - @fetched_at >= @refresh_interval_ms
        start_fetch
      end
    end

    def live_flight(at)
      flight = @inflight
      flight if flight && at - flight.started_at < STALL_MS
    end

    def start_fetch(force: false, unconditional: false)
      at = now
      live = live_flight(at)
      return live if live
      return nil if !force && at < @retry_at

      flight = Flight.new(at)
      @inflight = flight
      begin
        spawn("leverprice-config") { run_fetch(flight, unconditional) }
      rescue ThreadError => e
        @inflight = nil
        flight.finish
        report(e)
        return nil
      end
      flight
    end

    def run_fetch(flight, unconditional)
      load_config(unconditional)
    ensure
      @lock.synchronize { @inflight = nil if @inflight.equal?(flight) }
      flight.finish
    end

    def load_config(unconditional)
      headers = {}
      @lock.synchronize { headers["If-None-Match"] = @etag if !unconditional && @etag && usable(now) }
      response = http("GET", "/v1/config", headers)
      warning = @lock.synchronize { apply_config(response, headers.key?("If-None-Match")) }
      report(Error.new(warning)) if warning
    rescue StandardError => e
      @lock.synchronize do
        @failures += 1
        @retry_at = now + [MAX_BACKOFF_MS, 500 * (2**[@failures, 16].min)].min
      end
      report(e)
    end

    def apply_config(response, revalidating)
      warning = nil
      unless response.status == 304 && revalidating
        unless (200..299).cover?(response.status)
          raise Error, "Leverprice config: HTTP #{response.status}#{error_code(response.body)}"
        end

        warning = @acceptance.accept(parse_envelope(response.body), now).warning
        @etag = response.header("ETag")
      end
      @fetched_at = now
      @failures = 0
      @retry_at = 0
      note_server_version(response)
      warning
    end

    def parse_envelope(body)
      Util.parse_json(body)
    rescue StandardError
      raise Error, "Leverprice config: response is not JSON"
    end

    def note_server_version(response)
      raw = response.header(Wire::CONFIG_VERSION_HEADER)
      value = raw.nil? ? "" : Util.trim(raw)
      return unless Util.str_match?(DIGITS_RE, value)

      version = Util.safe_int(value.to_i)
      return unless version && version > @server_version

      @server_version = version
      kick(now) if version > loaded_version
    end

    def error_code(body)
      parsed = Util.parse_json(body)
      code = parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"]["code"] : nil
      code.is_a?(String) ? " (#{code})" : ""
    rescue StandardError
      ""
    end

    def http(method, path, headers, body = nil)
      request_headers = headers.merge("Authorization" => "Bearer #{@secret_key}", "User-Agent" => USER_AGENT)
      raw = with_deadline(method, path) do
        @transport.call(method: method, url: "#{@api_url}#{path}", headers: request_headers, body: body,
                        timeout: REQUEST_TIMEOUT_MS / 1000.0)
      end
      to_response(raw)
    end

    def with_deadline(method, path)
      result = nil
      failure = nil
      worker = spawn("leverprice-http") do
        result = yield
      rescue StandardError => e
        failure = e
      end
      unless worker.join(REQUEST_TIMEOUT_MS / 1000.0)
        worker.kill
        raise Error, "Leverprice: #{method} #{path} timed out after #{REQUEST_TIMEOUT_MS} ms"
      end
      raise failure if failure.is_a?(Error)
      raise Error, "Leverprice: #{method} #{path} failed: #{failure.message} (#{failure.class})" if failure

      result
    end

    def to_response(raw)
      status, headers, body = raw.is_a?(Array) ? raw : [raw.status, raw.headers, raw.body]
      body = body.join if body.is_a?(Array)
      Response.new(Integer(status), headers || {}, Util.text(body))
    rescue StandardError => e
      raise Error, "Leverprice: the transport returned an unusable response (#{e.class})"
    end

    def exposed?(experiment_id, visitor_id)
      @lock.synchronize { @exposed.key?("#{experiment_id}:#{visitor_id}") }
    end

    def record_exposure(experiment_id, variant_id, visitor_id, country)
      key = "#{experiment_id}:#{visitor_id}"
      fresh = @lock.synchronize do
        next false if @exposed.key?(key)

        @exposed.clear if @exposed.size >= MAX_DEDUPE
        @exposed[key] = true
      end
      return false unless fresh

      event = {
        "type" => "exposure",
        "experimentId" => experiment_id,
        "variantId" => variant_id,
        "visitorId" => visitor_id,
        "timestamp" => now
      }
      event["country"] = country if country && country != ""
      enqueue(event)
    end

    def attribution_of(metadata)
      ids = %w[pp_exp pp_var pp_vid].map { |name| metadata_value(metadata, name) }
      return nil unless ids.all? { |id| Util.id?(id) }

      signature = metadata_value(metadata, "pp_sig")
      {
        "experimentId" => ids[0],
        "variantId" => ids[1],
        "visitorId" => ids[2],
        "signature" => Util.str_match?(SIG_RE, signature) ? signature : nil
      }
    end

    def metadata_value(metadata, name)
      source = metadata_source(metadata)
      return nil unless source

      [name, name.to_sym].each { |key| return source[key] if source.key?(key) }
      nil
    rescue StandardError
      nil
    end

    def metadata_source(metadata)
      return metadata if metadata.is_a?(Hash) || (metadata.respond_to?(:key?) && metadata.respond_to?(:[]))
      return metadata.to_hash if metadata.respond_to?(:to_hash)

      metadata.to_h if metadata.respond_to?(:to_h)
    end

    def id_of(value)
      case value
      when String then Util.utf8(value)
      when Integer then value.to_s
      when Float then Util.safe_int(value).to_s
      else ""
      end
    end

    def amount_of(value)
      return value unless value.is_a?(Numeric) && value.real?
      return value if value.is_a?(Float) && !value.finite?

      Util.js_round(value)
    end

    def timestamp_of(value)
      case value
      when nil
        now
      when Time
        Util.js_round(value.to_r * 1000)
      when Numeric
        return value unless value.real? && (!value.is_a?(Float) || value.finite?)

        Util.js_round(value < 1e12 ? value * 1000 : value)
      else
        value.respond_to?(:to_time) && !value.is_a?(String) ? Util.js_round(value.to_time.to_r * 1000) : value
      end
    end

    def enqueue(event)
      problem = Wire.event_problem(event)
      if problem
        report(Error.new("Leverprice: dropped invalid #{event["type"]} event: #{problem}"))
        return false
      end

      dropped = @lock.synchronize do
        @queue << event
        overflow = trim_queue
        if @queue.size >= AUTO_FLUSH_AT
          @flush_now = true
        else
          @flush_due ||= Util.monotonic + (@flush_interval_ms / 1000.0)
        end
        ensure_flusher
        @wakeup.broadcast
        overflow
      end
      dropped.each { |error| report(error) }
      true
    end

    def trim_queue
      errors = []
      while @queue.size > MAX_QUEUE
        dropped = @queue.delete_at(@queue.index { |e| e["type"] == "exposure" } || 0)
        next if dropped["type"] == "exposure"

        errors << Error.new("Leverprice: event queue full, dropped #{dropped["type"]} #{dropped["orderId"]}")
      end
      errors
    end

    def ensure_flusher
      return if @closed || @flusher&.alive?

      @flusher = spawn("leverprice-flush") { flusher_loop }
    rescue ThreadError
      @flusher = nil
    end

    def flusher_loop
      @drain_lock.synchronize { drain } while wait_for_flush
    end

    def wait_for_flush
      @lock.synchronize do
        loop do
          return false if @closed

          if @flush_now || (@flush_due && Util.monotonic >= @flush_due)
            @flush_now = false
            @flush_due = nil
            return true
          end
          @wakeup.wait(@flush_due ? [@flush_due - Util.monotonic, 0.001].max : IDLE_WAIT_SECONDS)
        end
      end
    end

    def drain
      return if off?

      size = Wire::MAX_EVENTS_PER_REQUEST
      batches = @lock.synchronize { (@queue.size + size - 1) / size }
      batches.times do
        batch = @lock.synchronize { @queue.shift(size) }
        break if batch.empty? || !send_batch(batch)
      end
    rescue StandardError => e
      report(e)
    end

    def send_batch(events)
      body = JSON.generate({ "events" => events, "sdk" => SDK_INFO })
      last_error = nil
      SEND_ATTEMPTS.times do |attempt|
        break if off?

        @sleeper.call(0.25 * (4**(attempt - 1))) if attempt.positive?
        begin
          response = http("POST", "/v1/events", { "Content-Type" => "application/json" }, body)
          @lock.synchronize { note_server_version(response) }
          return true if (200..299).cover?(response.status)

          if response.status < 500 && ![408, 429].include?(response.status)
            report(Error.new("Leverprice events rejected: HTTP #{response.status} #{response.body[0, 300]}"))
            return true
          end
          last_error = Error.new("Leverprice events: HTTP #{response.status}")
        rescue StandardError => e
          last_error = e
        end
      end
      requeue(events)
      report(last_error) if last_error
      false
    end

    def requeue(events)
      money = events.reject { |e| e["type"] == "exposure" }
      return if money.empty?

      dropped = @lock.synchronize do
        @queue.unshift(*money)
        trim_queue
      end
      dropped.each { |error| report(error) }
    end
  end
end
