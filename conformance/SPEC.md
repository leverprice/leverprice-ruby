# Leverprice server SDK specification (protocol v2)

Every Leverprice SDK, in every language, behaves exactly as described here. The reference
implementation is the JavaScript SDK (`packages/sdk/src`, published as `@leverprice/sdk`); when this
document and the reference disagree, the reference wins and this document gets fixed.

`sdks/conformance/vectors.json` is generated from the server's own code
(`packages/core/test/sdk-conformance.test.ts`). Every SDK must pass every vector. Section 12 says how
to use each part of the file.

## 1. Principles

1. **Server only.** The SDK runs on the merchant's server with a secret key. It never runs in a
   browser and never sends an `Origin` header (the edge refuses requests that carry one).
2. **Fails safe.** If Leverprice is off, slow, down, misconfigured or returns anything unexpected,
   `getPrice` returns the merchant's own `fallbackPrice`. Leverprice problems never raise an
   exception into merchant code. The only exception `getPrice` may raise is for a product key the
   merchant did not configure (a bug in their code). `trackPurchase`, `trackRefund`, `logExposure`,
   `flush`, `refresh`, `preload` never raise.
3. **Verified and bounded.** Prices come only from a config signed through the root → keyset →
   config chain, and every standard and test price is checked against the product's signed price
   range and the merchant's currency.
4. **Private.** Raw visitor and user ids never leave the merchant's server; only HMACs do.
5. **No price flips.** A visitor keeps their variant (signed cookie). A browser that got the
   fallback during an outage keeps it for the rest of its session (pin cookie).
6. **Zero or near-zero dependencies.** Use the standard library. Where the standard library lacks
   Ed25519, use the platform's native crypto first and fall back to a pure implementation
   (see section 13).
7. **Configured in Leverprice, not in code.** Everything that can change after the integration
   (prices, ranges, tests, regional prices, where the visitor's country comes from) arrives in the
   signed config. The merchant's code names only the secret key, each product's currency and
   fallback price, and whether its checkout can charge other currencies (`localCurrencies`), so new
   features never need a code change: an SDK that does not know a config
   field ignores it and keeps serving the prices it understands.

## 2. Public API

Names follow each language's conventions (camelCase in JS/Go fields, snake_case in Python/Ruby/PHP
array keys where idiomatic). The concepts and defaults are identical everywhere.

### Options (constructor)

