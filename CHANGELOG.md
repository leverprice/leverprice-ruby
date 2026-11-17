# Changelog

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
