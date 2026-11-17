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
   config chain, and every price is checked against the merchant's local min/max and currency.
4. **Private.** Raw visitor and user ids never leave the merchant's server; only HMACs do.
5. **No price flips.** A visitor keeps their variant (signed cookie). A browser that got the
   fallback during an outage keeps it for the rest of its session (pin cookie).
6. **Zero or near-zero dependencies.** Use the standard library. Where the standard library lacks
   Ed25519, use the platform's native crypto first and fall back to a pure implementation
   (see section 13).

## 2. Public API

Names follow each language's conventions (camelCase in JS/Go fields, snake_case in Python/Ruby/PHP
array keys where idiomatic). The concepts and defaults are identical everywhere.

### Options (constructor)

| Option | Default | Meaning |
|---|---|---|
| `secretKey` | — | `pp_sk_live_…` / `pp_sk_test_…`. Missing or malformed → the SDK is off (fallback prices, reason `disabled`, no network). A non-empty malformed key is reported once through `onError` at construction (unless disabled). Trim whitespace first. |
| `products` | — | Map productKey → guard `{ currency, fallbackPrice, minPrice?, maxPrice? }`. Validated at construction (raise on invalid: this is merchant code). `currency` = 3 letters (stored lowercase). `fallbackPrice` = positive integer. `minPrice` default 1, `maxPrice` default 2^53−1 (Go/PHP/Ruby/Python: same value, 9007199254740991), both integers, `minPrice <= maxPrice`. |
| `disabled` | false | Kill switch (see section 9). |
| `apiUrl` | `https://api.leverprice.com` | Trailing slashes stripped. |
| `timeoutMs` | 500 | Max time a request waits for a config when none is usable. |
| `refreshIntervalMs` | 30000 | Revalidate the config this often (driven by traffic or a background worker). |
| `maxStaleMs` | 86400000 | Stop using a config this long after the server last confirmed it. |
| `cookieName` | `__pp` | Must match `^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$` (raise otherwise). The pin cookie is `<cookieName>_f`. |
| `cookieMaxAgeSeconds` | 15552000 (180 days) | Assignment cookie lifetime. |
| `cookieSecure` | true | `Secure` attribute. |
| `cookieDomain` | none | `Domain` attribute. |
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
| `getPrice(productKey, context)` → `Quote` | context: `request`, `cookie`, `userAgent`, `userId`, `exposure` (`"auto"` default / `"manual"`), `bot` (bool, optional). |
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
| `currency` | lowercase, from the merchant's guard |
| `isFallback` | `price` is the guard's `fallbackPrice` |
| `reason` | see the table below |
| `experimentId`, `variantId`, `visitorId` | set only when reason is `experiment`, else null |
| `metadata` | `{ pp_exp, pp_var, pp_vid, pp_sig }` when reason is `experiment`, else empty map |
| `setCookie` | list of `Set-Cookie` header values (zero or more) |
| `checkoutUrl` | variant's `checkoutUrl`, else product's, else null (also on `base_price` / `bot` quotes: the product's) |
| `exposureLogged` | an exposure for this visitor and experiment has been logged (now or earlier) |

| reason | price | isFallback |
|---|---|---|
| `experiment` | the visitor's variant | false |
| `base_price` | the product's standard price (no experiment) | false |
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
* `products`: object. For each entry, parse the product; an invalid product is **dropped** (left out,
  its key added to `dropped`), the rest of the config is still used.

Parse a product (null = invalid):

* object; `currency` string matching `^[A-Za-z]{3}$` (stored lowercase); `price`, `minPrice`,
  `maxPrice` safe integers (|n| ≤ 2^53−1, no fractions).
* `experiment`: null/absent, or an object with `id` matching `^[A-Za-z0-9_-]{1,64}$`, string `salt`,
  array `variants`; every variant an object with valid `id`, safe-integer `price`, safe-integer
  `weight >= 0`. Any bad variant invalidates the product.
* `checkoutUrl` (product and variant): kept only if it is a string matching
  `^https://[^\s]+$` (case-insensitive scheme).
* `id`: string or "".

Client-level acceptance after `verify` succeeds (reject = keep the current config):

1. `keyFingerprints` must contain `SHA-256(secretKey)` as lowercase hex, first 16 chars.
2. If a config is already loaded: same `projectId`, and `version >= current.version` (no rollback).
3. If products were dropped and the version differs from the current one, report
   `Leverprice config v<version>: ignored malformed products <a, b>`.
4. Store the config and its signing key.

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
* `currentConfig()`: `kick(now)`; if usable, return it. Otherwise wait for the in-flight fetch, but
  never longer than `timeoutMs` after **that fetch started** (so concurrent requests during a cold
  start all give up at the same moment); then return the config if usable, else none. If no fetch is
  in flight (backing off), return none immediately.
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
* **Visitor id**: `hex(HMAC(key, "pp:visitor:v1:" + visitorKey))[0:32]`.
* **Bucket**: `SHA-256(UTF-8(salt + ":" + visitorId))`, first 4 bytes as a big-endian unsigned
  32-bit integer, modulo 10000.
* **Pick variant**: walk variants in order accumulating `weight`; the first with
  `bucket < accumulated` wins; if none, the last variant.
* **Attribution tag** (`pp_sig`): `hex(HMAC(key, "pp:attr:v1:" + experimentId + ":" + variantId + ":" + visitorId))[0:16]`.

### Assignment cookie

Value: `<body>.<sig>` where `body = b64url(UTF-8(JSON(state)))` and
`sig = b64url(HMAC(key, "pp:cookie:v1:" + body)[0:16 bytes])` (22 characters).

State: `{ "v": <32 lowercase hex>, "a": { experimentId: variantId, … }, "x": [ experimentId, … ] }`.
`a` is **ordered** (most recent first); serialize it in that order. JSON is compact (no spaces), keys
in the order `v`, `a`, `x`. Languages whose maps are unordered (Go) must keep `a` as an ordered list
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
   entries that are keys of the normalized `a`, at most 10; otherwise empty.

Operations:

* `assign(state, exp, var)`: `a = [(exp, var)] + [other pairs without exp]`, truncated to 10 pairs;
  then `x` keeps only ids still in `a`.
* `markExposed(state, exp)`: if `exp` already in `x` → return false. Else
  `x = [exp] + x`, filtered to ids in `a`, truncated to 10; return true.
* Experiment, variant and product ids issued by the server always start with a letter prefix
  (`exp_…`, `var_…`), so they are never integer-like. (JavaScript objects order integer-like keys
  first; other languages keep document order.)
* New visitor: `v` = 16 random bytes as lowercase hex (cryptographically secure RNG), `a = {}`,
  `x = []`.

### Set-Cookie

```
<name>=<value>; Path=/; Max-Age=<seconds>; SameSite=Lax; HttpOnly[; Secure][; Domain=<domain>]
```

The pin cookie is `<cookieName>_f=1` with `Max-Age=1800`.

## 7. Reading the request

The SDK accepts whatever request object the framework has and reads three things: the `Cookie`
header, the `User-Agent` header and prefetch hints. Header names are case-insensitive. A header with
several values (Node-style arrays) is joined with `"; "` for `Cookie` and `", "` otherwise. Explicit
`cookie` / `userAgent` in the context win over the request.

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
* Prefetch: true if any of `sec-purpose`, `purpose`, `x-purpose`, `x-moz` matches
  `/prefetch|prerender|preview/i`, or `next-router-prefetch` equals `1`.

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
  product = config.products[productKey]   missing → fallback("unknown_product")
  product.currency != guard.currency     → fallback("currency_mismatch")
  no experiment: inBounds(product.price) ? quote(product.price, "base_price", checkoutUrl=product's)
                                         : fallback("out_of_bounds")
  experiment with no variants, or any variant out of bounds → fallback("out_of_bounds")
  return experimentQuote()
except any error:
  report(error); return bot ? fallback("bot") : noConfig()
```

`inBounds(p)`: safe integer, `p > 0`, `p >= max(guard.minPrice, product.minPrice)`,
`p <= min(guard.maxPrice, product.maxPrice)`.

`botQuote()`: `currentConfig()`; if it has the product with the guard's currency and the standard
price in bounds → price quote with reason `bot` (not a fallback, `checkoutUrl` = product's), else
`fallback("bot")`. Bots get no cookie and no exposure.

`experimentQuote()`:

1. State: if an earlier quote of the **same request** left a cookie state for the same cookie input,
   same user id and same assignment key, start from a copy of it. Otherwise verify the request's
   assignment cookies (first valid of at most 4). None → new visitor state, `changed = true`.
2. `visitorId` from the visitor key (section 6).
3. If `state.a` has this experiment **and** that variant still exists in the experiment, it sticks.
   Otherwise pick by bucket and `assign`, `changed = true`.
4. `logged` = experiment in `state.x`, or this process already logged `(experimentId, visitorId)`.
   If not logged, exposure mode is `auto` and the request is not a prefetch: record the exposure
   (section 10), `logged = true`. If `logged` and `markExposed(state, exp)` returns true,
   `changed = true`.
5. Remember the state for later quotes of the same request.
6. Return the variant price, `metadata = { pp_exp, pp_var, pp_vid, pp_sig }`,
   `setCookie = changed ? [Set-Cookie(cookieName, sign(state), cookieMaxAgeSeconds)] : []`,
   `checkoutUrl = variant.checkoutUrl ?? product.checkoutUrl ?? null`, `exposureLogged = logged`.

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
{ "type": "exposure", "experimentId", "variantId", "visitorId", "timestamp" }
{ "type": "purchase", "provider", "orderId", "amount", "currency", "timestamp", "attribution": null | { "experimentId", "variantId", "visitorId", "signature": null | "<16 hex>" } }
{ "type": "refund", "provider", "orderId", "currency", "timestamp", ("refundId", "amount") and/or "refundedTotal" }
```

`timestamp` is milliseconds since the epoch. Providers: `stripe`, `polar`, `lemonsqueezy`, `dodo`,
`other`.

Validation before queueing (an invalid event is reported as
`Leverprice: dropped invalid <type> event: <problem>` and dropped; the server would reject the whole
batch for it): timestamp a positive integer; ids match `^[A-Za-z0-9_-]{1,64}$`; provider known;
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
* `bots[]`: `{userAgent, bot}`.
* `events[]`: `{event, valid}` for the pre-queue validation.
* `quotes[]`: `{name, productKey, guards?, headers, userId, exposure?, bot?, expect}`. Build a client
  with `secretKey = vectors.secretKey`, `trustedRootKeys = vectors.rootKeys`, products = the
  `quotes` default guards (below) overridden by the case's `guards`, and a fake transport that
  answers `GET /v1/config` with `vectors.config` (status 200, `ETag: "v5"`) and `POST /v1/events`
  with 202. Call `getPrice(productKey, {request: headers, userId, exposure, bot})`, then `flush()`.
  `expect` holds every quote field plus `exposures`: the events sent, without `timestamp`. The only
  `onError` message allowed is the malformed-products report.

  Default guards for `quotes`:

  ```
  pro:   usd, fallback 1900, min 1500, max 3900
  basic: usd, fallback 1000
  euro:  eur, fallback 1200, min 100, max 5000
  wild:  usd, fallback 2000, min 1000, max 3000
  bad:   usd, fallback 150
  ghost: usd, fallback 4900
  ```

Behavioural tests every SDK also needs (with a fake transport and a controllable clock where the
language allows): cold start that times out returns `no_config` within about `timeoutMs`; outage
→ `no_config` + pin cookie, then `pinned_fallback` while the pin is sent; `304` revalidation keeps
the config; a newer `Leverprice-Config-Version` triggers an unconditional fetch; failed event sends
re-queue purchases and drop exposures; a `400` is not retried; kill switch via option and env;
malformed secret key → `disabled` and one error; a throwing `onError` changes nothing;
`trackPurchase` reads attribution from metadata and converts seconds to milliseconds;
`ROOT_PUBLIC_KEYS` contains only valid 32-byte keys.

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

## 14. Packaging

| Language | Registry name | Import |
|---|---|---|
| JavaScript / TypeScript | npm `@leverprice/sdk`, JSR `@leverprice/sdk` | `import { Leverprice } from "@leverprice/sdk"` |
| Python ≥ 3.9 | PyPI `leverprice` | `from leverprice import Leverprice` |
| PHP ≥ 8.1 | Packagist `leverprice/leverprice-php` | `use Leverprice\Leverprice;` |
| Ruby ≥ 3.1 | RubyGems `leverprice` | `require "leverprice"` |
| Go ≥ 1.22 | `github.com/leverprice/leverprice-go` | `import "github.com/leverprice/leverprice-go"` |

All SDKs: MIT license, version `0.3.0` for this protocol revision, a README with the same sections as
the JS README (quick start for the main frameworks of that language, guarantees, requests and
cookies, exposures, bots, kill switch, outages, trust chain, reference), and a `CHANGELOG.md`.