| Option | Default | Meaning |
|---|---|---|
| `secretKey` | — | `pp_sk_live_…` / `pp_sk_test_…`. Missing or malformed → the SDK is off (fallback prices, reason `disabled`, no network). A non-empty malformed key is reported once through `onError` at construction (unless disabled). Trim whitespace first. |
| `products` | — | Map productKey → guard `{ currency, fallbackPrice }`. Validated at construction (raise on invalid: this is merchant code). `currency` = 3 letters (stored lowercase). `fallbackPrice` = positive integer. The price range comes only from the signed config. `minPrice` and `maxPrice`, hard limits in 0.3, are still accepted so code written for 0.3 keeps compiling and running, but they are never validated and never used (typed SDKs keep them as deprecated fields). |
| `disabled` | false | Kill switch (see section 9). |
| `apiUrl` | `https://api.leverprice.com` | Trailing slashes stripped. |
| `timeoutMs` | 500 | Max time a request waits for a config when none is usable, counted from that request (section 5). |
| `refreshIntervalMs` | 30000 | Revalidate the config this often (driven by traffic or a background worker). |
| `maxStaleMs` | 86400000 | Stop using a config this long after the server last confirmed it. |
| `cookieName` | `__pp` | Must match `^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$` (raise otherwise). The pin cookie is `<cookieName>_f`. |
| `cookieMaxAgeSeconds` | 15552000 (180 days) | Assignment cookie lifetime. |
| `cookieSecure` | true | `Secure` attribute. |
| `cookieDomain` | none | `Domain` attribute. |
| `countryHeader` | none | Name of the request header that carries the visitor's country (set by the merchant's CDN or host: `cf-ipcountry`, `x-vercel-ip-country`, `cloudfront-viewer-country`…). Usually left out: the project's setting arrives in the config (`countryHeader`, section 4) and this option only overrides it. ASCII whitespace stripped from both ends; empty = none; must match the same token pattern as `cookieName` (raise otherwise) and is lowercased only after that check, so case mapping never sees anything but ASCII. There is no built-in default on purpose: a header the visitor can send themselves would let them choose their price. A header every browser sends itself (`visitorSetHeader`, section 7) is **ignored** as if the option were not set, and reported once through `onError` at construction (unless disabled): `Leverprice: countryHeader "<name>" is sent by visitors' browsers, so it would let them pick their own price; it is ignored. Name the header your CDN or host sets, such as cf-ipcountry.` (since 0.4.1). |
| `localCurrencies` | false | Also serve regional prices whose currency differs from the product's `currency`. Without it, only regional prices in the product's own currency are served and other countries get the standard price, so a checkout that ignores `quote.currency` can never charge an amount in the wrong currency. Set it only when the checkout charges `quote.price` in `quote.currency`. JS: anything but `true` is false; other languages: a boolean. |
| `flushIntervalMs` | 2000 | How long exposures may wait before being sent. |
| `trustedRootKeys` | `ROOT_PUBLIC_KEYS` | Root public keys by id (raw Ed25519, base64url). For staging and tests. |
| HTTP client override | platform default | `fetch` in JS; an injectable transport in other languages (needed for tests). |
| `onError` | log a warning | Receives every SDK error. A throwing `onError` must not break anything. |

Production root keys (embed exactly this map; the release test checks it):

```
ROOT_PUBLIC_KEYS = { "r1": "5FmNzXvPMPZEuDnFT_fFd_VVNsUrWwWTKLerMWbSdcg" }
MIN_KEYSET_VERSION = 1
```

### Methods

| Method | |
|---|---|
| `getPrice(productKey, context)` → `Quote` | context: `request`, `cookie`, `userAgent`, `userId`, `exposure` (`"auto"` default / `"manual"`), `bot` (bool, optional), `country` (string, optional). |
| `logExposure(quote)` → bool | For manual mode: logs the exposure when the price is really on screen. Returns true if an exposure was queued. Sets `quote.exposureLogged = true`. |
| `trackPurchase({ provider, orderId, amount, currency, metadata, timestamp? })` | Queues and flushes immediately. |
| `trackRefund({ provider, orderId, currency, timestamp?, refundId + amount \| refundedTotal })` | Queues and flushes immediately. |
| `flush()` | Sends queued events now. Waits until done. |
| `refresh()` | Fetches the config now (forced, waits). |
| `preload()` | Fetches the config only if none is usable (waits); a failed preload must not delay the first request's own attempt (reset the backoff). |
| `isBot(userAgent)` | Exported helper. |

Async languages (JS) return promises. Sync languages are sync and may use background threads;
offer async variants where the ecosystem expects them (Python `asyncio`).

### Quote

| Field | |
|---|---|
| `productKey` | as asked |
| `price` | integer minor units |
| `currency` | lowercase: the merchant's guard currency, or the region's currency when `regional` is true |
| `country` | the country whose price applies (uppercase ISO 3166-1 alpha-2) when known and the reason is `experiment` or `base_price`: the visitor's, or a dearer country the VPN guard holds (section 8); otherwise null |
| `regional` | `price` is the regional price of `country` (section 8) |
| `isFallback` | `price` is the guard's `fallbackPrice` |
| `reason` | see the table below |
| `experimentId`, `variantId`, `visitorId` | set only when reason is `experiment`, else null |
| `metadata` | `{ pp_exp, pp_var, pp_vid, pp_sig }` when reason is `experiment`, else empty map |
| `setCookie` | list of `Set-Cookie` header values (zero or more) |
| `checkoutUrl` | variant's `checkoutUrl`, else product's, else null (also on `base_price` / `bot` quotes: the product's). Always null when `regional` is true: hosted links are made for the standard prices |
| `exposureLogged` | an exposure for this visitor and experiment has been logged (now or earlier) |

| reason | price | isFallback |
|---|---|---|
| `experiment` | the visitor's variant | false |
| `base_price` | the product's price for this visitor, standard or regional (no experiment, or the visitor is outside its scope) | false |
| `bot` | standard price if a usable config has the product within bounds, else fallback | depends |
| `disabled` | fallback | true |
| `no_config` | fallback; `setCookie` = [pin] | true |
| `pinned_fallback` | fallback; `setCookie` = [pin] (renewed) | true |
| `unknown_product` | fallback | true |
| `currency_mismatch` | fallback | true |
| `out_of_bounds` | fallback | true |

Provide framework helpers where they are cheap and idiomatic (for example writing `setCookie` to a
response object), but the core API must work with nothing but a header map.

## 3. HTTP

Base: `apiUrl`. Every request carries:

```
Authorization: Bearer <secretKey>
User-Agent: leverprice-sdk-<lang>/<SDK_VERSION>        (lang: js, python, php, ruby, go)
```

Never send `Origin`. Each request has a hard timeout of 10 s (`REQUEST_TIMEOUT_MS`).

### GET /v1/config

* Request header `If-None-Match: <etag>` only when the SDK holds an ETag **and** its config is still
  usable, and the fetch is not a catch-up fetch (section 5).
* Request header `Leverprice-Products` on **every** config request (since 0.4.1), so the dashboard
  can tell whether visitors get real prices: one `key=currency` entry per configured product, the
  key percent-encoded (every UTF-8 byte outside `A–Z a–z 0–9 - . _ ~` as `%XX`, uppercase hex), the
  currency lowercase, entries sorted by encoded key (byte order), the first 50, joined with `", "`.
  No products: an empty value. Build it once at construction (vectors: `productsHeader`).
* Request header `Leverprice-Config-Error: <code>` while the last `200` response was refused
  (since 0.4.1): the code of that refusal (section 4). Cleared once a config is accepted; an HTTP
  error, a timeout or a `304` neither sets nor clears it.
* `200`: body is a `SignedConfig` JSON envelope. Accept it (section 4), then store `ETag` and set
  `fetchedAt = now`.
* `304` (only when `If-None-Match` was sent): set `fetchedAt = now`.
* Anything else, a network error, a timeout, a body that is not JSON, or an envelope that fails
  acceptance: a failure. Report `Leverprice config: HTTP <status>[ (<error.code>)]` (error code read
  from a JSON body `{"error":{"code":"…"}}` when present) or the acceptance error.
* On success (`200` accepted or `304`): `failures = 0`, `retryAt = 0`, then read the
  `Leverprice-Config-Version` header (section 5).
* On failure: `failures += 1`, `retryAt = now + min(30000, 500 * 2^failures)` ms.

### POST /v1/events

Body (JSON):

```json
{ "events": [ … ≤ 500 … ], "sdk": { "name": "leverprice-<lang>", "version": "<SDK_VERSION>" } }
```

(The JS SDK sends `"name": "@leverprice/sdk"`.) `Content-Type: application/json`.
Responses: `2xx` delivered. `4xx` other than `408` and `429`: permanent, report
`Leverprice events rejected: HTTP <status> <first 300 chars of body>` and treat the batch as
delivered (retrying cannot help). `5xx`, `408`, `429`, network errors and timeouts: retry. Every
response's `Leverprice-Config-Version` header is read (section 5).

## 4. Trust chain and config acceptance

Encodings: base64url without padding (`A–Z a–z 0–9 - _`; reject any other character when decoding).
All JSON payloads are UTF-8.

```
SignedConfig  = { payload, signature, keyId, keyset: SignedKeyset }   payload = b64url(JSON(ConfigPayload))
SignedKeyset  = { payload, signature, rootKeyId }                     payload = b64url(JSON(Keyset))
```

Signatures are Ed25519 over the UTF-8 bytes of the **base64url `payload` string itself** (not the
decoded JSON). Public keys are raw 32-byte Ed25519 keys, base64url. Any malformed key or signature
means "not verified", never a crash.

The trust chain keeps two pieces of state for the life of the client: `newest` (the highest-version
keyset verified so far) and a small cache of root-verified keyset payloads (at most 8 entries; clear
when full) so an unchanged keyset costs no signature check.

`verify(envelope, now)`:

1. `envelope` must be an object (not an array) with string `payload`, `signature`, `keyId`.
2. **Keyset.** `envelope.keyset` must be an object with string `payload`, `signature`, `rootKeyId`.
   If its payload is in the cache, use the cached keyset. Otherwise: look up `rootKeyId` in the
   trusted root keys (own keys only, never inherited/prototype members); unknown → reject. If the
   root key equals the placeholder `REPLACE_WITH_ROOT_PUBLIC_KEY` → reject with a message telling
   the developer to pass `trustedRootKeys`. Verify the root signature over the keyset payload.
   Decode: must be JSON object with `schema === 1`, integer `version`, array `keys`; keep only keys
   that are objects with string `id` and string `publicKey`; `expiresAt` is a number or null
   (anything non-numeric counts as null); `issuedAt` number or 0. Cache it.
3. Keyset checks: if `expiresAt` is a number and `now >= expiresAt` → reject. If
   `version < MIN_KEYSET_VERSION` → reject. If `newest` exists and `version < newest.version` →
   reject (revoked keys cannot come back). If no `newest` or `version > newest.version` → `newest`
   becomes this keyset.
4. Find `keyId` in the keyset's keys; missing → reject. Verify the config signature with that key's
   public key over `payload`; bad → reject.
5. Parse the config payload (below); then if `now >= expiresAt` → reject.
6. Return the config, the signing key `{id, publicKey}` and the list of dropped product keys.

`isTrusted(signingKey)`: true when there is no `newest`, or `newest.keys` contains an entry with the
same `id` **and** `publicKey`. A loaded config whose signing key is no longer trusted is not usable.

Parse the config payload (throw = reject the whole config):

* base64url → UTF-8 → JSON object, else reject.
* `schema` must be exactly `2`.
* `keyFingerprints`: array of strings each matching `^[0-9a-f]{16}$`.
* `projectId`: non-empty string. `version`: safe integer ≥ 0. `expiresAt`: finite number.
* `assignmentKey`: base64url string decoding to ≥ 32 bytes.
* `countryHeader`: a string matching `^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$` (the whole string, nothing
  trimmed) that is not `visitorSetHeader` (section 7) is kept, ASCII-lowercased. Absent, null or
  anything else means none; it never rejects the config.
* `countryHold` (since 0.4.1): a safe integer `> 0` and `<= 7776000` (90 days) is the VPN guard's
  hold in seconds (section 8); absent, 0 or anything else means 0 (off). It never rejects the config.
* `products`: object. For each entry, parse the product; an invalid product is **dropped** (left out,
  its key added to `dropped`), the rest of the config is still used.

Parse a product (null = invalid):

* object; `currency` string matching `^[A-Za-z]{3}$` (stored lowercase); `price`, `minPrice`,
  `maxPrice` safe integers (|n| ≤ 2^53−1, no fractions).
* `experiment`: null/absent, or an object with `id` matching `^[A-Za-z0-9_-]{1,64}$`, string `salt`,
  array `variants`; every variant an object with valid `id`, safe-integer `price`, safe-integer
  `weight >= 0`. Any bad variant invalidates the product. This is a test open to every visitor; a
  `countries` field on it means nothing and is not looked at.
* `scopedExperiment`: null/absent, or an object of the same shape as `experiment` plus `countries`:
  a non-empty array of at most 300 country codes, each country at most once. This is a test that
  runs only for visitors from those countries (its scope). A missing, empty or malformed
  `countries`, a repeated country, a `scopedExperiment` that is not an object, or a product that
  has both `experiment` and `scopedExperiment` invalidates the product. Keep one parsed test per
  product: the open one, or the scoped one with its scope as a set.
* `splits` (on either kind of test): absent or null means none, and so does an empty array.
  Otherwise an array of at most 300 entries, each an object with `countries` (a non-empty array of
  country codes, of any length) and `weights` (an array with exactly one safe integer `>= 0` per
  variant, in the order of `variants`). A country listed more than once (in two splits, or twice
  in one), or anything else out of shape, invalidates the product. Build a map country → weights.
  Weights are checked one by one, exactly like a variant's `weight`: they need not add up to 10000
  and one may be larger than 10000 (section 6 says what a short total does). A split may name a
  country outside the scope of a scoped test; it is kept and never used.
* A country code in `regions`, `countries` and `splits` is a string of exactly two letters `A–Z`:
  `^[A-Z]{2}$` matched against the whole string. Where `$` can match before a final newline
  (Python, Ruby, PHP), use `\A…\z` or a full match, so `"IN\n"` is refused. A JSON object is not an
  array: `{"0": "IN"}` is refused wherever a list is expected.
* `checkoutUrl` (product and variant): kept only if it is a string matching
  `^https://[^\s]+$` (case-insensitive scheme).
