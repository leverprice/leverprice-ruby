# frozen_string_literal: true

require_relative "test_helper"

class ConformanceTest < Minitest::Test
  V = Vectors.data

  DEFAULT_GUARDS = {
    "pro" => { "currency" => "usd", "fallbackPrice" => 1900 },
    "basic" => { "currency" => "usd", "fallbackPrice" => 1000 },
    "euro" => { "currency" => "eur", "fallbackPrice" => 1200 },
    "wild" => { "currency" => "usd", "fallbackPrice" => 2000 },
    "bad" => { "currency" => "usd", "fallbackPrice" => 150 },
    "ghost" => { "currency" => "usd", "fallbackPrice" => 4900 },
    "geo" => { "currency" => "usd", "fallbackPrice" => 2900 },
    "geox" => { "currency" => "usd", "fallbackPrice" => 2900 },
    "badgeo" => { "currency" => "usd", "fallbackPrice" => 2900 },
    "badgeox" => { "currency" => "usd", "fallbackPrice" => 2900 }
  }.freeze

  QUOTE_FIELDS = {
    "price" => :price, "currency" => :currency, "country" => :country, "regional" => :regional,
    "isFallback" => :is_fallback, "reason" => :reason, "experimentId" => :experiment_id,
    "variantId" => :variant_id, "visitorId" => :visitor_id, "metadata" => :metadata,
    "checkoutUrl" => :checkout_url, "exposureLogged" => :exposure_logged, "setCookie" => :set_cookie
  }.freeze

  MALFORMED_PRODUCTS_RE = /\ALeverprice config v\d+: ignored malformed products/

  def assignment_key
    Leverprice::Util.b64url_decode(V["assignmentKey"])
  end

  def state_from(vector)
    Leverprice::Cookie::State.new(vector["v"], vector["a"].to_h, vector["x"].dup)
  end

  def state_to_vector(state)
    { "v" => state.v, "a" => state.a.to_a, "x" => state.x }
  end

  def test_key_fingerprints
    V["keyFingerprints"].each do |vector|
      assert_equal vector["fingerprint"], OpenSSL::Digest::SHA256.hexdigest(vector["secretKey"])[0, 16]
    end
  end

  def test_trust_chain
    V["trust"].each do |test_case|
      trust = Leverprice::TrustChain.new(V["rootKeys"], test_case.fetch("minKeysetVersion", 1))
      acceptance = Leverprice::Acceptance.new(trust, V["secretKey"])
      test_case["steps"].each_with_index do |step, index|
        label = "#{test_case["name"]} (step #{index + 1})"
        result =
          begin
            acceptance.accept(step["envelope"], step.fetch("now", V["now"]))
          rescue Leverprice::Error => e
            e
          end
        if step["expect"] == "accept"
          refute_kind_of Leverprice::Error, result, "#{label}: #{result.inspect}"
          assert_equal step["version"], result.config.version, label
          assert_equal step["dropped"], result.dropped, label
        else
          assert_kind_of Leverprice::Error, result, label
        end
      end
    end
  end

  def test_visitor_ids
    V["visitorIds"].each do |vector|
      assert_equal "pp:visitor:v1:#{vector["visitorKey"]}", vector["message"]
      assert_equal vector["visitorId"], Leverprice::Util.hmac_hex(assignment_key, vector["message"], 32)
    end
  end

  def test_attribution
    V["attribution"].each do |vector|
      message = "pp:attr:v1:#{vector["experimentId"]}:#{vector["variantId"]}:#{vector["visitorId"]}"

      assert_equal vector["message"], message
      assert_equal vector["signature"], Leverprice::Util.hmac_hex(assignment_key, message, 16)
    end
  end

  def test_buckets
    V["buckets"].each do |vector|
      assert_equal vector["bucket"], Leverprice::Util.bucket_for(vector["salt"], vector["visitorId"]), vector.inspect
    end
  end

  def test_pick_variant
    V["pickVariant"].each do |vector|
      variants = vector["weights"].each_with_index.map { |w, i| Leverprice::Wire::Variant.new(id: "v#{i}", weight: w) }

      assert_equal "v#{vector["index"]}", Leverprice::Util.pick_variant(variants, vector["bucket"]).id, vector.inspect
    end
  end

  def test_cookie_sign
    V["cookies"]["sign"].each do |vector|
      state = state_from(vector["state"])

      assert_equal vector["json"], Leverprice::Cookie.serialize(state)
      assert_equal vector["cookie"], Leverprice::Cookie.sign(assignment_key, state)
    end
  end

  def test_cookie_verify
    V["cookies"]["verify"].each do |vector|
      state = Leverprice::Cookie.verify(assignment_key, vector["cookie"])
      if vector["state"].nil?
        assert_nil state, vector["name"]
      else
        assert_equal vector["state"], state_to_vector(state), vector["name"]
      end
    end
  end

  def test_cookie_ops
    V["cookies"]["ops"].each do |vector|
      state = state_from(vector["state"])
      op = vector["op"]
      if op.key?("assign")
        Leverprice::Cookie.assign(state, *op["assign"])
      else
        assert_equal vector["changed"], Leverprice::Cookie.mark_exposed(state, op["markExposed"]), vector["name"]
      end

      assert_equal vector["result"], state_to_vector(state), vector["name"]
    end
  end

  def test_cookie_header
    V["cookieHeader"].each do |vector|
      assert_equal vector["values"], Leverprice::Request.cookie_values(vector["header"], vector["name"]), vector.inspect
    end
  end

  def test_prefetch
    V["prefetch"].each do |vector|
      assert_equal vector["prefetch"], Leverprice::Request.prefetch?(vector["headers"]), vector.inspect
    end
  end

  def test_set_cookie
    V["setCookie"].each do |vector|
      header = Leverprice::Cookie.header(vector["name"], vector["value"], vector["maxAge"],
                                         secure: vector["secure"], domain: vector["domain"])

      assert_equal vector["header"], header
    end
  end

  def test_countries
    V["countries"].each do |vector|
      country = Leverprice::Request.normalize_country(vector["value"])
      if vector["country"].nil?
        assert_nil country, vector.inspect
      else
        assert_equal vector["country"], country, vector.inspect
      end
    end
  end

  def test_bots
    V["bots"].each do |vector|
      assert_equal vector["bot"], Leverprice.bot?(vector["userAgent"]), vector["userAgent"]
      assert_equal vector["bot"], Leverprice::Bots.bot?(vector["userAgent"]), vector["userAgent"]
    end
  end

  def test_events
    V["events"].each do |vector|
      problem = Leverprice::Wire.event_problem(vector["event"])

      assert_equal vector["valid"], problem.nil?, "#{vector["event"].inspect}: #{problem.inspect}"
    end
  end

  def test_quotes
    V["quotes"].each do |test_case|
      errors = []
      transport = FakeTransport.serving(V["config"], etag: '"v5"')
      guards = DEFAULT_GUARDS.merge(test_case.fetch("guards", {}))
      client = Leverprice::Client.new(
        secret_key: V["secretKey"],
        products: guards,
        trusted_root_keys: V["rootKeys"],
        country_header: test_case["countryHeader"],
        local_currencies: test_case.fetch("localCurrencies", false),
        transport: transport,
        clock: -> { V["now"] },
        on_error: ->(e) { errors << e.message }
      )
      context = { request: test_case["headers"], user_id: test_case["userId"], exposure: test_case["exposure"],
                  bot: test_case["bot"] }
      context[:country] = test_case["country"] if test_case.key?("country")
      quote = client.get_price(test_case["productKey"], **context)
      client.flush
      name = test_case["name"]
      expected = test_case["expect"]

      assert_equal QUOTE_FIELDS.keys.sort, (expected.keys - ["exposures"]).sort, "#{name}: expected quote fields"
      assert_equal test_case["productKey"], quote.product_key, name
      QUOTE_FIELDS.each do |field, reader|
        value = quote.public_send(reader)
        if expected[field].nil?
          assert_nil value, "#{name}: #{field}"
        else
          assert_equal expected[field], value, "#{name}: #{field}"
        end
      end

      assert_equal expected["exposures"], transport.events.map { |e| e.except("timestamp") }, "#{name}: exposures"
      assert_equal test_case["errors"], errors.grep_v(MALFORMED_PRODUCTS_RE), "#{name}: errors"
      client.close
    end
  end
end
