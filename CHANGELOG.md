# Changelog

## 0.4.0 (2026-11-18)

- Settings live in Leverprice, not in code: the product's price range and the header that carries the visitor's
  country (Project settings → Visitor country) arrive in the signed config. `min_price` and `max_price` in code are
  no longer used; 0.3 code that sets them keeps running.
- Upgrading: limits set in code (`min_price`, `max_price`) no longer hold prices. If they were tighter than the
  product's range in Leverprice, tighten the range in the dashboard before you upgrade.
- Regional prices: a product can cost something else in each country, in your currency or the visitor's. `country:`
  in `get_price`, `country` / `regional` (`regional?`) on the quote, and a `country_header:` option that overrides
  the project setting. Prices in the visitor's currency need `local_currencies: true` (set it when your checkout
  charges `quote.currency`); `quote.currency` is then the region's currency.
- Exposures carry the visitor's country when it is known.
- Tests by country: a test can run in selected countries only, and countries can be split between the prices their
  own way. Both are set in the dashboard; the SDK only needs the visitor's country.
- Cookies and the wire protocol are compatible with 0.3.
- Turbo 8 hover prefetches (`X-Sec-Purpose: prefetch`) are priced but no longer counted as exposures, like other
  prefetches. In a Rails app, hovering over a link to the pricing page counted as a view.
- README: the Stripe webhooks count only paid Checkout Sessions, handle `checkout.session.async_payment_succeeded`,
  report a subscription's first payment by its PaymentIntent id (as verified webhooks do), skip $0 sessions and
  answer a bad signature with 400.
- `track_purchase` and `track_refund` accept the providers `paddle` and `creem`.

## 0.3.0 (2026-11-17)

First release of the Ruby SDK, implementing protocol v2 of the Leverprice server SDK.

- `Leverprice::Client` with `get_price`, `log_exposure`, `track_purchase`, `track_refund`, `flush`, `refresh`,
  `preload` and `close`.
- Configs verified through the root, keyset and config signature chain (Ed25519 via OpenSSL), with key revocation,
  rollback protection and expiry.
- Signed, sticky assignment cookie shared by every quote of one request, and an outage pin cookie.
- Automatic or manual exposure logging with prefetch detection, and `Leverprice.bot?`.
- Batched event delivery with retries and a background flush thread. Thread-safe and fork-safe (Puma, Unicorn,
  Passenger).
- Reads Rack envs, Rack and ActionDispatch requests, header objects and plain Hashes. `Leverprice.write_cookies` for
  Rack 2 and Rack 3 responses.
- Kill switch through `disabled: true` or `LEVERPRICE_DISABLED`.
- No runtime dependencies.