* `id`: string or "".
* `regions`: absent or null means no regions. Otherwise an array of at most 300 entries, each an
  object with `countries` (a non-empty array of strings matching `^[A-Z]{2}$`), `currency` (string
  matching `^[A-Za-z]{3}$`, stored lowercase) and `price` (safe integer > 0). A country listed more
  than once (in two regions, or twice in one), or anything else out of shape, invalidates the
  product. Keep the regions in order and build a map country → region index. `level` (since 0.4.1):
  what the region pays as basis points of the standard price (10000 = the same), a safe integer
  `> 0`; absent or anything else is 10000. It never invalidates the product.
* Variant `regional`: when the product has at least one region, every variant must carry
  `regional`, an array with exactly one safe integer > 0 per region (same order); otherwise the
  product is invalid. When the product has no regions, `regional` is ignored (treated as empty).

Client-level acceptance after `verify` succeeds (reject = keep the current config):

1. `keyFingerprints` must contain `SHA-256(secretKey)` as lowercase hex, first 16 chars.
2. If a config is already loaded: same `projectId`, and `version >= current.version` (no rollback).
3. If products were dropped and the version differs from the current one, report
   `Leverprice config v<version>: ignored malformed products <a, b>`.
4. Store the config and its signing key.

Every refusal of a `200` body has a code, sent back in `Leverprice-Config-Error` (section 3; the
`trust` vectors give it as `code`):

| Code | Refusal |
|---|---|
| `malformed` | body not JSON; envelope not an object with string `payload`, `signature`, `keyId`; config payload that fails parsing (schema, fingerprints, assignment key…) |
| `untrusted` | anything wrong with the keyset (step 2–3: missing, malformed, unknown or placeholder root, bad root signature, expired, below the minimum or older than `newest`) |
| `bad_signature` | `keyId` not in the keyset, or the config signature does not verify |
| `expired` | `now >= config.expiresAt` |
| `wrong_key` | acceptance step 1 |
| `wrong_project` | acceptance step 2, other `projectId` |
| `rollback` | acceptance step 2, lower `version` |

## 5. Config lifecycle

State: `config`, `signingKey`, `etag`, `fetchedAt`, `inflight` (+ start time), `failures`,
`retryAt`, `serverVersion` (highest `Leverprice-Config-Version` seen), `catchUpAt`.

* `usable(now)`: config exists, `now < config.expiresAt`, `now - fetchedAt < maxStaleMs`, and its
  signing key is still trusted.
