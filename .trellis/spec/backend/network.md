---
prefix: NET
applies_to:
  - lib/core/network/**
  - lib/core/auth/oauth_service.dart
  - lib/core/download/*transport*.dart
  - lib/core/image/image_worker_host.dart
  - lib/core/platform/local_network.dart
reviewed: 2026-10-14
---

# Network policy, auth and transfers

## Contents

- [Destinations and routes](#destinations-and-routes)
- [Failures and replay](#failures-and-replay)
- [Clients and diagnostics](#clients-and-diagnostics)
- [Segmented transfers](#segmented-transfers)

## Destinations and routes

### NET-01 Routes steer connections, never URLs
- **Rule:** A route changes only the TCP destination; the original URI
  keeps the `Host` header and certificate hostname verification (and SNI,
  except on the no-SNI tiers). The only URL rewrite is the user's image
  source, on image-purpose requests only.
- **Why:** Rewriting URLs to IPs or mirrors broke caching, Referer checks
  and certificate verification.
- **Check:** `test/restricted_compat_image_test.dart` "the factory only rewrites image-purpose requests" "a rewritten host missing from the registry fails loudly"
- **Code:** `lib/core/network/compat/pixiv_network_factory.dart`, `lib/core/network/compat/network_policy.dart`

### NET-02 Destinations are exact allowlisted hosts
- **Rule:** `PixivDestinationRegistry` accepts only exact ASCII HTTPS Pixiv
  hosts for their purpose; userinfo, fragments, IP literals, trailing dots,
  IDN input and non-443 ports are rejected before any request. Resolved
  candidates must be public addresses.
- **Why:** A suffix match would have sent tokens to `evil.pixiv.net`.
- **Check:** `test/restricted_compat_network_test.dart` "destination registry accepts only canonical Pixiv hosts and purposes" "policy rejects private addresses from an injected resolver"
- **Code:** `lib/core/network/compat/network_contracts.dart`

### NET-03 Tier order per destination group
- **Rule:** In automatic mode the cold order is:

  | Group | Order |
  |---|---|
  | API, OAuth, web (Cloudflare) | `ech`, `dohRealSni`, `direct` |
  | `i.pximg.net`, `s.pximg.net` | `ech`, `noSni`, `dohRealSni`, `direct`, `bootstrapNoSni` |
  | image mirrors (every mode) | `direct`, `noSni`, `dohRealSni` |

  `bootstrapNoSni` serves the pixiv image hosts only, is always last cold
  and never becomes a group preference; a failed fast address cools for
  30 s. Its address is the built-in one or the last one a `noSni` request
  was served from; a DoH answer is never stored unproven. Memory promotes
  the last successful kind per host and group, persisted per network
  identity as a kind, never an address. Only cold mirror image requests
  race two tiers; a raced tier that answers before the other is even
  selected wins without waiting. One request looks its host up once per
  network revision: a failed lookup is not repeated by later tiers or
  selections, and a network change mid-request looks it up again. A mirror's
  direct tier gets an 8 s connect budget (the fourth SYN), not the
  fast-fail 3 s.
- **Why:** Plain DNS and SNI are blocked or poisoned on the user's
  networks; a failed bootstrap address without a cooldown delayed every
  request. Pixiv's origin answers API, OAuth and web traffic that bypasses
  Cloudflare with 403, which the ladder took for a working route, and a
  DoH refresh stored Cloudflare addresses that reject a handshake without
  SNI. Mirrors went `noSni` first: the preset mirrors sit behind
  Cloudflare (no SNI, no handshake) and both other tiers waited on DoH,
  which the mainland could not reach, so an image took 24–40 s and hit
  the 15 s headers timeout; pixiv.re and pixiv.nl connect directly.
- **Check:** `test/restricted_compat_network_test.dart` "an empty GET prefers the strict tier over direct", `test/network_fast_route_test.dart` "a failed fast address is cooled before the next request" "API, OAuth and web never reach the bootstrap tier" "only a noSni success teaches the bootstrap tier an address", `test/restricted_compat_image_test.dart` "a cold API GET stays serial — racing is image-only" "a cold mirror answers from direct while DoH hangs", `test/restricted_compat_network_test.dart` "policy rejects private addresses from an injected resolver"
- **Code:** `lib/core/network/compat/network_policy.dart`, `lib/core/network/compat/network_policy_ladder.dart`, `lib/core/network/compat/rhttp_client_factory.dart`

### NET-04 Pixiv image hosts stay on ECH
- **Rule:** Pixiv image hosts start on ECH alone. One ECH failure moves
  only that request; two in a row cool ECH for 1 minute, doubling per
  failed retry up to 10. While cooling, a remembered stand-in tier goes
  first and ECH last. One ECH success or a network change clears the
  cooldown. Origin-tier successes are neither shared nor persisted.
- **Why:** Origin addresses answer faster but are throttled to tens of
  KB/s inside the wall.
- **Check:** `test/restricted_compat_image_test.dart` "a cold GET goes to ECH alone instead of racing" "the cooldown doubles after every failed retry, capped" "origin-tier successes are neither shared nor persisted"
- **Code:** `lib/core/network/compat/network_policy_ladder.dart`

### NET-05 Image and download exits use HTTP/1.1
- **Rule:** Image and download exits run HTTP/1.1, one connection per
  transfer, with a connect budget and an idle guard instead of a total
  timeout. Other exits negotiate through ALPN.
- **Why:** One shared HTTP/2 connection let a throttled flow stall every
  image.
- **Check:** `test/rhttp_client_factory_test.dart` "image exits use HTTP/1.1, every other exit negotiates" "streaming exits carry no total timeout"
- **Code:** `lib/core/network/compat/rhttp_client_factory.dart`

## Failures and replay

### NET-06 Only undelivered failures move to the next tier
- **Rule:** DNS, connect, reset and handshake failures may advance a
  request to the next tier, each tier tried at most once; GET and HEAD may
  also advance on timeout. A POST, the token exchange and any request with
  a body advance only when the failure proves nothing reached the server.
  HTTP answers, auth, parse, certificate and cancellation outcomes are
  surfaced, never re-sent.
- **Why:** Re-sending a bookmark POST after a timeout could apply it twice.
- **Check:** `test/restricted_compat_network_test.dart` "a timed-out POST is never replayed across routes" "HTTP, auth, certificate and cancellation responses do not fallback" "a refused token exchange moves on and is sent exactly once"
- **Code:** `lib/core/network/compat/network_policy_ladder.dart`

### NET-07 Certificates are always verified
- **Rule:** `RhttpClientFactory.settingsFor` is the only `TlsSettings`
  construction site and always verifies certificates, the no-SNI tiers
  included. A certificate mismatch is terminal.
- **Why:** A tier that works only without verification is reaching the
  wrong server.
- **Check:** `test/rhttp_client_factory_test.dart` "no route kind turns certificate verification off", `test/restricted_compat_image_test.dart` "a real-SNI certificate mismatch stays terminal"
- **Code:** `lib/core/network/compat/rhttp_client_factory.dart`

### NET-08 Refresh on 401 or 400 invalid_grant, once per account
- **Rule:** The token refreshes on 401, or on 400 whose body contains
  `invalid_grant`; a plain 400 never refreshes. Concurrent callers share
  one refresh per account. A POST replays its body after a refresh only
  when the caller sets `allowAuthReplay: true` (bookmark, follow, comment),
  and only once.
- **Why:** `/v1/illust/recommended` reports an expired token as 400
  `invalid_grant`; replaying arbitrary POST bodies is unsafe.
- **Check:** `test/pixiv_http_client_test.dart` "plain 400 without invalid_grant never triggers refresh" "opt-in POST surfaces a second 401 without another replay", `test/token_refresh_gate_test.dart` "20 concurrent callers share exactly one refresh per account"
- **Code:** `lib/core/network/pixiv_http_client.dart`

### NET-09 Rate limits pause reads, not writes
- **Rule:** A 429 maps to `ApiRateLimited` with its `Retry-After`; reads
  wait out the cooldown, posts still go.
- **Why:** Hammering the API after a 429 extended the block.
- **Check:** `test/pixiv_http_client_test.dart` "429 maps to rate limited with the retry-after hint" "after a 429 reads wait out the cooldown; posts still go"
- **Code:** `lib/core/network/pixiv_http_client.dart`

### NET-10 Identical GETs share one flight
- **Rule:** An uncancelled GET shares a flight in progress only when the
  URI and bearer token match; cancellable calls stay independent and no
  response is kept after completion.
- **Why:** Duplicate requests from several widgets doubled load; keeping
  responses would serve stale data to pull-to-refresh.
- **Check:** `test/pixiv_http_client_test.dart` "concurrent identical GETs share one transport flight"
- **Code:** `lib/core/network/pixiv_http_client.dart`

### NET-17 A blocked local address fails before connecting
- **Rule:** On Android 17 a host the user configured (custom image source,
  DoH override, LLM endpoint, system proxy) that resolves to the local
  network needs `ACCESS_LOCAL_NETWORK`. The app asks with the system
  dialog only then, once per set of hosts; while the dialog is up and
  while denied, the policy, the DoH resolver, the LLM transport and the
  login WebView (every load and reload) throw `LocalNetworkBlocked`
  without connecting, shown as `ErrorCategory.localNetwork`. Built-in
  hosts are public and never checked. Known gap: requests are not held
  back during the first check after settings load or change (channel
  calls plus a system DNS lookup, at most 3 s).
- **Why:** Without the permission a TCP connect to a local address hangs
  until it times out; the user decided on an immediate error and the
  system dialog, no in-app prompt.
- **Check:** `test/local_network_test.dart` "configured local hosts ask once; denied, none connects", `test/doh_resolver_test.dart` "a blocked local endpoint is skipped without a request"
- **Code:** `lib/core/platform/local_network.dart`, `lib/core/network/local_network_address.dart`, `android/app/src/main/kotlin/io/github/lopution/parfait/LocalNetworkChannel.kt`

## Clients and diagnostics

### NET-11 Pixiv traffic goes only through the policy stack
- **Rule:** Pixiv API and OAuth clients come from `PixivNetworkFactory`,
  Pixiv images from the image worker, downloads from
  `PolicyDownloadTransport`. Third-party traffic (translation, SauceNAO,
  updater) uses `thirdPartyHttpClientProvider` and never enters the Pixiv
  connector; DoH and probes use `resolverHttpClientProvider`.
- **Why:** Pixiv requests outside the policy failed on blocked networks;
  third-party hosts inside it were rejected by the registry.
- **Check:** `test/restricted_compat_network_test.dart` "API and download exits share one route ladder"
- **Code:** `lib/core/network/http_client_providers.dart`, `lib/core/network/compat/pixiv_network_factory.dart`

### NET-12 The image worker never persists routes
- **Rule:** The worker's own policy learns routes but sends them back to
  the main isolate's fast-route and route-kind stores, the only writers of
  those preferences.
- **Why:** Two isolates writing the same preferences overwrote each other.
- **Check:** manual
- **Code:** `lib/core/image/image_worker_host.dart`, `lib/core/network/compat/route_kind_store.dart`

### NET-13 Diagnostics and errors carry no secrets
- **Rule:** Route diagnostics hold host, purpose, route, DNS source, IP
  family, failure, latency and revision only: no query strings, cookies,
  tokens, bodies or full addresses. Error details are clamped body
  snippets without credentials. A DNS disagreement is secondary evidence
  when ECH or empty-SNI worked.
- **Why:** Diagnostics are copied into bug reports.
- **Check:** `test/restricted_compat_network_test.dart` "diagnostics contain route metadata but no URL or credential material", `test/pixiv_http_client_test.dart` "error objects never embed tokens or authorization material", `test/network_probe_test.dart` "DNS discrepancy does not hide a working ECH transport"
- **Code:** `lib/core/network/compat/network_probe.dart`, `lib/core/network/api_error.dart`

### NET-14 Protocol tests use checked-in bytes
- **Rule:** DNS and TLS parser tests use repository-owned bytes or a
  fixture builder; they never read machine-local captures or the network.
- **Why:** Tests that read a local capture passed only on one machine.
- **Check:** `test/doh_resolver_test.dart`
- **Code:** `lib/core/network/compat/dns_message.dart`

## Segmented transfers

### NET-15 Ranges stitch only the same file
- **Rule:** Large originals and downloads continue in parallel ranges only
  from a first 206 carrying the total. Every later range sends `If-Range`
  with the first ETag; a range that is not exactly its 206 fails the whole
  transfer with `SegmentedFetchMismatch`, never retried. Extra connections
  come from the isolate's `SegmentBudget` (main isolate one provider,
  limit 6; image worker its own, limit 3).
- **Why:** Stitching a mismatched range mixed two files; per-factory
  budgets multiplied connections per host.
- **Check:** `test/segmented_fetch_test.dart` "every segment asks If-Range with the first ETag" "a budget of 2 caps the transfer at 3 connections" "cancelling closes every connection and returns the budget"
- **Code:** `lib/core/network/compat/segmented_fetch.dart`

### NET-16 Slow ranges restart a bounded number of times
- **Rule:** A range restarts from the byte it reached after 5 s without
  bytes, or when it streams under a third of the median pace; at most
  `maxRestarts` per range. Teardown uses `subscription.cancel().ignore()`
  before closing the response.
- **Why:** One slow CDN connection set the pace; awaiting `cancel()` never
  settled under `fakeAsync` and surfaced teardown errors as uncaught.
- **Check:** `test/segmented_fetch_test.dart` "a slow segment restarts from the byte it reached" "a segment restarts at most twice, then waits"
- **Code:** `lib/core/network/compat/segmented_fetch.dart`
