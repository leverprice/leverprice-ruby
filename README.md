<p>
<a href="https://leverprice.com">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/leverprice/.github/main/assets/repo/ruby-dark.svg">
    <img alt="Leverprice SDK for Ruby" src="https://raw.githubusercontent.com/leverprice/.github/main/assets/repo/ruby-light.svg" width="100%">
  </picture>
</a>
</p>

<p>
  <a href="https://rubygems.org/gems/leverprice"><img alt="RubyGems" src="https://img.shields.io/gem/v/leverprice?label=gem&style=flat-square&labelColor=0F1011&color=3C3F44"></a>
  <a href="https://github.com/leverprice/leverprice-ruby/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/leverprice/leverprice-ruby/ci.yml?branch=main&label=ci&style=flat-square&labelColor=0F1011"></a>
  <a href="https://github.com/leverprice/leverprice-ruby/blob/main/LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-3C3F44?style=flat-square&labelColor=0F1011"></a>
</p>

Server-side SDK for [Leverprice](https://leverprice.com) price experiments. Ruby 3.1 or later, no runtime dependencies (OpenSSL, Net::HTTP and JSON from the standard library). Thread-safe and fork-safe, so it works under Puma, Unicorn, Passenger, Sidekiq and plain Rack.

**Your payments stay yours.** The SDK gives your server a number. Your own code creates the checkout with your own provider keys. Leverprice never sees card data or provider API keys.

```sh
bundle add leverprice
```

## Quick start

### Rails

```ruby
# config/initializers/leverprice.rb
LEVERPRICE = Leverprice::Client.new(
  secret_key: ENV["LEVERPRICE_SECRET_KEY"], # server-only
  products: {
    "pro" => { currency: "usd", fallback_price: 1900 }, # your current price, served whenever Leverprice cannot answer
  },
  logger: Rails.logger,
)
LEVERPRICE.preload # optional: fetch the config at boot instead of on the first request
at_exit { LEVERPRICE.close }
```

That is all the configuration your code holds. Prices, price ranges, tests, regional prices and where the visitor's country comes from are managed in Leverprice and arrive in a signed config, so new features and new settings never need a code change.

Show the price, then charge the same price at checkout. Never trust a price sent by the browser.

```ruby
class PricingController < ApplicationController
  def show
    @quote = LEVERPRICE.get_price("pro", request: request, user_id: current_user&.id)
    Leverprice.write_cookies(response, @quote)
    # @quote.price is in minor units (1900 = $19.00)
  end
end

class CheckoutsController < ApplicationController
  def create
    quote = LEVERPRICE.get_price("pro", request: request, user_id: current_user&.id)
    Leverprice.write_cookies(response, quote)
    session = Stripe::Checkout::Session.create(
      mode: "payment",
      line_items: [{
        quantity: 1,
        price_data: { currency: quote.currency, unit_amount: quote.price, product_data: { name: "Pro" } },
      }],
      metadata: quote.metadata, # signed attribution: pass it whole
      payment_intent_data: { metadata: quote.metadata },
      success_url: root_url,
      cancel_url: pricing_url,
    )
    redirect_to session.url, allow_other_host: true, status: :see_other
  end
end
```

Report the purchase from your webhook (or connect your provider's webhooks to Leverprice directly). A Checkout Session paid with a delayed method (bank debit, voucher) completes as `unpaid`; `checkout.session.async_payment_succeeded` reports its payment later, so handle both events and count only `paid` sessions:

```ruby
class StripeWebhooksController < ActionController::API
  PAID = %w[checkout.session.completed checkout.session.async_payment_succeeded].freeze

  def create
    event = Stripe::Webhook.construct_event(
      request.raw_post, request.headers["Stripe-Signature"], ENV.fetch("STRIPE_WEBHOOK_SECRET"),
    )
    checkout = event.data.object
    if PAID.include?(event.type) && paid?(checkout)
      LEVERPRICE.track_purchase(
        provider: "stripe",
        order_id: checkout.payment_intent,
        amount: checkout.amount_total - (checkout.total_details&.amount_tax || 0),
        currency: checkout.currency,
        metadata: checkout.metadata.to_h,
        timestamp: event.created, # Unix seconds are converted
      )
    end
    head :ok
  rescue JSON::ParserError, Stripe::SignatureVerificationError
    head :bad_request
  end

  private

  # $0 sessions (a trial start, a 100% discount) are not sales.
  def paid?(checkout)
    checkout.payment_status == "paid" && checkout.payment_intent && checkout.amount_total.positive?
  end
end
```

A subscription session names the PaymentIntent of its first payment from Stripe API version 2025-03-31.basil on. On an older version, report that payment from `invoice.paid` with `billing_reason` `subscription_create`: the order id is the invoice's `payment_intent` and the attribution is in `subscription_details.metadata`, so pass `subscription_data: { metadata: quote.metadata }` at checkout as well.

`Leverprice.write_cookies` appends the quote's `Set-Cookie` values correctly on Rack 2 and Rack 3. On Rack 3 (Rails 7.1+ with Rack 3, Sinatra 4) you can also write them yourself with `quote.set_cookie.each { |c| response.add_header("set-cookie", c) }`; on Rack 2, join them with `"\n"` into one `Set-Cookie` header.

### Sinatra

```ruby
require "sinatra"
require "leverprice"

LEVERPRICE = Leverprice::Client.new(
  secret_key: ENV["LEVERPRICE_SECRET_KEY"],
  products: { "pro" => { currency: "usd", fallback_price: 1900 } },
)

get "/pricing" do
  quote = LEVERPRICE.get_price("pro", request: request, user_id: session[:user_id])
  Leverprice.write_cookies(response, quote)
  erb :pricing, locals: { quote: quote }
end

post "/checkout" do
  quote = LEVERPRICE.get_price("pro", request: request, user_id: session[:user_id])
  Leverprice.write_cookies(response, quote)
  checkout = Stripe::Checkout::Session.create(
    mode: "payment",
    line_items: [{ quantity: 1, price_data: { currency: quote.currency, unit_amount: quote.price,
                                              product_data: { name: "Pro" } } }],
    metadata: quote.metadata,
    payment_intent_data: { metadata: quote.metadata },
    success_url: url("/thanks"), cancel_url: url("/pricing"),
  )
  redirect checkout.url, 303
end

post "/webhooks/stripe" do
  event = Stripe::Webhook.construct_event(request.body.read, env["HTTP_STRIPE_SIGNATURE"], ENV["STRIPE_WEBHOOK_SECRET"])
  s = event.data.object
  paid = %w[checkout.session.completed checkout.session.async_payment_succeeded].include?(event.type) &&
         s.payment_status == "paid" && s.payment_intent && s.amount_total.positive?
  if paid
    LEVERPRICE.track_purchase(provider: "stripe", order_id: s.payment_intent,
                              amount: s.amount_total - (s.total_details&.amount_tax || 0),
                              currency: s.currency, metadata: s.metadata.to_h, timestamp: event.created)
  end
  200
rescue JSON::ParserError, Stripe::SignatureVerificationError
  400
end
```

### Rack

```ruby
# config.ru
require "leverprice"

LEVERPRICE = Leverprice::Client.new(
  secret_key: ENV["LEVERPRICE_SECRET_KEY"],
  products: { "pro" => { currency: "usd", fallback_price: 1900 } },
)

run lambda { |env|
  quote = LEVERPRICE.get_price("pro", request: env)
  headers = { "content-type" => "text/plain" }
  Leverprice.write_cookies(headers, quote)
  [200, headers, ["Pro: #{format('%.2f', quote.price / 100.0)} #{quote.currency.upcase}"]]
}
```

## Guarantees

- **Fails safe.** If Leverprice is off, slow (no config within 500 ms), down, misconfigured or returns anything unexpected, `get_price` returns your `fallback_price`. It raises only for a product key missing from `products`, which is a bug in the calling code. `track_purchase`, `track_refund`, `log_exposure`, `flush`, `refresh`, `preload` and `close` never raise.
- **Verified config.** Root key, keyset and config signatures are checked in a chain. Versions only move forward (no rollback, no revoked keys) and configs expire.
- **Bounded.** Every standard and test price is checked against the product's signed price range and currency; regional prices follow from them, and every country pays between 5% and 200% of the standard price.
- **Sticky and tamper-proof.** Visitors keep their price. The assignment cookie is HMAC-signed with your project's assignment key, delivered in the signed config, so rotating your API key does not reshuffle visitors.
- **Private.** Visitor and user ids are HMAC-hashed on your server. Leverprice only sees the hash.
- **No price flips.** A visitor who got the fallback during an outage keeps it for the rest of their session.
- **Search engines see the standard price.** Crawlers and link previews are never put into experiments.
- **Never in the way.** Background threads never keep your process alive, and events are sent off the request path.

## Requests and cookies

Pass whatever request object you have: a Rack env Hash, a `Rack::Request` or `ActionDispatch::Request`, anything with `#headers`, or a plain Hash of header names (case-insensitive, Symbol keys and Array values allowed). The SDK reads the `Cookie` header, the `User-Agent` and prefetch hints. `cookie:` and `user_agent:` override what is read from the request.

`quote.set_cookie` is an Array of `Set-Cookie` header values: usually empty, one value when the assignment cookie (`__pp`) changes, or the outage pin (`__pp_f`). Write every value to your response.

Pricing several products on one page? Pass the **same request** to each `get_price` call. The quotes share one visitor cookie, and the last quote's cookie carries every assignment.

`user_id:` accepts a String or an Integer. Convert other id types (UUID objects, `BSON::ObjectId`) with `to_s`.

## Regional prices

Turn on regional prices for a product in the dashboard and a visitor from India pays $12, or ₹999 in rupees, where a visitor from the US pays $29. Your code stays as it is: in Leverprice, choose where your site runs under **Project settings → Visitor country** (Cloudflare, Vercel, AWS CloudFront, or the header your own proxy sets), and the SDK reads the visitor's country from that header.

```ruby
# Rails, Sinatra or Rack: the request (or Rack env) you already pass carries the header.
quote = LEVERPRICE.get_price("pro", request: request) # a visitor from India
quote.price     # 1200: India is set to $12 in the dashboard
quote.currency  # "usd": pass both to your checkout
quote.country   # "IN"
quote.regional? # true

# No such header? Pass the country from your own GeoIP lookup: a two-letter ISO 3166-1 code, or nil.
quote = LEVERPRICE.get_price("pro", request: request, country: lookup_country(request.ip))
```

- **The country.** Name only a header your host or CDN sets and overwrites: a header a visitor can send themselves would let them pick their own price. To decide in code instead, pass `country_header:` to `Leverprice::Client.new` (it replaces the project setting) or `country:` to `get_price` (it wins over both). Give the HTTP header name, not the Rack key: the SDK finds `HTTP_CF_IPCOUNTRY` in a Rack env by itself. `CF_IPCountry` and `CF-IPCountry` share that key, so keep header names with underscores dropped in front of the app (the nginx default).
- **Local currencies.** Regional prices in your product's currency ($12 in India instead of $29) need nothing in code. Prices in the visitor's own currency (₹999) are served only with `local_currencies: true`, which you set when your checkout charges `quote.price` in `quote.currency`; without it those visitors get the standard price, so a checkout with a fixed currency can never charge 99900 in dollars.
- **Tests.** Each visitor still gets one sticky variant, at that variant's price for their country. A test can run in selected countries only, and countries can get their own share of traffic per price: both are set in the dashboard and need nothing from your code but the visitor's country.
- **Checkout.** Always pass `quote.currency` with `quote.price`, also before you turn regional prices on: then they need no code change later. `checkout_url` is `nil` for a regional price: hosted checkout links are made for standard prices.
- Bots and visitors whose country is unknown get the standard price.

## Exposures

An exposure is one person seeing an experiment price. With `exposure: :auto` (the default) the SDK logs it the first time a visitor gets a price from an experiment, once per visitor and experiment. Prefetch and prerender requests (`Sec-Purpose`, `Purpose`, `X-Purpose`, `X-Moz`, `Next-Router-Prefetch`, and Turbo's `X-Sec-Purpose`) are priced but not counted.

If you compute the price before it is visible, use manual mode:

```ruby
quote = LEVERPRICE.get_price("pro", request: request, exposure: :manual)
# later, once the price is on screen:
LEVERPRICE.log_exposure(quote)
```

Exposures are sent in batches within 2 seconds. Purchases and refunds are sent immediately.

## Bots

Crawlers, link previewers (Slack, WhatsApp, iMessage), headless browsers, uptime monitors and command-line clients get the product's standard price (or your fallback when no config is available) with reason `"bot"`: no assignment, no cookie, no exposure. An empty user agent counts as a person. Pass `bot: true` or `bot: false` to use your own detection. The built-in check is `Leverprice.bot?(user_agent)`.

## Kill switch

Set `LEVERPRICE_DISABLED=1` (or `true`), or pass `disabled: true`. The variable is read on every call. `get_price` then returns your fallback price with reason `"disabled"`, sets no cookies, makes no network calls and logs nothing, and `track_purchase`, `track_refund` and `log_exposure` do nothing. A missing or malformed `secret_key` behaves the same way; a malformed key is reported once through `on_error`.

## Outages

When no usable config is available (reason `"no_config"`), the quote also sets `__pp_f=1` for 30 minutes. While a browser sends it, it gets the fallback price with reason `"pinned_fallback"` and is not enrolled. Each pinned request extends the pin, so the price changes only after 30 minutes of inactivity. The pin is unsigned on purpose: it can only select your own fallback price.

Failed config fetches back off exponentially up to 30 seconds. Purchases and refunds that cannot be delivered stay queued and are retried with the next flush.

## Forking servers

Create the client once at boot. With `preload_app!` (Puma) or `preload_app true` (Unicorn), calling `preload` at boot means every worker starts with a verified config. The SDK detects forks and gives each worker its own threads, locks and event queue; a worker never re-sends events queued in the parent. Call `close` at shutdown (`at_exit`, or Puma's `on_worker_shutdown`) to send pending exposures.

## Trust chain and updates

The SDK embeds only Leverprice's offline root public keys (`Leverprice::ROOT_PUBLIC_KEYS`). Each config carries a keyset of online signing keys, signed by a root key, and must itself be signed by one of those keys. Keyset versions only move forward within a process, so a revoked key cannot come back with an older keyset and a config it signed stops being trusted. `Leverprice::MIN_KEYSET_VERSION` sets the floor for fresh processes. Config versions only move forward and configs expire. For local development pass `trusted_root_keys: { "r1" => "<your dev root public key>" }`.

The config is revalidated every 30 seconds with an ETag, driven by traffic. When any Leverprice response announces a newer version in `Leverprice-Config-Version`, the SDK fetches it right away.

## Reference

`get_price(product_key, request:, cookie:, user_agent:, user_id:, exposure:, bot:, country:)` returns a `Leverprice::Quote`.

| Quote | |
|---|---|
| `product_key` | The key you asked for |
| `price` | Minor units; use it for display and as the checkout amount |
| `currency` | Lowercase ISO 4217: your product's currency, or the region's for a regional price |
| `country` | The visitor's country (ISO 3166-1 alpha-2) when known, else `nil` |
| `regional`, `regional?` | `true` when `price` is the regional price of `country` |
| `is_fallback`, `fallback?` | `true` when `price` is your `fallback_price` |
| `reason` | See below |
| `experiment_id`, `variant_id` | Set when `reason` is `"experiment"`, else `nil` |
| `visitor_id` | Hashed visitor id Leverprice sees; `nil` unless `reason` is `"experiment"` |
| `metadata` | `{ "pp_exp", "pp_var", "pp_vid", "pp_sig" }` for the checkout (signed); `{}` otherwise |
| `set_cookie` | `Set-Cookie` values to write (zero or more) |
| `checkout_url` | Hosted checkout link for this price, or `nil` (always `nil` for a regional price) |
| `exposure_logged`, `exposure_logged?` | An exposure for this visitor and experiment has been logged |

| `reason` | Price |
|---|---|
| `experiment` | The visitor's sticky variant |
| `base_price` | The product's price for this visitor (no experiment runs for them) |
| `bot` | Standard price, or fallback if unavailable; never enrolled |
| `disabled` | Fallback: kill switch, or no valid secret key |
| `no_config` | Fallback: no usable signed config (timeout, outage, rejected or expired); sets the pin |
| `pinned_fallback` | Fallback: this browser got a fallback during an outage in this session |
| `unknown_product` | Fallback: the config has no such product |
| `currency_mismatch` | Fallback: the config's currency differs from your guard |
| `out_of_bounds` | Fallback: a price is outside the product's signed range |

| Method | |
|---|---|
| `log_exposure(quote)` | Logs a manual-mode exposure; returns `true` if one was queued |
| `track_purchase(provider:, order_id:, amount:, currency:, metadata: nil, timestamp: nil)` | Reads `pp_exp`, `pp_var`, `pp_vid` and `pp_sig` from `metadata`. Providers: `stripe`, `polar`, `lemonsqueezy`, `dodo`, `paddle`, `creem`, `other` |
| `track_refund(provider:, order_id:, currency:, refund_id:, amount:)` or `(…, refunded_total:)` | One refund, or the order's cumulative refunded total |
| `flush` | Sends queued events now (up to 500 per request, retried; purchases and refunds are kept on failure) |
| `refresh` / `preload` | Fetch the config now / only if none is usable |
| `close` | Flushes and stops the background flush thread |
| `Leverprice.write_cookies(response, quote)` | Writes `quote.set_cookie` to a Rails, Sinatra or Rack response, or a headers Hash |
| `Leverprice.bot?(user_agent)` | The built-in bot check |

| Option | Default | |
|---|---|---|
| `secret_key` | | `pp_sk_live_…` or `pp_sk_test_…` |
| `products` | | Product key to `{ currency:, fallback_price: }`. `min_price:` and `max_price:` are deprecated and ignored since 0.4: the price range is set in Leverprice |
| `disabled` | `false` | Kill switch |
| `api_url` | `https://api.leverprice.com` | |
| `timeout_ms` | `500` | Longest a request waits for a config when none is usable |
| `refresh_interval_ms` | `30000` | Config revalidation period |
| `max_stale_ms` | `86400000` | Stop using a config this long after the server last confirmed it |
| `cookie_name` | `"__pp"` | The outage pin is `<cookie_name>_f` |
| `cookie_max_age_seconds` | `15552000` | 180 days |
| `cookie_secure` | `true` | Set `false` only for plain-HTTP development |
| `cookie_domain` | `nil` | |
| `country_header` | `nil` | Request header your CDN or host sets to the visitor's country, such as `cf-ipcountry`. Overrides the project's country setting in Leverprice. Name only a header visitors cannot set |
| `local_currencies` | `false` | Serve regional prices in the visitor's currency, not only in each product's own. Set it only when your checkout charges `quote.price` in `quote.currency` |
| `flush_interval_ms` | `2000` | Longest exposures wait before being sent |
| `trusted_root_keys` | `ROOT_PUBLIC_KEYS` | For staging and local development |
| `on_error` | `nil` | Callable that receives every SDK error (`Leverprice::Error`) |
| `logger` | `nil` | Used for warnings when `on_error` is not set (default: `Kernel#warn`) |
| `transport` | Net::HTTP | Object with `call(method:, url:, headers:, body:, timeout:)` returning a `Leverprice::Response` or `[status, headers, body]` |

In tests, pass `disabled: true`, or a `transport` that returns canned responses.

**Upgrading from 0.3:** no code changes. `min_price` and `max_price` in your code are no longer used: the product's range set in Leverprice applies, and you can delete them whenever you like. If the limits in your code were tighter than that range, tighten the range in Leverprice before you upgrade. Regional prices need no code: turn them on in the dashboard and set **Project settings → Visitor country**. Add `local_currencies: true` if your checkout passes `quote.currency` and you want prices in visitors' own currencies.

## License

MIT