* `kick(now)` (called on every quote, never blocks): if a fetch is in flight, nothing. Else if
  `serverVersion > config.version (or 0)` and `now >= catchUpAt`: `catchUpAt = now + 5000`, start an
  **unconditional** fetch (no `If-None-Match`). Else if not usable or
  `now - fetchedAt >= refreshIntervalMs`: start a fetch (subject to `retryAt`).
* Starting a fetch: if one is in flight, reuse it. Unless forced, do nothing while `now < retryAt`.
* `currentConfig()`: `kick(now)`; if usable, return it. Otherwise wait for the in-flight fetch at
  most `timeoutMs` counted from **this request** (since 0.4.1): a fetch started earlier by
  `preload()`, a refresh, another request or another process (PHP's shared lease) never shortens the
  wait. Then return the config if usable, else none. If the wait ran out while that fetch is still in
  flight, report `Leverprice config: still loading after <timeoutMs> ms (<option name>); serving
  fallback prices until it arrives` once per fetch (once per fetch and process in shared-nothing
  PHP). A `timeoutMs` of 0 waits for nothing and reports nothing. If no fetch is in flight (backing
  off), return none immediately.
  Before 0.4.1 the wait ended `timeoutMs` after the fetch started: after an unawaited `preload()` at
  boot, a busy server gave the first visitors 2–340 ms instead of 500, served them the fallback
  with no report and pinned them to it for 30 minutes.
* A fetch that has shown no progress for 15 s (`STALL_MS = REQUEST_TIMEOUT_MS + 5000`) is considered
  dead (an edge runtime cancelled it): start a new one.
* `Leverprice-Config-Version` header (on any config or events response): parse as a non-negative
  integer; if it is greater than `serverVersion`, store it and, if greater than the loaded config's
  version, `kick(now)`.

Languages with real threads may refresh from a background worker instead of from traffic, but the
observable behaviour (cold-start timeout, backoff, catch-up, ETag use) must stay the same, and a
background worker must never keep the process alive (daemon threads) and must survive `fork()`
(section 13).

## 6. Visitors, assignment and attribution

`key` = HMAC-SHA256 key = base64url-decoded `config.assignmentKey`.

* **Visitor key**: `u:<userId>` when a user id is given (non-empty strings as-is; safe integers in
  decimal; anything else, fractional numbers included, counts as no user id), else `a:<state.v>`
  from the cookie state.
* **New visitor key** `v` (since 0.4.1). A browser that refuses cookies used to be a new visitor on
  every request: a new price each time, counted again each time. Now, when the request has a client
  address (section 7):
  `v = hex(HMAC(key, "pp:anon:v1:" + address + "\n" + userAgent + "\n" + acceptLanguage))[0:32]`,
  where `userAgent` is the request's User-Agent (the context's `userAgent` wins) and `acceptLanguage`
  the raw `Accept-Language` header value, each `""` when missing. Without an address, `v` is 16 random
  bytes as lowercase hex (cryptographically secure RNG), as before. A visitor with a valid cookie
  keeps the cookie's `v`. Raw addresses and user agents never leave the merchant's server: only
  the HMAC, keyed by the project's assignment key. Vectors: `anonVisitors`, and the `quotes` cases
  that start with "no cookie".
* **Visitor id**: `hex(HMAC(key, "pp:visitor:v1:" + visitorKey))[0:32]`.
* **Bucket**: `SHA-256(UTF-8(salt + ":" + visitorId))`, first 4 bytes as a big-endian unsigned
  32-bit integer, modulo 10000.
* **Pick variant**: walk variants in order accumulating `weight`; the first with
  `bucket < accumulated` wins; if none, the last variant. When the visitor's country has a split
  (section 8), accumulate that split's weights instead, position by position.
* **Attribution tag** (`pp_sig`): `hex(HMAC(key, "pp:attr:v1:" + experimentId + ":" + variantId + ":" + visitorId))[0:16]`.

### Assignment cookie

Value: `<body>.<sig>` where `body = b64url(UTF-8(JSON(state)))` and
`sig = b64url(HMAC(key, "pp:cookie:v1:" + body)[0:16 bytes])` (22 characters).

State: `{ "v": <32 lowercase hex>, "a": { experimentId: variantId, … }, "x": [ experimentId, … ] }`,
plus, since 0.4.1, the VPN guard's held country `"c": <two letters A–Z>` and the second it was set
`"t": <integer seconds since the epoch>`, both or neither. `a` is **ordered** (most recent first);
serialize it in that order. JSON is compact (no spaces), keys in the order `v`, `a`, `x`, then `c`,
`t` when set. An SDK before 0.4.1 drops `c` and `t` when it rewrites the cookie; that only ends the
hold early. Languages whose maps are unordered (Go) must keep `a` as an ordered list
of pairs and write the JSON by hand. The `sign` vectors give the exact bytes.

Verifying a raw cookie value (any failure → null, never an exception):

1. length ≤ 4096; split at the first `.`; body non-empty, body matches `^[A-Za-z0-9_-]+$`, sig
   matches `^[A-Za-z0-9_-]{22}$`.
2. Constant-time compare of the first 16 bytes of `HMAC(key, "pp:cookie:v1:" + body)` with the
   decoded sig.
3. Decode body as JSON; must be an object whose `v` is a string matching `^[0-9a-f]{32}$` and whose
   `a` is an object (not an array).
4. Normalize: keep the first 10 entries of `a` (in order); of those keep pairs where the experiment id
   and the variant (a string) both match `^[A-Za-z0-9_-]{1,64}$`. `x`: if an array, keep string
   entries that are keys of the normalized `a`, at most 10; otherwise empty. Keep `c` and `t` only
   when `c` is a string matching `^[A-Z]{2}$` (whole string) and `t` a safe integer `>= 0`;
   otherwise drop both.

Operations:

* `assign(state, exp, var)`: `a = [(exp, var)] + [other pairs without exp]`, truncated to 10 pairs;
  then `x` keeps only ids still in `a`.
* `markExposed(state, exp)`: if `exp` already in `x` → return false. Else
  `x = [exp] + x`, filtered to ids in `a`, truncated to 10; return true.
* Experiment, variant and product ids issued by the server always start with a letter prefix
  (`exp_…`, `var_…`), so they are never integer-like. (JavaScript objects order integer-like keys
  first; other languages keep document order.)
* New visitor: `v` = the new visitor key (above), `a = {}`, `x = []`, no `c` / `t`.

### Set-Cookie

```
<name>=<value>; Path=/; Max-Age=<seconds>; SameSite=Lax; HttpOnly[; Secure][; Domain=<domain>]
```

