# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  include TestHelpers

  def setup
    @signer = Signer.new
    @envelope = @signer.envelope
  end

  def test_cold_start_that_times_out_returns_no_config_within_timeout
    release = Queue.new
    transport = FakeTransport.new(config: lambda { |_call|
      release.pop
      [503, {}, ""]
    })
    client = build_client(transport: transport, timeout_ms: 400)
    started = monotonic
    first = Thread.new { [client.get_price("pro", request: browser), monotonic] }
    sleep 0.2
    late_started = monotonic
    late = Thread.new { [client.get_price("pro", request: browser), monotonic] }
    first_quote, first_done = first.value
    late_quote, late_done = late.value

    assert_equal "no_config", first_quote.reason
    assert_equal [PIN], first_quote.set_cookie
    assert_equal "no_config", late_quote.reason
    assert_operator first_done - started, :>=, 0.38
    assert_operator first_done - started, :<, 1.5
    assert_operator late_done - late_started, :<, 0.38
    assert_equal 1, transport.config_calls.size
  ensure
    release&.close
  end

  def test_outage_returns_no_config_with_pin_then_pinned_fallback
    clock = TestClock.new
    transport = FakeTransport.new(config: ->(_call) { [503, {}, '{"error":{"code":"unavailable"}}'] })
    client = build_client(transport: transport, clock: clock)

    quote = client.get_price("pro", request: browser)

    assert_equal "no_config", quote.reason
    assert_predicate quote, :fallback?
    assert_equal 1900, quote.price
    assert_equal [PIN], quote.set_cookie
    assert_includes errors, "Leverprice config: HTTP 503 (unavailable)"

    pinned = client.get_price("pro", request: browser("cookie" => "__pp_f=1"))

    assert_equal "pinned_fallback", pinned.reason
    assert_equal [PIN], pinned.set_cookie

    clock.advance(60_000)
    env = { "REQUEST_METHOD" => "GET", "HTTP_USER_AGENT" => CHROME }

    assert_equal "no_config", client.get_price("pro", request: env).reason
    assert_equal "pinned_fallback", client.get_price("team", request: env).reason
  end

  def test_failed_fetches_back_off_and_preload_does_not_delay_the_first_request
    clock = TestClock.new
    transport = FakeTransport.new(config: ->(_call) { [500, {}, ""] })
    client = build_client(transport: transport, clock: clock)

    client.get_price("pro", request: browser)
    wait_idle(client)

    assert_equal 1, transport.config_calls.size

    clock.advance(500)

    assert_equal "no_config", client.get_price("pro", request: browser).reason
    assert_equal 1, transport.config_calls.size

    clock.advance(600)
    client.get_price("pro", request: browser)
    wait_idle(client)

    assert_equal 2, transport.config_calls.size

    client.preload

    assert_equal 3, transport.config_calls.size
    client.get_price("pro", request: browser)
    wait_idle(client)

    assert_equal 4, transport.config_calls.size
  end

  def test_not_modified_revalidation_keeps_the_config
    clock = TestClock.new
    envelope = @envelope
    transport = FakeTransport.new(config: lambda { |call|
      call.headers["If-None-Match"] == '"v1"' ? [304, {}, ""] : [200, { "ETag" => '"v1"' }, JSON.generate(envelope)]
    })
    client = build_client(transport: transport, clock: clock, max_stale_ms: 60_000)

    assert_equal "base_price", client.get_price("basic").reason
    refute transport.config_calls.first.headers.key?("If-None-Match")

    clock.advance(31_000)

    assert_equal "base_price", client.get_price("basic").reason
    wait_until { transport.config_calls.size == 2 }
    wait_idle(client)

    assert_equal '"v1"', transport.config_calls.last.headers["If-None-Match"]
    assert_equal clock.now, client.instance_variable_get(:@fetched_at)

    clock.advance(40_000)

    assert_equal "base_price", client.get_price("basic").reason
    wait_until { transport.config_calls.size == 3 }
    wait_idle(client)

    assert_equal '"v1"', transport.config_calls.last.headers["If-None-Match"]
    assert_empty errors
  end

  def test_newer_config_version_header_triggers_an_unconditional_fetch
    served = [@envelope]
    transport = FakeTransport.new(
      config: ->(_call) { [200, { "ETag" => %("v#{served.size}") }, JSON.generate(served.last)] },
      events: ->(_call) { [202, { "Leverprice-Config-Version" => "2" }, "{}"] }
    )
    client = build_client(transport: transport, clock: TestClock.new)

    assert_equal 900, client.get_price("basic").price

    served << @signer.envelope(version: 2, products: Signer.products(price: 1200))
    client.track_purchase(provider: "stripe", order_id: "pi_1", amount: 900, currency: "usd")
    wait_until { transport.config_calls.size == 2 }
    wait_idle(client)

    refute transport.config_calls.last.headers.key?("If-None-Match")
    assert_equal 1200, client.get_price("basic").price
    assert_empty errors
  end

  def test_failed_event_sends_requeue_purchases_and_drop_exposures
    status = 503
    waits = []
    transport = FakeTransport.serving(@envelope)
    transport.events_handler = ->(_call) { [status, {}, ""] }
    client = build_client(transport: transport, sleeper: ->(seconds) { waits << seconds })

    assert_equal "experiment", client.get_price("pro", request: browser).reason
    client.track_purchase(provider: "stripe", order_id: "pi_1", amount: 1900, currency: "usd")

    assert_equal 3, transport.event_calls.size
    assert_equal [0.25, 1.0], waits
    assert_equal(%w[exposure purchase], JSON.parse(transport.event_calls.first.body)["events"].map { |e| e["type"] })
    assert_includes errors, "Leverprice events: HTTP 503"

    status = 202
    client.flush

    assert_equal 4, transport.event_calls.size
    assert_equal(%w[purchase], JSON.parse(transport.event_calls.last.body)["events"].map { |e| e["type"] })
  end

  def test_a_400_is_not_retried
    transport = FakeTransport.serving(@envelope)
    transport.events_handler = ->(_call) { [400, {}, "bad request"] }
    client = build_client(transport: transport)

    client.track_purchase(provider: "stripe", order_id: "pi_1", amount: 1900, currency: "usd")
    client.flush

    assert_equal 1, transport.event_calls.size
    assert_includes errors, "Leverprice events rejected: HTTP 400 bad request"
  end

  def test_kill_switch_option
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport, disabled: true)
    quote = client.get_price("pro", request: browser)

    assert_equal "disabled", quote.reason
    assert_predicate quote, :fallback?
    assert_empty quote.set_cookie
    refute client.log_exposure(quote)
    client.track_purchase(provider: "stripe", order_id: "pi_1", amount: 1900, currency: "usd")
    client.track_refund(provider: "stripe", order_id: "pi_1", currency: "usd", refunded_total: 1900)
    client.refresh
    client.preload
    client.flush

    assert_predicate client, :disabled?
    assert_empty transport.calls
    assert_empty errors
  end

  def test_kill_switch_environment_is_read_on_every_call
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport)

    with_env("LEVERPRICE_DISABLED", " TRUE ") do
      assert_equal "disabled", client.get_price("pro", request: browser).reason
      assert_predicate client, :disabled?
    end
    with_env("LEVERPRICE_DISABLED", "1") { assert_equal "disabled", client.get_price("basic").reason }
    assert_empty transport.calls

    with_env("LEVERPRICE_DISABLED", "0") { assert_equal "base_price", client.get_price("basic").reason }
    refute_predicate client, :disabled?
  end

  def test_malformed_secret_key_disables_the_sdk_and_reports_once
    transport = FakeTransport.serving(@envelope)
    client = Leverprice::Client.new(secret_key: "  pp_sk_live_short  ", products: PRODUCTS, transport: transport,
                                    on_error: ->(e) { errors << e.message })

    assert_equal 1, errors.size
    assert_match(/\ALeverprice: secret_key is not a pp_sk_live_/, errors.first)
    assert_equal "disabled", client.get_price("pro", request: browser).reason
    client.track_purchase(provider: "stripe", order_id: "pi_1", amount: 1900, currency: "usd")

    assert_equal 1, errors.size
    assert_empty transport.calls
  end

  def test_missing_secret_key_is_silent_and_whitespace_is_trimmed
    Leverprice::Client.new(secret_key: nil, products: PRODUCTS, on_error: ->(e) { errors << e.message })
    with_env("LEVERPRICE_DISABLED", "true") do
      Leverprice::Client.new(secret_key: "bad", products: PRODUCTS, on_error: ->(e) { errors << e.message })
    end

    assert_empty errors

    client = build_client(transport: FakeTransport.serving(@envelope), secret_key: "\t#{SECRET_KEY}\n")

    refute_predicate client, :disabled?
    assert_equal "base_price", client.get_price("basic").reason
  end

  def test_a_throwing_on_error_changes_nothing
    transport = FakeTransport.new(config: ->(_call) { [503, {}, ""] })
    client = Leverprice::Client.new(secret_key: SECRET_KEY, products: PRODUCTS, transport: transport,
                                    on_error: ->(_e) { raise "boom" })

    quote = client.get_price("pro", request: browser)

    assert_equal "no_config", quote.reason
    assert_nil client.track_purchase(provider: "paypal", order_id: "x", amount: 1, currency: "usd")
    refute client.log_exposure(quote)
    assert_nil client.flush
  end

  def test_track_purchase_reads_attribution_from_metadata_and_converts_seconds
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport)
    quote = client.get_price("pro", request: browser)

    assert_predicate quote, :experiment?

    client.track_purchase(provider: :stripe, order_id: "pi_1", amount: 2900.4, currency: "USD",
                          metadata: quote.metadata, timestamp: 1_800_000_000)
    client.track_purchase(provider: "stripe", order_id: 42, amount: 2900, currency: "usd",
                          metadata: quote.metadata.transform_keys(&:to_sym).merge(pp_sig: "nothex"),
                          timestamp: Time.at(1_800_000_000, 500, :millisecond))
    client.track_purchase(provider: "stripe", order_id: "pi_3", amount: 2900, currency: "usd",
                          metadata: quote.metadata.except("pp_vid"), timestamp: 1_800_000_000_123)

    purchases = transport.events.select { |e| e["type"] == "purchase" }
    attribution = {
      "experimentId" => quote.experiment_id,
      "variantId" => quote.variant_id,
      "visitorId" => quote.visitor_id,
      "signature" => quote.metadata["pp_sig"]
    }

    assert_equal(
      { "type" => "purchase", "provider" => "stripe", "orderId" => "pi_1", "amount" => 2900, "currency" => "usd",
        "timestamp" => 1_800_000_000_000, "attribution" => attribution },
      purchases[0]
    )
    assert_equal "42", purchases[1]["orderId"]
    assert_equal 1_800_000_000_500, purchases[1]["timestamp"]
    assert_equal attribution.merge("signature" => nil), purchases[1]["attribution"]
    assert_equal 1_800_000_000_123, purchases[2]["timestamp"]
    assert_nil purchases[2]["attribution"]
    assert_empty errors
  end

  def test_track_refund_shapes_and_invalid_events
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport, clock: TestClock.new)

    client.track_refund(provider: "stripe", order_id: "pi_1", currency: "usd", refund_id: "re_1", amount: 500)
    client.track_refund(provider: "other", order_id: "pi_1", currency: "usd", refunded_total: 2900)
    client.track_refund(provider: "stripe", order_id: "pi_1", currency: "usd", refund_id: "re_2")
    client.track_purchase(provider: "paypal", order_id: "x", amount: 1, currency: "usd")
    client.track_purchase(provider: "stripe", orderId: "x", amount: 1, currency: "usd")

    assert_equal(
      [
        { "type" => "refund", "provider" => "stripe", "orderId" => "pi_1", "currency" => "usd",
          "timestamp" => 1_800_000_000_000, "refundId" => "re_1", "amount" => 500 },
        { "type" => "refund", "provider" => "other", "orderId" => "pi_1", "currency" => "usd",
          "timestamp" => 1_800_000_000_000, "refundedTotal" => 2900 }
      ],
      transport.events
    )
    assert_includes errors, "Leverprice: dropped invalid refund event: amount must be a non-negative integer"
    assert_includes errors, 'Leverprice: dropped invalid purchase event: unknown provider "paypal"'
    assert_includes errors, "Leverprice: track_purchase ignores unknown keywords orderId"
  end

  def test_root_public_keys_are_valid_ed25519_keys
    assert_equal({ "r1" => "5FmNzXvPMPZEuDnFT_fFd_VVNsUrWwWTKLerMWbSdcg" }, Leverprice::ROOT_PUBLIC_KEYS)
    assert_predicate Leverprice::ROOT_PUBLIC_KEYS, :frozen?
    assert_equal 1, Leverprice::MIN_KEYSET_VERSION
    Leverprice::ROOT_PUBLIC_KEYS.each_value do |key|
      raw = Leverprice::Util.b64url_decode(key)

      assert_equal 32, raw.bytesize
      assert_equal "ED25519", OpenSSL::PKey.read(Leverprice::Util::ED25519_SPKI_PREFIX + raw).oid
    end
  end

  def test_quotes_of_one_request_share_one_cookie
    client = build_client(transport: FakeTransport.serving(@envelope))
    env = { "REQUEST_METHOD" => "GET", "HTTP_USER_AGENT" => CHROME }

    pro = client.get_price("pro", request: env)
    team = client.get_price(:team, request: env)

    assert_equal pro.visitor_id, team.visitor_id
    assert_equal "team", team.product_key
    state = cookie_state(team.set_cookie.first)

    assert_equal({ "exp_B" => team.variant_id, "exp_A" => pro.variant_id }, state["a"])
    assert_equal %w[exp_B exp_A], state["x"]

    returning = { "REQUEST_METHOD" => "GET", "HTTP_USER_AGENT" => CHROME,
                  "HTTP_COOKIE" => team.set_cookie.first.split(";").first }
    again = client.get_price("pro", request: returning)

    assert_equal pro.variant_id, again.variant_id
    assert_empty again.set_cookie
    assert_empty client.get_price("team", request: returning).set_cookie
  end

  def test_manual_exposure_and_log_exposure
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport)

    quote = client.get_price("pro", request: browser, exposure: :manual)

    refute_predicate quote, :exposure_logged?
    assert_empty(quote.set_cookie.select { |c| cookie_state(c)["x"].any? })
    assert client.log_exposure(quote)
    assert quote.exposure_logged
    refute client.log_exposure(quote)
    client.flush

    assert_equal(1, transport.events.count { |e| e["type"] == "exposure" })
  end

  def test_exposures_are_flushed_by_the_background_timer_and_at_one_hundred
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport, flush_interval_ms: 50)
    client.get_price("pro", request: browser)
    wait_until { transport.events.size == 1 }

    busy = build_client(transport: transport)
    100.times { |i| busy.get_price("pro", request: browser, user_id: "user_#{i}") }
    wait_until { transport.events.size == 101 }
    client.close
    busy.close
  end

  def test_requests_and_headers_sent_to_the_api
    transport = FakeTransport.serving(@envelope)
    client = build_client(transport: transport, api_url: "https://api.example.test///")
    client.get_price("pro", request: browser)
    client.flush

    config_call = transport.config_calls.first

    assert_equal "GET", config_call.http_method
    assert_equal "https://api.example.test/v1/config", config_call.url
    assert_equal "Bearer #{SECRET_KEY}", config_call.headers["Authorization"]
    assert_equal "leverprice-sdk-ruby/0.3.0", config_call.headers["User-Agent"]
    refute(transport.calls.any? { |c| c.headers.keys.any? { |k| k.casecmp?("origin") } })

    events_call = transport.event_calls.first

    assert_equal "POST", events_call.http_method
    assert_equal "application/json", events_call.headers["Content-Type"]
    assert_equal({ "name" => "leverprice-ruby", "version" => "0.3.0" }, JSON.parse(events_call.body)["sdk"])
  end

  def test_transport_failures_and_bad_bodies_fall_back
    failing = FakeTransport.new(config: ->(_call) { raise Errno::ECONNREFUSED })

    assert_equal "no_config", build_client(transport: failing).get_price("pro").reason
    assert(errors.any? { |e| e.start_with?("Leverprice: GET /v1/config failed:") })

    garbage = FakeTransport.new(config: ->(_call) { [200, {}, "<html>"] })

    assert_equal "no_config", build_client(transport: garbage).get_price("pro").reason
    assert_includes errors, "Leverprice config: response is not JSON"

    other_key = FakeTransport.serving(@signer.envelope(secret_key: "pp_sk_test_#{"z" * 40}"))

    assert_equal "no_config", build_client(transport: other_key).get_price("pro").reason
    assert_includes errors, "Leverprice config: not issued for this API key; refusing"
  end

  def test_configuration_errors_raise
    client = build_client(transport: FakeTransport.serving(@envelope))
    error = assert_raises(ArgumentError) { client.get_price("ghost") }
    assert_equal 'Leverprice: unknown product "ghost". Add it to the products option.', error.message

    invalid = [
      { "x" => { currency: "us", fallback_price: 1 } },
      { "x" => { currency: "usd", fallback_price: 0 } },
      { "x" => { currency: "usd", fallback_price: 19.5 } },
      { "x" => { currency: "usd", fallback_price: 1, min_price: 10, max_price: 5 } },
      { "x" => "usd" }
    ]

    invalid.each do |products|
      assert_raises(ArgumentError) { Leverprice::Client.new(secret_key: SECRET_KEY, products: products) }
    end
    assert_raises(ArgumentError) do
      Leverprice::Client.new(secret_key: SECRET_KEY, products: PRODUCTS, cookie_name: "bad name")
    end
    camel = Leverprice::Client.new(secret_key: nil, products: { pro: { "currency" => "EUR", "fallbackPrice" => 5 } })

    assert_equal "eur", camel.get_price(:pro).currency
  end

  def test_inspect_hides_the_secret_key
    client = build_client(transport: FakeTransport.serving(@envelope))

    refute_includes client.inspect, SECRET_KEY
  end

  def test_write_cookies_appends_to_rack_headers
    quote = Leverprice::Quote.new(set_cookie: ["__pp=a.b; Path=/", "__pp_f=1; Path=/"])
    headers = { "Set-Cookie" => "session=1\n__pp=old.sig; Path=/" }
    Leverprice.write_cookies(headers, quote)

    assert_equal "session=1\n__pp=a.b; Path=/\n__pp_f=1; Path=/", headers["Set-Cookie"]

    rack3 = { "set-cookie" => ["session=1"] }
    Leverprice.write_cookies(rack3, quote)

    assert_equal ["session=1", "__pp=a.b; Path=/", "__pp_f=1; Path=/"], rack3["set-cookie"]

    response = Struct.new(:headers).new({})

    assert_same response, Leverprice.write_cookies(response, ["__pp_f=1; Path=/"])
    assert_equal "__pp_f=1; Path=/", response.headers["Set-Cookie"]
    assert_equal({}, Leverprice.write_cookies({}, Leverprice::Quote.new(set_cookie: [])))
  end
end
