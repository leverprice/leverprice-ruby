# frozen_string_literal: true

require_relative "test_helper"

class RequestTest < Minitest::Test
  include TestHelpers

  V = Vectors.data
  RETURNING = "__pp=eyJ2IjoiMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYiLCJhIjp7ImV4cF9BIjoidmFyXzMifSwieCI6WyJleHBf" \
              "QSJdfQ.wlG8g6VEGHFiJU1qrpwGbA"
  GOOGLEBOT = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

  RackRequest = Struct.new(:env)
  HeadersOnly = Struct.new(:headers)

  class HeaderLookup
    def initialize(headers)
      @headers = headers.transform_keys(&:downcase)
    end

    def [](name)
      @headers[name.downcase]
    end
  end

  def client
    @client ||= Leverprice::Client.new(
      secret_key: V["secretKey"],
      products: { "pro" => { currency: "usd", fallback_price: 1900 } },
      trusted_root_keys: V["rootKeys"],
      transport: FakeTransport.serving(V["config"]),
      clock: -> { V["now"] },
      on_error: ->(e) { errors << e.message }
    )
  end

  def regional_client
    @regional_client ||= Leverprice::Client.new(
      secret_key: V["secretKey"],
      products: { "geo" => { currency: "usd", fallback_price: 2900 } },
      country_header: " CF-IPCountry ",
      local_currencies: true,
      trusted_root_keys: V["rootKeys"],
      transport: FakeTransport.serving(V["config"]),
      clock: -> { V["now"] },
      on_error: ->(e) { errors << e.message }
    )
  end

  def assert_returning_visitor(request, **context)
    quote = client.get_price("pro", request: request, **context)

    assert_equal "experiment", quote.reason, request.inspect
    assert_equal "var_3", quote.variant_id, request.inspect
    assert_empty quote.set_cookie, request.inspect
  end

  def test_rack_env_hash
    assert_returning_visitor({ "REQUEST_METHOD" => "GET", "HTTP_COOKIE" => RETURNING, "HTTP_USER_AGENT" => CHROME })
  end

  def test_object_with_env
    assert_returning_visitor(RackRequest.new({ "HTTP_COOKIE" => "a=1; #{RETURNING}", "HTTP_USER_AGENT" => CHROME }))
  end

  def test_object_with_headers_hash
    assert_returning_visitor(HeadersOnly.new({ "Cookie" => RETURNING, "User-Agent" => CHROME }))
  end

  def test_object_with_header_lookup
    assert_returning_visitor(HeaderLookup.new("Cookie" => RETURNING, "User-Agent" => CHROME))
  end

  def test_plain_hash_with_mixed_case_symbols_and_arrays
    assert_returning_visitor({ "COOKIE" => RETURNING, "User-Agent" => CHROME })
    assert_returning_visitor({ cookie: RETURNING, user_agent: CHROME })
    assert_returning_visitor({ "cookie" => ["a=1", RETURNING], "user-agent" => [CHROME] })
  end

  def test_explicit_cookie_and_user_agent_win
    assert_returning_visitor({ "cookie" => "__pp=forged.AAAAAAAAAAAAAAAAAAAAAA" }, cookie: RETURNING,
                                                                                   user_agent: CHROME)
    assert_returning_visitor(nil, cookie: RETURNING.delete_prefix("__pp="), user_agent: CHROME)
    assert_equal "bot", client.get_price("pro", request: { "cookie" => RETURNING }, user_agent: GOOGLEBOT).reason
  end

  def test_rack_env_prefetch_is_priced_but_not_counted
    env = { "REQUEST_METHOD" => "GET", "HTTP_USER_AGENT" => CHROME, "HTTP_SEC_PURPOSE" => "prefetch;prerender" }
    quote = client.get_price("pro", request: env)

    assert_equal "experiment", quote.reason
    refute quote.exposure_logged
    assert Leverprice::Request.prefetch?(RackRequest.new({ "HTTP_NEXT_ROUTER_PREFETCH" => "1" }))
    refute Leverprice::Request.prefetch?({ "REQUEST_METHOD" => "GET" })
  end

  def test_turbo_hover_prefetch_is_priced_but_not_counted
    env = { "REQUEST_METHOD" => "GET", "HTTP_USER_AGENT" => CHROME, "HTTP_X_SEC_PURPOSE" => "prefetch" }
    quote = client.get_price("pro", request: env)

    assert_equal "experiment", quote.reason
    refute quote.exposure_logged
    assert Leverprice::Request.prefetch?(RackRequest.new(env))
  end

  def test_binary_and_invalid_header_bytes_do_not_raise
    env = { "REQUEST_METHOD" => "GET", "HTTP_COOKIE" => "__pp=\xFF\xFE; x=%FF".b, "HTTP_USER_AGENT" => "\xC3(".b }
    quote = client.get_price("pro", request: env)

    assert_equal "experiment", quote.reason
    refute_empty quote.set_cookie
    assert_empty errors.grep_v(/ignored malformed products/)
  end

  def test_frozen_and_scalar_requests_are_priced_without_sharing
    assert_equal "experiment", client.get_price("pro", request: { "user-agent" => CHROME }.freeze).reason
    assert_equal "experiment", client.get_price("pro", request: "not a request").reason
  end

  def test_country_header_is_read_from_every_request_shape
    requests = [
      { "REQUEST_METHOD" => "GET", "HTTP_USER_AGENT" => CHROME, "HTTP_CF_IPCOUNTRY" => "IN" },
      RackRequest.new({ "HTTP_USER_AGENT" => CHROME, "HTTP_CF_IPCOUNTRY" => "in" }),
      HeadersOnly.new({ "User-Agent" => CHROME, "CF-IPCountry" => "IN" }),
      HeaderLookup.new("User-Agent" => CHROME, "CF-IPCountry" => " IN "),
      { user_agent: CHROME, cf_ipcountry: "IN" },
      { "user-agent" => [CHROME], "cf-ipcountry" => ["IN"] }
    ]

    requests.each do |request|
      quote = regional_client.get_price("geo", request: request)

      assert_equal ["IN", "inr", 99_900, true], quote.to_h.values_at(:country, :currency, :price, :regional),
                   request.inspect
      assert_nil quote.checkout_url, request.inspect
    end
    assert_empty errors.grep_v(/ignored malformed products/)
  end

  def test_country_passed_in_wins_over_the_header
    env = { "REQUEST_METHOD" => "GET", "HTTP_USER_AGENT" => CHROME, "HTTP_CF_IPCOUNTRY" => "IN" }
    quote = regional_client.get_price("geo", request: env, country: :mx)

    assert_equal ["MX", "usd", 2000, true], quote.to_h.values_at(:country, :currency, :price, :regional)
    assert_nil regional_client.get_price("geo", request: env, country: "Mexico").country
    assert_equal "IN", regional_client.get_price("geo", request: env, country: nil).country
  end

  def test_unusable_countries_get_the_standard_price_and_never_raise
    [42, ["IN"], "\xFF\xFE".b, "", "T1"].each do |country|
      quote = regional_client.get_price("geo", request: { "user-agent" => CHROME }, country: country)

      assert_equal [nil, "usd", 2900, false], quote.to_h.values_at(:country, :currency, :price, :regional),
                   country.inspect
    end
    env = { "REQUEST_METHOD" => "GET", "HTTP_USER_AGENT" => CHROME, "HTTP_CF_IPCOUNTRY" => "\xC3(".b }

    assert_nil regional_client.get_price("geo", request: env).country
    assert_empty errors.grep_v(/ignored malformed products/)
  end
end