The pin cookie is `<cookieName>_f=1` with `Max-Age=1800`.

## 7. Reading the request

The SDK accepts whatever request object the framework has and reads the `Cookie` header, the
`User-Agent` header, prefetch hints, when told where to look the visitor's country and, for a
visitor without a cookie, the client address and the `Accept-Language` header. Header names are matched without regard to ASCII case only: fold `A–Z` and nothing else,
because Unicode case mapping turns U+212A into `k` and U+017F into `s`. A header with several values
(Node-style arrays) is joined with `"; "` for `Cookie` and `", "` otherwise. Explicit `cookie` /
`userAgent` in the context win over the request.

Cookie values for a name (`cookieValues(header, name)`): split the header on `;` **and** `,` (Fetch
`Headers` joins repeated headers with `", "`); for each part, the name is the text before the first
`=`, trimmed; parts without `=` or with an empty name are skipped; the value is the rest, trimmed;
surrounding double quotes are removed; if it contains `%`, percent-decode it (keep the raw value if
decoding fails); empty values are skipped. Return all values in order.

* `assignmentCookies` = `cookieValues(cookieHeader, cookieName)`; try at most the first 4, in order;
  the first that verifies wins.
* `pinned` = `cookieValues(cookieHeader, cookieName + "_f")` is non-empty.
* Legacy: if the explicit `cookie` context value contains no `=`, it is the bare assignment cookie
  value (trimmed; empty → none) and the pin is not read.
* Prefetch: true if any of `sec-purpose`, `x-sec-purpose`, `purpose`, `x-purpose`, `x-moz` matches
  `/prefetch|prerender|preview/i`, or `next-router-prefetch` equals `1`. `x-sec-purpose` is what
  Turbo 8 sends for hover prefetches: scripts cannot set a `Sec-` header themselves.
* Country: if the context's `country` is a string, it is the input (even when it turns out invalid:
  no header is then consulted). Otherwise, if the `countryHeader` option is set, the value of that
  request header (the config's header is then never consulted, even when the option's header is
  missing). Otherwise the value of the header the config's `countryHeader` names, read once a
  config is loaded (section 8); none when the config names none. `normalizeCountry(input)`: not a string → null; the whole
  input must be exactly two ASCII letters (`A–Z`, `a–z`), optionally surrounded by ASCII whitespace
  (space, tab, LF, VT, FF, CR) and nothing else; uppercase those two letters; the result must not
  be one of `XX`, `ZZ`, `T1`, `A1`, `A2`, `AP`, `EU` (what CDNs send for "unknown", Tor, anonymous
  proxies and non-countries); else null. Check the letters **before** changing case and never use
  Unicode-aware trimming or case mapping here: `"ß".upper()` is `"SS"` and `"ﬁ"` becomes `"FI"` in
  several languages, and a no-break space is whitespace to some trim functions and not to others.
  Anchor the pattern to the whole string (`\A…\z`, not `^…$`, where `$` can match before a final
  newline).
* `visitorSetHeader(name)` (since 0.4.1): fold `A–Z` to `a–z`; true when the name starts with
  `sec-`, `accept`, `content-`, `if-`, `x-forwarded-` or `proxy-`, or is one of `authorization`,
  `cache-control`, `connection`, `cookie`, `dnt`, `forwarded`, `host`, `origin`, `pragma`,
  `priority`, `purpose`, `range`, `referer`, `te`, `upgrade-insecure-requests`, `user-agent`, `via`,
  `x-real-ip`, `x-requested-with`. Such a header is never a country source: not as the
  `countryHeader` option, not from the config. The dashboard applies the same rule. Vectors:
  `countryHeaderNames`.
