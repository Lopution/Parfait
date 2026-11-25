---
prefix: NET
applies_to:
  - lib/core/network/**
  - lib/core/auth/oauth_service.dart
  - lib/core/download/*transport*.dart
  - lib/core/image/image_worker_host.dart
  - lib/core/platform/local_network.dart
  - lib/core/platform/network_identity.dart
  - lib/core/settings/image_mirror.dart
reviewed: 2026-11-21
---

# Network policy, auth and transfers

## Contents

- [Destinations and routes](#destinations-and-routes)
- [Failures and replay](#failures-and-replay)
- [Clients and diagnostics](#clients-and-diagnostics)
- [Continued transfers](#continued-transfers)

## Destinations and routes

### NET-01 Routes steer connections, never URLs
- **Rule:** A route changes only the TCP destination; the original URI keeps `Host`, certificate hostname verification, and SNI (except on no-SNI tiers). The only URL rewrite is the user's image source on image-purpose requests.
- **Why:** Rewriting URLs to IPs or mirrors broke caching, Referer checks, and TLS verification.
- **Check:** `test/restricted_compat_image_test.dart` "the factory only rewrites image-purpose requests" "a rewritten host missing from the registry fails loudly"
- **Code:** `lib/core/network/compat/pixiv_network_factory.dart`, `lib/core/network/compat/network_policy.dart`

### NET-02 Destinations are exact allowlisted hosts
- **Rule:** `PixivDestinationRegistry` accepts only exact ASCII HTTPS Pixiv hosts for their purpose (rejecting userinfo, fragments, IP literals, trailing dots, IDN, non-443 ports, and non-public resolved addresses). An image source's allowlist covers every host it rewrites to, including each auto winner's `s.` host.
- **Why:** Suffix matching would leak tokens; omitting `s.` hosts blocked rewritten avatars.
- **Check:** `test/restricted_compat_network_test.dart` "destination registry accepts only canonical Pixiv hosts and purposes" "policy rejects private addresses from an injected resolver", `test/image_mirror_test.dart` "every winner rewrites to hosts the auto allowlist admits"
- **Code:** `lib/core/network/compat/network_contracts.dart`, `lib/core/settings/image_mirror.dart`

### NET-03 Tier order per destination group
- **Rule:** Cold automatic order is: API/OAuth/web `ech` → `dohRealSni` → `direct`; `i.pximg.net`/`s.pximg.net` scored candidates (NET-04) → `dohRealSni` → `direct` (`bootstrapNoSni` serves only Pixiv image hosts as `origin`); image mirrors `direct` (8 s connect budget) → `noSni` → `dohRealSni`. Last working kind persists per network identity (except Pixiv image hosts). Only cold mirror image loads race two tiers (failing legs yield to the next; terminal failures end racing). One request looks up its host once per network revision; concurrent DoH/ECH lookups share one wire query, and a caller's cancel ends only its wait.
- **Why:** Plain DNS/SNI is blocked on mainland networks; Pixiv's origin 403s non-Cloudflare API traffic; mirrors behind Cloudflare reject no-SNI handshakes while direct connects cleanly.
- **Check:** `test/restricted_compat_network_test.dart` "an empty GET prefers the strict tier over direct" "a network change mid-request looks the host up again" "policy rejects private addresses from an injected resolver", `test/network_fast_route_test.dart` "API, OAuth and web never reach the bootstrap tier", `test/restricted_compat_image_test.dart` "a cold API GET stays serial — racing is image-only" "a cold mirror answers from direct while DoH hangs" "a raced tier that fails gives its place to the next while the " "a real-SNI certificate mismatch stays terminal", `test/doh_resolver_test.dart` "concurrent address lookups share one wire query; a cancel ends " "concurrent ECH lookups share one wire query, cancellable or "
- **Code:** `lib/core/network/compat/network_policy.dart`, `lib/core/network/compat/network_policy_ladder.dart`, `lib/core/network/compat/rhttp_client_factory.dart`

### NET-04 Pixiv image routes follow per-network scores
- **Rule:** Pixiv image hosts rank up to four `ech:<front>` candidates (NET-20) plus `origin` (built-in ten + NET-21 proven addresses), then `dohRealSni` and `direct`. Body cost is seconds/100 KB (12 s for stall/failure/5xx; aborted loads count as stalls only past 2.5 s without headers or 2 s without body bytes via `ImageStall`). Samples halve weight every 10 min (cap 6); switching requires 15% lower cost. Only prefetches probe one stale candidate at a time. Scoreboards persist per network identity (last 16 networks, 8 candidates); UI displays "Cloudflare n · colo" or origin, never raw IPs (NET-13).
- **Why:** Best routes invert across carriers; first-byte races miss stalled bodies.
- **Check:** `test/image_route_scores_test.dart` "visible loads settle on a good route within six and stay there" "a route that turns slow loses the choice within minutes" "another route takes over only when 15 % cheaper" "prefetches explore one stale route at a time, visible loads never" "a snapshot seeds the next visit to the network", `test/restricted_compat_image_test.dart` "pixiv images walk their candidates, then dohRealSni and direct, " "a stalled body counts against its route; one given up does " "a body given up after a stall counts against its route" "a request aborted with no headers after the stall gap counts " "a prefetch may try another route; a visible load never" "a network starts on the route that served it last time", `test/settings_test.dart` "effective routes list the image worker's hosts and route ", `test/network_fast_route_test.dart` "a failed origin address gives way to the next, where the next "
- **Code:** `lib/core/network/compat/image_route_scores.dart`, `lib/core/network/compat/image_route_score_store.dart`, `lib/core/network/compat/network_policy.dart`, `lib/core/network/compat/network_policy_idle_guard.dart`, `lib/core/network/compat/network_policy_ladder.dart`

### NET-20 Each network finds its own Cloudflare fronts
- **Rule:** Beyond ECH config hints, each network keeps extra Cloudflare fronts (4 `ech:` total; seed `162.159.152.4` initially). `FrontDiscovery` runs in the image worker only while idle (after 20 samples or when all sampled fronts cost >= 1.5x best or fail > 30%, min 6 h backoff up to 48 h), probing 8 addresses across 15 prefixes (10 s each, verified `cdn-cgi/trace` + thumbnail) and keeping the best two (< 0.8x cost or new colo <= 1.2x). Failed fronts cool down 24 h; fronts >= 1.5x for a day drop. Results persist per network via the main isolate (NET-12).
- **Why:** Anycast colo varies by carrier and prefix; every front must prove it serves real images without 403/stalls.
- **Check:** `test/route_discovery_test.dart` "a run keeps the two fronts that beat the hints or add a colo, " "a front worse than the best other for a day is dropped; a better " "a discovery survives a restart and seeds a new worker" "the sample spreads over Cloudflare" "a run is due"
- **Code:** `lib/core/network/compat/front_discovery.dart`, `lib/core/network/compat/image_route_discovery.dart`, `lib/core/image/image_worker_host.dart`

### NET-21 Pixiv's origin addresses follow encrypted DNS
- **Rule:** At most once daily while idle, `OriginRefresh` queries `i.pximg.net` via DoH (never system DNS), proves each new public IP with a verified empty-SNI image GET (10 s), keeps up to ten, and drops addresses DNS no longer lists. Visible loads pause probing and resume later without re-querying. Proven addresses failing three loads without a full response cool down for 24 h (reset on network/setting change); built-in addresses never cool down. Results sync to the main isolate's fast-route store (NET-12).
- **Why:** Origin IPs rotate between releases while mainland system DNS poisons them.
- **Check:** `test/route_discovery_test.dart` "it keeps the address DNS names that serves an image, ignores " "a proven address from a new worker" "the worker sends its proven origins home, and a config sent " "a visible image arriving mid-refresh stops it before the next " "a whole image from a proven address between its failures starts "
- **Code:** `lib/core/network/compat/origin_refresh.dart`, `lib/core/network/compat/network_fast_route_store.dart`, `lib/core/network/compat/network_policy.dart`

### NET-19 A network is its carrier or its link
- **Rule:** Network identity keys route memory, scoreboards, and auto image source. On Android it tracks the default network callback on the main looper (`mobile:<MCC+MNC>`, `wifi:<hash>` of IPv6 /32 or gateways+DNS, `vpn`, `none`, or bare `wifi`/`mobile`); elsewhere it uses `connectivity_plus`. Every identity change (including data-SIM switches) advances the network revision.
- **Why:** Collapsing all carriers into `mobile` mixed opposite route winners.
- **Check:** `android/app/src/test/kotlin/io/github/lopution/parfait/NetworkIdentityChannelTest.kt` "the kind and the data SIM's operator name the network" "a local link is named by its provider's IPv6 block, else by its router", `test/restricted_compat_network_test.dart` "on Android a data-SIM switch is a network change" "on Windows a failed first look still follows network changes"
- **Code:** `android/app/src/main/kotlin/io/github/lopution/parfait/NetworkIdentityChannel.kt`, `lib/core/platform/network_identity.dart`, `lib/core/network/compat/network_providers.dart`

### NET-22 The auto source measures each network rarely
- **Rule:** Auto image-source mode applies the network's remembered winner immediately. Missing winners race immediately; winners older than 24 h (or without timestamp) race once 30 s after seeing the network, replacing the winner only if >= 1/0.85x faster or the winner failed. A winner failing all tiers falls back to direct and races immediately (or after 30 s cooldown). Network changes cancel pending races and discard cross-network results.
- **Why:** Racing on every launch stalled the first screen with cold ECH lookups and flipped sources across launches.
- **Check:** `test/restricted_compat_image_test.dart` "no winner remembered: the race runs at once and applies; an " "a stale winner applies at once, races after the deferral and " "a race replaces a winner it beats by 15 % or that failed" "a network change drops the old network's pending race; a " "the winner persists scoped to the network identity"
- **Code:** `lib/core/network/compat/auto_image_source.dart`, `lib/core/network/compat/network_providers.dart`

### NET-05 Image and download exits use HTTP/1.1
- **Rule:** Image and download exits use HTTP/1.1 (one connection per transfer, connect budget + idle guard, no total timeout); other exits negotiate ALPN. Idle timeouts propagate to post-`listen` handlers (so `drain()` ends on stalls), survive non-terminal errors, and forward unhandled errors to the listener's zone. Headers timeout, idle timeout, or reader cancel aborts the underlying request; raced losers drain with errors ignored.
- **Why:** Shared HTTP/2 connections suffered head-of-line stalls, and un-aborted stalled bodies leaked rhttp sockets.
- **Check:** `test/rhttp_client_factory_test.dart` "image exits use HTTP/1.1, every other exit negotiates" "streaming exits carry no total timeout", `test/restricted_compat_image_test.dart` "send() surfaces a headers timeout for image clients, aborting" "the response body errors after an idle gap" "a body that errs and goes on still times out" "an idle timeout nobody handles reaches the zone" "an abandoned body aborts its request"
- **Code:** `lib/core/network/compat/rhttp_client_factory.dart`

## Failures and replay

### NET-06 Only undelivered failures move to the next tier
- **Rule:** DNS, connect, reset, and handshake failures advance tiers (each tried once); GET/HEAD also advance on timeout. POST, token exchange, and requests with bodies advance only when nothing reached the server. HTTP answers, auth, parse, certificate, and cancellation outcomes never replay.
- **Why:** Replaying a timed-out POST risks duplicate server mutations.
- **Check:** `test/restricted_compat_network_test.dart` "a timed-out POST is never replayed across routes" "HTTP, auth, certificate and cancellation responses do not fallback" "a refused token exchange moves on and is sent exactly once"
- **Code:** `lib/core/network/compat/network_policy_ladder.dart`

### NET-07 Certificates are always verified
- **Rule:** `RhttpClientFactory.settingsFor` is the sole `TlsSettings` constructor and always verifies certificates (including no-SNI tiers); mismatches are terminal.
- **Why:** Bypassing verification masks hijacked routes.
- **Check:** `test/rhttp_client_factory_test.dart` "no route kind turns certificate verification off", `test/restricted_compat_image_test.dart` "a real-SNI certificate mismatch stays terminal"
- **Code:** `lib/core/network/compat/rhttp_client_factory.dart`

### NET-08 Refresh on 401 or 400 invalid_grant, once per account
- **Rule:** Refresh runs on 401 or 400 containing `invalid_grant` (never plain 400), coalesced per account. POST replays once after refresh only when `allowAuthReplay: true` (bookmark, follow, comment). Requests stay bound to their starting account across switches; removed/signed-out accounts never refresh.
- **Why:** `/v1/illust/recommended` returns 400 `invalid_grant` on expiry; unpinned requests replayed Account A writes with Account B tokens.
- **Check:** `test/pixiv_http_client_test.dart` "plain 400 without invalid_grant never triggers refresh" "opt-in POST surfaces a second 401 without another replay" "a request keeps its account through a switch, its refresh too", `test/token_refresh_gate_test.dart` "20 concurrent callers share exactly one refresh per account"
- **Code:** `lib/core/network/pixiv_http_client.dart`

### NET-09 Rate limits pause reads, not writes
- **Rule:** 429 maps to `ApiRateLimited` with `Retry-After`; reads respect the cooldown scoped per `accountId` while writes still proceed.
- **Why:** Hammering reads after 429 extended bans; global cooldowns blocked switched accounts.
- **Check:** `test/pixiv_http_client_test.dart` "429, server, parse and transport failures map to errors, no retry" "after a 429 reads wait out the cooldown; posts still go" "a 429 cooldown scopes to the rate-limited account across switches"
- **Code:** `lib/core/network/pixiv_http_client.dart`

### NET-10 Identical GETs share one flight
- **Rule:** Uncancelled GETs coalesce only when URI and bearer token match; cancellable calls stay independent and responses are never cached post-completion.
- **Why:** Simultaneous widget mounts doubled load while response caching would break pull-to-refresh.
- **Check:** `test/pixiv_http_client_test.dart` "concurrent identical GETs share one transport flight"
- **Code:** `lib/core/network/pixiv_http_client.dart`

### NET-17 A blocked local address fails before connecting
- **Rule:** On Android 17, user-configured hosts resolving to local networks request `ACCESS_LOCAL_NETWORK` via the system dialog once per host set; while pending or denied, policy, DoH, ECH, LLM, and login WebView fail immediately with `LocalNetworkBlocked` (`ErrorCategory.localNetwork`) without connecting. DoH and ECH endpoints also require HTTPS without userinfo or loopback/localhost hosts and enforce `blockedHosts` on both DoH and ECH queries before sending. Built-in hosts are never checked. Known gap: requests are not held back while the first check after settings load or change runs (at most 3 s).
- **Why:** User decision: fail immediately with the system permission dialog rather than hanging until TCP timeout; unvalidated DoH/ECH overrides could downgrade DNS to HTTP or probe loopback/blocked local hosts.
- **Check:** `test/local_network_test.dart` "configured local hosts ask once; denied, none connects", `test/doh_resolver_test.dart` "a blocked local endpoint is skipped without a request" "rejects http, userinfo, and loopback endpoints and blocks ECH hosts"
- **Code:** `lib/core/platform/local_network.dart`, `lib/core/network/local_network_address.dart`, `lib/core/network/compat/secure_resolver.dart`, `lib/core/settings/network_endpoint_validation.dart`, `android/app/src/main/kotlin/io/github/lopution/parfait/LocalNetworkChannel.kt`

### NET-18 A cancelled body's late error is dropped
- **Rule:** The image idle guard drops late cancel errors from rhttp streams and resolves `cancel()` immediately without waiting on Rust; any other rhttp body cancel wraps `cancel()` in `try` or `.ignore()`, never `unawaited`.
- **Why:** Uncaught late `AnyhowException` killed the image worker isolate and delayed stall detection by 15–30 s.
- **Check:** `test/restricted_compat_image_test.dart` "a body error after the idle timeout is dropped" "a cancel completes though the body errs after it" "a mapped body errors after an idle gap though its cancel waits"
- **Code:** `lib/core/network/compat/network_policy.dart`, `lib/core/network/compat/network_policy_idle_guard.dart`

## Clients and diagnostics

### NET-11 Pixiv traffic goes only through the policy stack
- **Rule:** Pixiv API/OAuth use `PixivNetworkFactory`, images use the image worker, downloads use `PolicyDownloadTransport`; third-party services use `thirdPartyHttpClientProvider`; DoH and probes use `resolverHttpClientProvider`.
- **Why:** Bypassing the policy broke blocked networks; third-party hosts inside it failed registry checks.
- **Check:** `test/restricted_compat_network_test.dart` "API and download exits share one route ladder"
- **Code:** `lib/core/network/http_client_providers.dart`, `lib/core/network/compat/pixiv_network_factory.dart`

### NET-12 The image worker never persists routes
- **Rule:** The worker reports learned routes, score samples, range marks, and discoveries tagged with their network identity back to the main isolate (sole preference writer); worker configs seed new workers, with fresh worker discoveries outranking stale config.
- **Why:** Cross-isolate preference writes clobbered each other; main-isolate downloads reuse worker-learned routes.
- **Check:** `test/image_worker_host_test.dart` "route samples go back to the main isolate under their network", `test/route_discovery_test.dart` "the worker sends its discoveries home, and a config sent before "
- **Code:** `lib/core/image/image_worker_host.dart`, `lib/core/image/image_worker_providers.dart`, `lib/core/network/compat/route_kind_store.dart`, `lib/core/network/compat/image_route_score_store.dart`

### NET-13 Diagnostics and errors carry no secrets
- **Rule:** Route diagnostics carry only host, purpose, route, DNS source, IP family, failure, latency, and revision (no queries, cookies, tokens, bodies, or full IPs). Error details clamp body snippets without credentials; DNS discrepancies stay secondary when ECH/no-SNI succeeds.
- **Why:** Diagnostics are pasted into public bug reports.
- **Check:** `test/restricted_compat_network_test.dart` "diagnostics contain route metadata but no URL or credential material", `test/pixiv_http_client_test.dart` "error objects never embed tokens or authorization material", `test/network_probe_test.dart` "DNS discrepancy does not hide a working ECH transport"
- **Code:** `lib/core/network/compat/network_probe.dart`, `lib/core/network/api_error.dart`

### NET-14 Protocol tests use checked-in bytes
- **Rule:** DNS and TLS parser tests use repository-owned fixtures or builders, never local captures or live network calls.
- **Why:** Machine-local captures break CI and other checkouts.
- **Check:** `test/doh_resolver_test.dart` "resolves a host to its public address via DoH wire format" "TTL is clamped to the configured bounds"
- **Code:** `lib/core/network/compat/dns_message.dart`

## Continued transfers

### NET-15 A continuation appends only the same file
- **Rule:** Originals and downloads run one connection at a time (`bytes=N-`; only 206 with total continues, while an initial 200 is consumed as a complete file). Continuations send `If-Range` with the first ETag and require 206 matching offset and total (else terminal `ContinuedFetchMismatch`). A 200 to a continuation requested without `If-Range` marks the candidate as range-ignoring per network and retries elsewhere without consuming its bytes. All ranges of a transfer share one `ImageRoutePin`.
- **Why:** Mismatched ranges corrupted files, and parallel range splitting lost to single-connection streaming on every measured network.
- **Check:** `test/continued_fetch_test.dart` "every continuation asks If-Range with the first ETag" " fails the transfer without appending or a retry" "a 200 to a continuation without If-Range is asked again elsewhere; " "streams " "cancelling closes the live connection", `test/restricted_compat_image_test.dart` "every range of a transfer keeps to the route of its first" "a resumed transfer tries last a route that sent a whole file ", `test/download_resume_test.dart` "a large file arrives on one connection, in order" "a retry after pause continues from the anchor", `test/image_worker_host_test.dart` "arrives whole on one range request, its progress against the "
- **Code:** `lib/core/network/compat/continued_fetch.dart`, `lib/core/network/compat/network_policy_ladder.dart`, `lib/core/download/download_manager.dart`, `lib/core/download/download_manager_adapters.dart`, `lib/core/image/image_worker_host.dart`

### NET-16 A stopped connection continues from its received byte
- **Rule:** On `ImageStall.body`/`ImageStall.headers`, error, or early EOF (paused readers excluded), the transfer closes and continues from its received byte up to `ContinuedFetch.defaultContinuations` times. Consecutive zero-byte stops switch routes via `ImageRoutePin.awayFrom`. Past the bound, normal idle timeout ends the transfer as a transport failure (preserving download resume anchors). Teardown uses `subscription.cancel().ignore()` before closing.
- **Why:** Waiting 15 s on stalled connections failed recoverable loads; awaiting `cancel()` hung `fakeAsync` and surfaced teardown errors.
- **Check:** `test/continued_fetch_test.dart` "a stalled body continues from the received byte after 2 s; " "a dropped connection continues on the same route" "continuations stop at the bound, then " "a paused reader is not a stall; resuming finishes", `test/download_resume_test.dart` "a dropped connection continues from the received byte, on the " "network failure preserves bytes; retry resumes", `test/image_worker_host_test.dart` "a dropped connection continues from its received byte on the ", `test/restricted_compat_image_test.dart` "a restarted range goes to another candidate that serves ranges, "
- **Code:** `lib/core/network/compat/continued_fetch.dart`, `lib/core/network/compat/network_policy_ladder.dart`