* Client address (since 0.4.1), only to key a visitor without a cookie: the first of these request
  headers whose value, cut at the first `,`, normalizes to an address: `cf-connecting-ip`,
  `true-client-ip`, `fastly-client-ip`, `fly-client-ip`, `x-real-ip`, `x-forwarded-for`; else the
  address of the connection where the platform has one (Node `request.ip` or
  `request.socket.remoteAddress`, WSGI/Rack/PHP `REMOTE_ADDR`, Go `Request.RemoteAddr`), normalized;
  else none. A visitor can forge these headers, and gains nothing by it: a forged address only
  makes them a new visitor, as clearing cookies always could. Vectors: `clientAddresses` (the
  connection's address is `remoteAddress`).
* `normalizeAddress(value)`: not a string → none. Strip spaces and tabs at both ends. If it starts
  with `[`: it needs a `]`, followed by nothing or by `:` and 1–5 digits; the address is what is
  between the brackets. Else if it is digits and dots, then `:` and 1–5 digits, drop the port. Drop
  everything from the first `%` (a zone). IPv4: four decimal numbers 0–255 joined by dots, no sign,
  no leading zero (`07` is refused); the result is the four numbers in decimal. IPv6: groups of 1–4
  hex digits separated by `:`, at most one `::` standing for one or more zero groups, optionally
  ending in an IPv4 address that stands for the last two groups; exactly 8 groups in all. An
  IPv4-mapped address (`::ffff:a.b.c.d`, in any spelling) becomes that IPv4 address. Any other IPv6
  address becomes its /64 network: the first four groups in lowercase hex without leading zeros,
  joined by `:` (`2001:db8:1:2`), because phones change the rest of the address every day. Anything
  else → none. Implement it by hand if the platform's parser disagrees with the `addresses` vectors.

## 8. getPrice algorithm

```
guard = products[productKey]            (missing → raise: merchant bug)
if off(): return fallback("disabled")
try:
  req = readRequest(context)
  bot = context.bot if it is a bool else isBot(req.userAgent)
  if bot: return botQuote()
  if req.pinned or (this request already pinned, see below):
      kick(now); return fallback("pinned_fallback", setCookie=[pin])
  config = currentConfig()
  if none: return noConfig()                         fallback("no_config", [pin]); mark the request pinned
  if no context country and no countryHeader option:
      req.country = normalizeCountry(header named by config.countryHeader)   (none if it names none)
  product = config.products[productKey]   missing → fallback("unknown_product")
  product.currency != guard.currency     → fallback("currency_mismatch")
  country = req.country
  if config.countryHold > 0 and product has regions:
      visitor = visitorState()                              (experimentQuote step 1)
      country = heldCountry(visitor, req.country)
  exp = experimentFor(product, country)
  no exp:
      not inBounds(product.price) → fallback("out_of_bounds")
      region = regionFor(country)
      region ? quote(region.price, "base_price", currency=region.currency, regional=true, checkoutUrl=null)
             : quote(product.price, "base_price", checkoutUrl=product's)
      both carry country = country
      with a visitor: remember its state for the request (step 5 below); setCookie =
          [Set-Cookie(cookieName, sign(state))] if the state changed and holds a country, else []
  exp with no variants, or any variant out of bounds → fallback("out_of_bounds")
  return experimentQuote(exp, regionFor(country))      (with the visitor, if there is one)
except any error:
  report(error); return bot ? fallback("bot") : noConfig()
```

`inBounds(p)`: safe integer, `p > 0`, `product.minPrice <= p <= product.maxPrice` (the signed
range).

`botQuote()`: `currentConfig()`; if it has the product with the guard's currency and the standard
price in bounds → price quote with reason `bot` (not a fallback, `checkoutUrl` = product's), else
`fallback("bot")`. Bots get no cookie, no exposure and never a regional price (`country` null).

Every fallback quote and every `bot` quote has `country = null` and `regional = false`.

`experimentFor(product, country)` is the test the visitor is in: the product's open test; or its
scoped test when `country` is not null and is in the test's scope; otherwise none. A visitor outside
the scope, or whose country is unknown, is priced exactly as if the product had no test: no
assignment, no cookie, no exposure, reason `base_price`. That also holds for a visitor whose cookie
carries an assignment from an earlier visit inside the scope; the cookie is left as it is. The
variants of a scoped test are checked against the bounds only for visitors inside its scope.

**VPN guard** (`heldCountry`, since 0.4.1). Regional prices follow the visitor's IP address, and a
VPN changes it. A visitor seen lately in a country that pays more keeps that country's price, so
switching a VPN to a cheaper country changes nothing until the hold runs out:

```
now  = whole seconds since the epoch
held = state.c if state has c and t and now - state.t < config.countryHold, else none
if held and held != country and level(held) > level(country):
    return held                                    (the state is left as it is)
if country is not none and held != country:
    state.c = country; state.t = now; changed = true
return country
```

`level(c)`: none → 10000; else `regionFor(c)` → that region's `level`; no region (or one that may not
be served) → 10000. So the comparison is between what the visitor would actually pay. A visitor
who moves to a dearer country, or comes back after the hold, is priced where they are and held
there. A held country also picks the scoped test, the split, the region of a test price, the
quote's `country` and the exposure's country. Bots never get a hold. Vectors: `countryHold`.

`regionFor(country)` returns the visitor's region when its price may be served, else none:

1. none if `country` is null.
2. `index` = the product's region index for `country`; none if the country is in no region.
3. none if `region.currency` differs from the guard's currency and the `localCurrencies` option is
   not true (nothing is reported). Only that option says the checkout charges `quote.currency`.
4. Otherwise the region `{ index, currency, price }`.

Regional prices need no other check here: the server derives them from the standard and test
prices checked above, keeps every country between 5% and 200% of the standard price, and signs no
region for a product sold through checkout links.

The standard price checks always come first: a product whose standard price or variants are out of
bounds is a fallback for every country. A visitor without a usable region is priced exactly as
before regional prices existed; their `country` is still reported.

`experimentQuote()`:

1. State (`visitorState()`; already done when the VPN guard ran): if an earlier quote of the **same
   request** left a cookie state for the same cookie input, same user id and same assignment key,
   start from a copy of it. Otherwise verify the request's assignment cookies (first valid of at
   most 4). None → new visitor state (section 6), `changed = true`.
2. `visitorId` from the visitor key (section 6).
3. If `state.a` has this experiment **and** that variant still exists in the experiment, it sticks.
   Otherwise pick by bucket and `assign`, `changed = true`. The weights are the split's when
   `req.country` is not null and a split lists it, else the variants' own. A split never moves a
   visitor who already has a variant.
4. `logged` = experiment in `state.x`, or this process already logged `(experimentId, visitorId)`.
   If not logged, exposure mode is `auto` and the request is not a prefetch: record the exposure
   (section 10), `logged = true`. If `logged` and `markExposed(state, exp)` returns true,
   `changed = true`.
5. Remember the state for later quotes of the same request.
6. Return `price = region ? variant.regional[region.index] : variant.price`,
   `currency = region ? region.currency : guard.currency`, `country = req.country`,
   `regional = region is set`, `metadata = { pp_exp, pp_var, pp_vid, pp_sig }`,
   `setCookie = changed ? [Set-Cookie(cookieName, sign(state), cookieMaxAgeSeconds)] : []`,
   `checkoutUrl = region ? null : (variant.checkoutUrl ?? product.checkoutUrl ?? null)`,
   `exposureLogged = logged`.

The exposure recorded in step 4 carries `req.country` when it is not null (section 10), whether or
not a regional price applies. `logExposure(quote)` sends `normalizeCountry(quote.country)` the same
way: a quote that went through a cache or was edited can never make its exposure invalid.

"Same request" sharing lets one page price several products and send one cookie: the last quote's
`Set-Cookie` carries every assignment. Quotes of one request are computed one after another. Where a
language has no stable request object identity (or it is unidiomatic), sharing by the identity of the
request object passed in is enough; without a request object there is no sharing.

## 9. Kill switch and off state

`off()` = `disabled` option, or no valid secret key, or env `LEVERPRICE_DISABLED` (trimmed,
lowercase) is `1` or `true`. Read the env **on every call** (it can be flipped at runtime). While off:
`getPrice` returns `fallback("disabled")` with no cookie and no network; tracking and exposure calls
do nothing; errors are not reported.

## 10. Events

Wire event shapes (JSON):

```
{ "type": "exposure", "experimentId", "variantId", "visitorId", "timestamp", "country"? }
{ "type": "purchase", "provider", "orderId", "amount", "currency", "timestamp", "attribution": null | { "experimentId", "variantId", "visitorId", "signature": null | "<16 hex>" } }
{ "type": "refund", "provider", "orderId", "currency", "timestamp", ("refundId", "amount") and/or "refundedTotal" }
```

`timestamp` is milliseconds since the epoch. Providers: `stripe`, `polar`, `lemonsqueezy`, `dodo`,
`paddle`, `creem`, `other`. `country` on an exposure is the visitor's normalized country; the key is left out (never
sent as null) when the country is unknown.

Validation before queueing (an invalid event is reported as
`Leverprice: dropped invalid <type> event: <problem>` and dropped; the server would reject the whole
batch for it): timestamp a positive integer; ids match `^[A-Za-z0-9_-]{1,64}$`; provider known;
an exposure's `country`, when present, a string matching `^[A-Z]{2}$`;
`orderId` and `refundId` strings of 1–255 characters; currency `^[a-z]{3}$`; amounts integers in
`0..10000000000`; attribution ids valid and signature null or `^[0-9a-f]{16}$`; a refund needs
`refundId` + `amount`, or `refundedTotal`.

Normalization in `trackPurchase` / `trackRefund`: `orderId`/`refundId` become strings (integers in
decimal; anything else becomes `""` so validation rejects it); numeric amounts are rounded to
integers and anything that is not a number (null included) makes the event invalid;
currency is lowercased; `timestamp` defaults to now, and a value below `1e12` is taken as Unix
seconds and multiplied by 1000. Attribution is read from `metadata` (own keys only): `pp_exp`,
`pp_var`, `pp_vid` must be valid ids (else attribution is null); `pp_sig` is kept if it matches
`^[0-9a-f]{16}$`, else null.

Exposures: a process-wide set of `experimentId:visitorId` (clear it when it reaches 10000 entries)
deduplicates; a duplicate is not queued.

Queue: at most 5000 events; when over, drop the oldest exposure first, and only when no exposure is
left, drop the oldest money event (report `Leverprice: event queue full, dropped <type> <orderId>`).
Enqueue triggers a flush when the queue reaches 100 events, else arms a single timer for
`flushIntervalMs` (the timer must not keep the process alive).

Flush: drains one after another (a flush resolves after earlier drains). A drain sends only the
batches that were queued when it started, 500 events per request. Each request is attempted up to 3
times with waits of 250 ms, then 1000 ms between attempts. If a batch fails after all attempts, its
money events (purchases, refunds) go back to the **front** of the queue, exposures are dropped,
the error is reported, and the drain stops. `trackPurchase` and `trackRefund` enqueue and then
flush, waiting for the flush.

## 11. Errors

`report(error)`: ignored while off; otherwise `onError(error)` (exceptions inside it swallowed), or
a warning on the platform logger when no `onError` is given. Messages start with `Leverprice`.

## 12. Conformance vectors (`sdks/conformance/vectors.json`)

Load the file (tests should search upward from the test file for `conformance/vectors.json`, so the
same test works in the monorepo and in the published repository). Sections:

* `rootKeys`, `secretKey`, `assignmentKey`, `now`: inputs used by the other sections.
* `keyFingerprints[]`: `{secretKey, fingerprint}`.
* `config`: the signed envelope every `quotes` case is served.
* `trust[]`: `{name, minKeysetVersion?, steps[]}`. For each case create a fresh trust chain with
  `vectors.rootKeys` and `minKeysetVersion` (default 1) and a fresh acceptance state, then feed each
  step's `envelope` through the full acceptance (section 4: chain + fingerprint of
  `vectors.secretKey` + project + rollback) at time `step.now ?? vectors.now`. `expect` is `accept`
  or `reject`; accepted steps also give `version` and the `dropped` product keys (in order).
* `visitorIds[]`: `{visitorKey, message, visitorId}` with `vectors.assignmentKey`.
* `attribution[]`: `{experimentId, variantId, visitorId, message, signature}`.
* `buckets[]`: `{salt, visitorId, bucket}`. `pickVariant[]`: `{weights, bucket, index}`.
* `cookies.sign[]`: `{state, json, cookie}`. `state.a` is a list of `[experimentId, variantId]`
  pairs in order. Your serializer must produce exactly `json`, and signing must produce exactly
  `cookie`.
* `cookies.verify[]`: `{name, cookie, state | null}` (same pair format).
* `cookies.ops[]`: `{name, state, op: {assign: [exp, var]} | {markExposed: exp}, changed?, result}`.
* `cookieHeader[]`: `{header, name, values}`. `prefetch[]`: `{headers, prefetch}` (lowercase names).
* `setCookie[]`: `{name, value, maxAge, secure, domain, header}`.
* `countries[]`: `{value, country}` for `normalizeCountry`.
* `bots[]`: `{userAgent, bot}`.
* `events[]`: `{event, valid}` for the pre-queue validation.
* `trust[]` steps also carry, since 0.4.1, `code` on every `reject` (the `Leverprice-Config-Error`
  code, section 4) and, on some `accept` steps, `countryHeader`: the header the SDK will read the
  country from (null: none).
* `countryHeaderNames[]`: `{name, allowed}`: `allowed` is `!visitorSetHeader(name)`.
* `addresses[]`: `{value, address}` for `normalizeAddress`. `clientAddresses[]`: `{headers,
  remoteAddress?, address}`: the request's headers and the connection's address.
* `anonVisitors[]`: `{address, userAgent, acceptLanguage, message, v}` with `vectors.assignmentKey`.
* `productsHeader[]`: `{products, header}`: a client built with these `products` sends this
  `Leverprice-Products` value.
* `countryHold`: `{config, guards, visitor, cases[]}`. Each case: `{name, productKey, country?,
  cookie, localCurrencies?, expect}`. Build a client like for `quotes` (fake transport serving
  `countryHold.config`, products = `countryHold.guards`, `localCurrencies` when the case says
  true). If `cookie` is not null, sign the state `{v: countryHold.visitor, a: cookie.a ?? [], x:
  cookie.x ?? []}` plus, when `cookie.c` is present, `c = cookie.c` and `t = now - cookie.age` (whole
  seconds, your real clock), and send it as `__pp`. Headers: a browser `User-Agent`, `x-geo-country`
  when the case has `country`, and the cookie. Call `getPrice(productKey, {request})` and `flush()`.
  `expect` holds `price`, `currency`, `country`, `regional`, `reason`, `variantId`, `exposures` (sent
  events without `timestamp` and `visitorId`) and `cookie`: null when the quote sets no `__pp`
  cookie, else that cookie's verified state as `{c, t, a}` where `c` is the held country or null,
  `t` is `"kept"` when it equals the `t` you signed, `"fresh"` when it is another value (it must be
  within a few seconds of now) and null when absent, and `a` the assignment pairs in order.
* `quotes[]`: `{name, productKey, guards?, headers, userId, exposure?, bot?, countryHeader?,
  localCurrencies?, country?, errors, expect}`. The signed `config` names `x-geo-country` as the
  project's country header. `localCurrencies`, when present, is the client option of that name. Build a client with `secretKey = vectors.secretKey`,
  `trustedRootKeys = vectors.rootKeys`, products = the `quotes` default guards (below) overridden by
  the case's `guards`, the `countryHeader` and `localCurrencies` options when the case has them, and a fake transport that
  answers `GET /v1/config` with `vectors.config` (status 200, `ETag: "v5"`) and `POST /v1/events`
  with 202. Call `getPrice(productKey, {request: headers, userId, exposure, bot, country})` (pass
  `country` only when the case has it), then `flush()`. `expect` holds every quote field except
  `productKey`, plus `exposures`: the events sent, without `timestamp` (an exposure has a `country`
  key only when the country is known). `errors` lists, in order, every `onError` message the case must produce apart
  from the malformed-products report, which is always allowed. Cases about products that are not in
  the table below (`local`, `localwild`, `split`, the malformed ones) carry all the guards they need.
  Two cases put the 0.3 keys `minPrice` and `maxPrice` in a guard: pass them through exactly like
  0.3 merchant code would, and the quote must not change.

  Default guards for `quotes`:

  ```
  pro:     usd, fallback 1900
  basic:   usd, fallback 1000
  euro:    eur, fallback 1200
  wild:    usd, fallback 2000
  bad:     usd, fallback 150
  ghost:   usd, fallback 4900
  geo:     usd, fallback 2900
  geox:    usd, fallback 2900
  badgeo:  usd, fallback 2900
  badgeox: usd, fallback 2900
  ```

Behavioural tests every SDK also needs (with a fake transport and a controllable clock where the
language allows): cold start that times out returns `no_config` within about `timeoutMs`; outage
→ `no_config` + pin cookie, then `pinned_fallback` while the pin is sent; `304` revalidation keeps
the config; a newer `Leverprice-Config-Version` triggers an unconditional fetch; failed event sends
re-queue purchases and drop exposures; a `400` is not retried; kill switch via option and env;
malformed secret key → `disabled` and one error; a throwing `onError` changes nothing;
`trackPurchase` reads attribution from metadata and converts seconds to milliseconds;
`ROOT_PUBLIC_KEYS` contains only valid 32-byte keys; a guard with 0.3's `minPrice` and `maxPrice`,
even invalid ones (`minPrice` above `maxPrice`; a string where the language allows one), constructs
and serves the signed prices;
an invalid `countryHeader` raises at construction, including a header name with a character outside
ASCII (U+212A lowercases to `k` in most languages and must still be refused); a `countryHeader` that
`visitorSetHeader` names (`Accept-Language`, `x-forwarded-for`) is ignored, reported once and never
reported when disabled; every config request carries `Leverprice-Products`, and
`Leverprice-Config-Error` after a refused `200` until one is accepted; a request without a cookie
but with an address gets the same visitor every time (one exposure for 20 requests), and one without
an address a new one; `logExposure` on a manual quote sends the quote's
country, and still logs the exposure (without a country) when the quote's country was replaced by
something that is not one.

## 13. Platform notes

* **Ed25519.** JS: WebCrypto. Go: `crypto/ed25519`. PHP: `sodium_crypto_sign_verify_detached`
  (ext-sodium, bundled with PHP ≥ 7.2; `paragonie/sodium_compat` as a polyfill). Ruby: OpenSSL
  (`OpenSSL::PKey.read` of a DER SubjectPublicKeyInfo: prefix `302a300506032b6570032100` + 32-byte
  key). Python: the `cryptography` package when importable, otherwise a pure-Python RFC 8032
  verifier shipped in the package (verification is rare: only for a new config body).
* **Regex lookbehind.** The bot pattern `(?<!cu)bot(?![a-z])` needs lookbehind/lookahead. Go's RE2
  has neither: implement that one pattern by hand (every occurrence of `bot`, case-insensitive, not
  preceded by `cu` and not followed by a letter `a–z`).
* **Fork safety (Python, Ruby).** Pre-forking servers (gunicorn, uWSGI, Unicorn, Puma clustered)
  copy the client into children after the parent may have started threads. Record the PID; when it
  changes, reset threads, locks, the in-flight fetch and the event queue (never re-send the
  parent's queue from a child).
* **Shared-nothing PHP.** Each request starts from scratch, so the config, ETag, `fetchedAt`,
  `newest` keyset version and `serverVersion` live in a cache that survives requests: APCu when
  available, otherwise files in the system temp directory (atomic rename, `0600`), or a PSR-16
  cache the merchant passes. Cache keys include the key fingerprint and the API URL. Events are
  flushed at shutdown (`register_shutdown_function`, after `fastcgi_finish_request()` when
  available) and immediately for `trackPurchase` / `trackRefund`. Re-verify signatures when loading
  from a file cache (cheap with sodium) or keep a MAC; never trust a cached file blindly.
* **Go.** `context.Context` on every call; goroutines for refresh and flush; `Close()` /
  `Flush(ctx)` for shutdown.
* **CGI-style header maps (WSGI, Rack, `$_SERVER`).** `CF-IPCountry` and `CF_IPCountry` both become
  `HTTP_CF_IPCOUNTRY`, so the SDK cannot tell the header the CDN set from one a visitor spelled with
  underscores. The server in front must drop header names with underscores (nginx does by default);
  the READMEs of those SDKs say so next to `countryHeader`.

## 14. Packaging

| Language | Registry name | Import |
|---|---|---|
| JavaScript / TypeScript | npm `@leverprice/sdk`, JSR `@leverprice/sdk` | `import { Leverprice } from "@leverprice/sdk"` |
| Python ≥ 3.9 | PyPI `leverprice` | `from leverprice import Leverprice` |
| PHP ≥ 8.1 | Packagist `leverprice/leverprice-php` | `use Leverprice\Leverprice;` |
| Ruby ≥ 3.1 | RubyGems `leverprice` | `require "leverprice"` |
| Go ≥ 1.22 | `github.com/leverprice/leverprice-go` | `import "github.com/leverprice/leverprice-go"` |

All SDKs: MIT license, version `0.4.1` for this protocol revision (0.4.1 added the VPN guard
`countryHold` with region `level` and the cookie's `c` / `t`, stable keys for visitors without a
cookie, the `Leverprice-Products` and `Leverprice-Config-Error` request headers, and ignores country
headers visitors send; 0.4.0 added regional prices:
`regions`, `localCurrencies`, the config's `countryHeader` and the option that overrides it,
`country`; stopped using 0.3's `minPrice` and `maxPrice` in code; and tests by country: `scopedExperiment` and `splits`. A 0.3.0 SDK ignores all of them: it keeps serving standard prices,
splits every visitor by the variants' own weights and never sees a scoped test), a README with the same sections as the JS README (quick start for the main
frameworks of that language, guarantees, requests and cookies, regional prices, exposures, bots, kill
switch, outages, trust chain, reference), and a `CHANGELOG.md`.
