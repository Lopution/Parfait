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
reviewed: 2026-10-29
---

# Network policy, auth and transfers

## Contents

- [Destinations and routes](#destinations-and-routes)
- [Failures and replay](#failures-and-replay)
- [Clients and diagnostics](#clients-and-diagnostics)
- [Continued transfers](#continued-transfers)

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
  candidates must be public addresses. An image source's allowlist holds
  every host it rewrites to; the auto source's holds each candidate and
  its preset's `s.` host, whichever wins.
- **Why:** A suffix match would have sent tokens to `evil.pixiv.net`. The
  auto allowlist once held only the `i.` hosts, so avatars rewritten to
  a winner's `s.` host were refused.
- **Check:** `test/restricted_compat_network_test.dart` "destination registry accepts only canonical Pixiv hosts and purposes" "policy rejects private addresses from an injected resolver", `test/image_mirror_test.dart` "every winner rewrites to hosts the auto allowlist admits"
- **Code:** `lib/core/network/compat/network_contracts.dart`, `lib/core/settings/image_mirror.dart`

### NET-03 Tier order per destination group
- **Rule:** In automatic mode the cold order is:

  | Group | Order |
  |---|---|
  | API, OAuth, web (Cloudflare) | `ech`, `dohRealSni`, `direct` |
  | `i.pximg.net`, `s.pximg.net` | route candidates by score (NET-04), `dohRealSni`, `direct` |
  | image mirrors (every mode) | `direct`, `noSni`, `dohRealSni` |

  `bootstrapNoSni` serves the pixiv image hosts only, as their `origin`
  candidate. Memory promotes the last successful kind per host and group
  except on pixiv's image hosts, persisted per network identity as a kind,
  never an address. Only cold mirror image requests
  race two tiers; a raced tier that answers before the other is even
  selected wins without waiting, and one that fails gives its place to the
  next tier, so two stay in flight until one answers or the tiers run out.
  A terminal failure (NET-06, NET-07) brings in no further tier and drops
  one already brought in. One request looks its host up once per
  network revision: a failed lookup is not repeated by later tiers or
  selections, and a network change mid-request looks it up again.
  Concurrent DoH lookups of one host (address or ECH config) on one
  revision share one query, cancellable or not; a caller's cancel ends
  only its own wait. A mirror's
  direct tier gets an 8 s connect budget (the fourth SYN), not the
  fast-fail 3 s.
- **Why:** Plain DNS and SNI are blocked or poisoned on the user's
  networks. Pixiv's origin answers API, OAuth and web traffic that bypasses
  Cloudflare with 403, which the ladder took for a working route, and a
  DoH refresh stored Cloudflare addresses that reject a handshake without
  SNI. Mirrors went `noSni` first: the preset mirrors sit behind
  Cloudflare (no SNI, no handshake) and both other tiers waited on DoH,
  which the mainland could not reach, so an image took 24–40 s and hit
  the 15 s headers timeout; pixiv.re and pixiv.nl connect directly.
  i.pixiv.re refuses the no-SNI handshake in 0.6 s, and the race then
  waited on its direct leg alone for 3–15 s while `dohRealSni` answered in
  1 s, and the slow direct was remembered. Every image request carries a
  cancel signal, so the first screen sent eight ECH queries at once.
- **Check:** `test/restricted_compat_network_test.dart` "an empty GET prefers the strict tier over direct" "a network change mid-request looks the host up again", `test/network_fast_route_test.dart` "API, OAuth and web never reach the bootstrap tier", `test/restricted_compat_image_test.dart` "a cold API GET stays serial — racing is image-only" "a cold mirror answers from direct while DoH hangs" "a raced tier that fails gives its place to the next while the " "a real-SNI certificate mismatch stays terminal", `test/restricted_compat_network_test.dart` "policy rejects private addresses from an injected resolver", `test/doh_resolver_test.dart` "concurrent address lookups share one wire query; a cancel ends " "concurrent ECH lookups share one wire query, cancellable or "
- **Code:** `lib/core/network/compat/network_policy.dart`, `lib/core/network/compat/network_policy_ladder.dart`, `lib/core/network/compat/rhttp_client_factory.dart`

### NET-04 Pixiv image routes follow per-network scores
- **Rule:** Pixiv's image hosts have route candidates: `ech:<front>` for
  up to four Cloudflare fronts (NET-20), and `origin`, pixiv's image
  origin at the host's current
  address (ten built in, plus those NET-21 proves; a failed one gives way
  to the next, a served one is persisted). A request tries each once, cheapest expected cost first,
  then `dohRealSni` and `direct`. Costs come from the image bodies:
  seconds per 100 KB; 12 s for a stall, a failure or a 5xx. A request
  given up is a stall after 2.5 s without headers or 2 s without body
  bytes (`ImageStall`), else costs nothing. Samples halve in weight every 10 min and
  weigh at most 6 together; another candidate takes over only when 15 %
  cheaper. A prefetch may go first to one candidate without a sample in
  10 min, one at a time; a visible load never does. Each network identity
  has its own board, seeded from what that network scored before (the
  last 16 networks, 8 candidates each). The network page lists the
  worker's current candidates as "Cloudflare n · colo" or the origin, with
  cost, failure share and the one in use; never an address (NET-13).
- **Why:** On one carrier the fronts the ECH config names stalled half the
  bodies while the seed front and the origin served; on another the
  origin crawled at 25 KB/s while every front served. Each fixed order
  was wrong on one of them, and a first-byte race says nothing of the
  body.
- **Check:** `test/image_route_scores_test.dart` "visible loads settle on a good route within six and stay there" "a route that turns slow loses the choice within minutes" "another route takes over only when 15 % cheaper" "prefetches explore one stale route at a time, visible loads never" "a snapshot seeds the next visit to the network", `test/restricted_compat_image_test.dart` "pixiv images walk their candidates, then dohRealSni and direct, " "a stalled body counts against its route; one given up does " "a body given up after a stall counts against its route" "a request aborted with no headers after the stall gap counts " "a prefetch may try another route; a visible load never" "a network starts on the route that served it last time", `test/settings_test.dart` "effective routes list the image worker's hosts and route ", `test/network_fast_route_test.dart` "a failed origin address gives way to the next, where the next "
- **Code:** `lib/core/network/compat/image_route_scores.dart`, `lib/core/network/compat/image_route_score_store.dart`, `lib/core/network/compat/network_policy.dart`, `lib/core/network/compat/network_policy_ladder.dart`

### NET-20 Each network finds its own Cloudflare fronts
- **Rule:** After the up to three public fronts the ECH config names, each
  network identity has extra fronts, four `ech:` in all: the seed
  162.159.152.4 until a run replaces it. A run (`FrontDiscovery`, image
  worker) samples 8 addresses across the 15 built-in Cloudflare IPv4
  prefixes by size and, one at a time, 10 s each, only while no visible
  image waits, fetches `cdn-cgi/trace` (`colo=`) and a thumbnail over ECH
  through each, certificates verified, unscored. It keeps the two best
  under 0.8 × the best Cloudflare candidate's cost, or in a new colo
  within 1.2 ×; a failed address is skipped for a day. A run starts after
  20 samples on a network with no run, or when every sampled Cloudflare
  candidate costs 1.5 × the best other or fails over 30 % of two loads or
  more; 6 h apart at least, doubled after each run that kept nothing (up
  to 48 h). A front at 1.5 × the best other for a day is dropped. A front
  in use gets one trace a day for its colo label. Results reach the main
  isolate like samples (NET-12) and persist per network.
- **Why:** The colo a front reaches differs by carrier and prefix: the
  ECH config's fronts land in LAX, which stalls pixiv's bodies for
  Unicom, while the seed lands in HKG there and in SJC for Telecom. Some
  Cloudflare addresses refuse or answer 403, so each is proven by a real
  image.
- **Check:** `test/route_discovery_test.dart` "a run keeps the two fronts that beat the hints or add a colo, " "a front worse than the best other for a day is dropped; a better " "a discovery survives a restart and seeds a new worker" "the sample spreads over Cloudflare" "a run is due"
- **Code:** `lib/core/network/compat/front_discovery.dart`, `lib/core/network/compat/image_route_discovery.dart`, `lib/core/image/image_worker_host.dart`

### NET-21 Pixiv's origin addresses follow encrypted DNS
- **Rule:** At most once a day, on an image sample while no visible
  image waits, the image worker's `OriginRefresh` asks the policy's DoH
  resolver for `i.pximg.net` (never system DNS). Each public address it
  names beyond the built-in ten and those already proven gets one image
  GET over the empty-SNI route, 10 s, certificates verified; those that
  answer 200 with a body are kept (at most ten), and a kept address DNS
  no longer names is dropped. A failed lookup counts as the day's ask. A
  visible image arriving mid-refresh stops it before the next probe; the
  next idle sample probes the rest of the same answer without asking
  again. The origin book of each image host is the address served last,
  the kept ones, then the built-in ten. A kept address that fails three
  loads (a refusal, a broken body or a 5xx) without a whole response
  body between (a range's counts) is skipped for a day, across new books a refresh makes, or until the
  network or the network settings (mode, DoH) change, which start every
  route afresh; a built-in one never is. Results reach the main isolate's
  fast-route store like learned routes (NET-12).
- **Why:** Pixiv's image addresses change without a release; mainland
  resolvers poison them, so only encrypted DNS is asked and every
  address is proven before it is used.
- **Check:** `test/route_discovery_test.dart` "it keeps the address DNS names that serves an image, ignores " "a proven address from a new worker" "the worker sends its proven origins home, and a config sent " "a visible image arriving mid-refresh stops it before the next " "a whole image from a proven address between its failures starts "
- **Code:** `lib/core/network/compat/origin_refresh.dart`, `lib/core/network/compat/network_fast_route_store.dart`, `lib/core/network/compat/network_policy.dart`

### NET-19 A network is its carrier or its link
- **Rule:** The network identity keys route memory, image route scores
  and the auto source. On Android it follows the default network's
  callback on the main looper: `mobile:<MCC+MNC>` of the default data
  SIM; `wifi:<hash>` over the first four bytes of the link's global IPv6
  address, else over its gateways and DNS servers; `vpn`; `none`; plain
  `wifi` or `mobile` when the facts are missing. Elsewhere it is the
  `connectivity_plus` kinds. Every new identity advances the network
  revision, a data-SIM switch included.
- **Why:** `connectivity_plus` named every cellular network `mobile`, so
  two carriers whose best image routes are opposite shared one memory.
- **Check:** `android/app/src/test/kotlin/io/github/lopution/parfait/NetworkIdentityChannelTest.kt` "the kind and the data SIM's operator name the network" "a local link is named by its provider's IPv6 block, else by its router", `test/restricted_compat_network_test.dart` "on Android a data-SIM switch is a network change" "on Windows a failed first look still follows network changes"
- **Code:** `android/app/src/main/kotlin/io/github/lopution/parfait/NetworkIdentityChannel.kt`, `lib/core/platform/network_identity.dart`, `lib/core/network/compat/network_providers.dart`

### NET-22 The auto source measures each network rarely
- **Rule:** In auto image-source mode the winner remembered for a network
  identity (NET-19) applies as soon as the network is seen, with the time
  it was measured. With none, the candidates race at once and the best
  applies. One measured within 24 h is not raced; an older one, or one
  stored without a time, is raced once 30 s after the network is seen. A
  race replaces the winner in use only when its best candidate moved at
  least 1/0.85 of that winner's bytes per second in the same race, or the
  winner failed in it; a kept winner counts as measured then. A winner
  whose every tier failed drops to direct and the candidates race at once,
  30 s apart at least. A network change cancels the old network's pending
  race, and a result measured on another network is dropped.
- **Why:** Every launch raced and applied one sample per candidate during
  the first screen: the race paid a cold ECH lookup for pixiv's host, the
  source flipped between two launches on one network, and the images sent
  to the old source held five of the eight lanes for 21–23 s.
- **Check:** `test/restricted_compat_image_test.dart` "no winner remembered: the race runs at once and applies" "a stale winner applies at once, races after the deferral and " "a race replaces a winner it beats by 15 % or that failed" "a network change drops the old network's pending race; a " "the winner persists scoped to the network identity"
- **Code:** `lib/core/network/compat/auto_image_source.dart`, `lib/core/network/compat/network_providers.dart`

### NET-05 Image and download exits use HTTP/1.1
- **Rule:** Image and download exits run HTTP/1.1, one connection per
  transfer, with a connect budget and an idle guard instead of a total
  timeout. Other exits negotiate through ALPN. The idle timeout reaches
  handlers set after `listen`, so `drain()` on a stalled body ends; an
  error that does not end the body keeps its idle budget, and an error
  without a handler goes to the listener's zone. A raced loser's body is
  drained with its errors ignored. A headers timeout, an idle timeout or a
  reader cancelling the body fires the request's abort trigger.
- **Why:** One shared HTTP/2 connection let a throttled flow stall every
  image. `drain()` once waited forever on a stalled body. rhttp ends a
  transfer only on its abort, an error or the server's next bytes: a
  dropped stalled body kept its socket after its lane was freed.
- **Check:** `test/rhttp_client_factory_test.dart` "image exits use HTTP/1.1, every other exit negotiates" "streaming exits carry no total timeout", `test/restricted_compat_image_test.dart` "send() surfaces a headers timeout for image clients, aborting" "the response body errors after an idle gap" "a body that errs and goes on still times out" "an idle timeout nobody handles reaches the zone" "an abandoned body aborts its request"
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
  and only once. A request keeps the account current as it started: its
  refresh and replay use that account's credential even after a switch;
  a removed or signed-out account is not refreshed.
- **Why:** `/v1/illust/recommended` reports an expired token as 400
  `invalid_grant`; replaying arbitrary POST bodies is unsafe. After a
  switch, a 401 replayed account A's bookmark with B's token.
- **Check:** `test/pixiv_http_client_test.dart` "plain 400 without invalid_grant never triggers refresh" "opt-in POST surfaces a second 401 without another replay" "a request keeps its account through a switch, its refresh too", `test/token_refresh_gate_test.dart` "20 concurrent callers share exactly one refresh per account"
- **Code:** `lib/core/network/pixiv_http_client.dart`

### NET-09 Rate limits pause reads, not writes
- **Rule:** A 429 maps to `ApiRateLimited` with its `Retry-After`; reads
  wait out the cooldown, posts still go.
- **Why:** Hammering the API after a 429 extended the block.
- **Check:** `test/pixiv_http_client_test.dart` "429, server, parse and transport failures map to errors, no retry" "after a 429 reads wait out the cooldown; posts still go"
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

### NET-18 A cancelled body's late error is dropped
- **Rule:** A cancelled rhttp body can fail its cancel future with a body
  error Rust reports afterwards: flutter_rust_bridge's `async*` stream
  keeps waiting through a cancel, and rhttp maps only error events. The
  image idle guard drops that error from its own cancels and from
  `cancel()`, and its `cancel()` completes at once while the source's
  cancel runs on; any other cancel of an rhttp body awaits it inside a
  `try` or calls `.ignore()`, never `unawaited`.
- **Why:** The idle timeout dropped a stalled body's cancel future; when
  the connection died later, the raw `AnyhowException` went uncaught and
  ended the image worker isolate. A `.map` under `await for` hands an
  error on only after the cancel it starts completes, so returning the
  source's cancel held the idle timeout until Rust's next event: stalled
  images failed 15–30 s late.
- **Check:** `test/restricted_compat_image_test.dart` "a body error after the idle timeout is dropped" "a cancel completes though the body errs after it" "a mapped body errors after an idle gap though its cancel waits"
- **Code:** `lib/core/network/compat/network_policy.dart`

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
  the main isolate's fast-route, route-kind and image route score stores,
  the only writers of those preferences. Image route samples, range
  marks and front discoveries go back with their network identity: the
  main isolate's policy learns them while that network is current, and
  the score store keeps them. Each config carries the store's scores and
  discovery for its network, which seed the worker's policy when it or
  its network is new; a discovery the worker made outranks a config's.
- **Why:** Two isolates writing the same preferences overwrote each other.
  Downloads run on the main isolate and choose their route from the
  images the worker loaded.
- **Check:** `test/image_worker_host_test.dart` "route samples go back to the main isolate under their network", `test/route_discovery_test.dart` "the worker sends its discoveries home, and a config sent before "
- **Code:** `lib/core/image/image_worker_host.dart`, `lib/core/image/image_worker_providers.dart`, `lib/core/network/compat/route_kind_store.dart`, `lib/core/network/compat/image_route_score_store.dart`

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

## Continued transfers

### NET-15 A continuation appends only the same file
- **Rule:** Originals and downloads are one connection at a time. The
  first request asks a range from its offset (`bytes=N-`, from 0 too, so
  the total is known); only a 206 carrying the total is continued. A
  continuation asks `bytes=<received>-` with `If-Range` set to the first
  ETag, and is appended only when it is a 206 from that byte with the
  first total; anything else fails the transfer with
  `ContinuedFetchMismatch`, never retried. A 200 to a continuation asked
  without `If-Range` (no first ETag, as with pximg) is that route
  ignoring `Range`: it is closed and continued elsewhere instead; bytes
  are never taken from a 200. On pixiv's image hosts every request of a
  transfer shares one `ImageRoutePin`: the first sets its route, the
  continuations go there unless they move away (NET-16). A candidate that
  answered a `Range` with the whole file is marked per network until it
  serves a range; a resumed download tries marked candidates last, a
  range from byte 0 ignores the mark.
- **Why:** Appending a mismatched range mixed two files. Image routes
  change with their scores mid-transfer, and another route may serve
  another copy. Parallel 1 MiB ranges (until 11-04) were held up by their
  slowest range near its end, so downloads advanced in steps and lost to
  one connection on every measured network; no pixiv client splits an
  image.
- **Check:** `test/continued_fetch_test.dart` "every continuation asks If-Range with the first ETag" " fails the transfer without appending or a retry" "a 200 to a continuation without If-Range is asked again elsewhere; " "streams " "cancelling closes the live connection", `test/restricted_compat_image_test.dart` "every range of a transfer keeps to the route of its first" "a resumed transfer tries last a route that sent a whole file ", `test/download_resume_test.dart` "a large file arrives on one connection, in order" "a retry after pause continues from the anchor", `test/image_worker_host_test.dart` "arrives whole on one range request, its progress against the "
- **Code:** `lib/core/network/compat/continued_fetch.dart`, `lib/core/network/compat/network_policy_ladder.dart`, `lib/core/download/download_manager.dart`, `lib/core/image/image_worker_host.dart`

### NET-16 A stopped connection continues from its received byte
- **Rule:** When no body bytes arrive for `ImageStall.body` (no headers
  for `ImageStall.headers` while a continuation opens), or the connection
  fails or ends early, it is closed and the transfer continues from the
  received byte, at most `ContinuedFetch.defaultContinuations` times; a
  paused reader's wait does not count. A continuation stays on the
  transfer's route; it goes elsewhere (`ImageRoutePin.awayFrom`: the best
  other candidate that serves ranges, else the transfer's own route) when
  the one before it also stopped before sending a byte. After the last
  continuation the connection is left to the transport's idle timeout,
  and the next failure, early end or idle timeout ends the transfer as a
  transport failure, so a download keeps its bytes for a retry from its
  anchor (D8). Teardown uses
  `subscription.cancel().ignore()` before closing the response.
- **Why:** A stalled body waited the 15 s idle timeout, then failed. The
  first stop is often one bad connection; a route that stops again before
  a byte is likely bad for good. Awaiting `cancel()` never settled under
  `fakeAsync` and surfaced teardown errors as uncaught.
- **Check:** `test/continued_fetch_test.dart` "a stalled body continues from the received byte after 2 s; " "a dropped connection continues on the same route" "continuations stop at the bound, then " "a paused reader is not a stall; resuming finishes", `test/download_resume_test.dart` "a dropped connection continues from the received byte, on the " "network failure preserves bytes; retry resumes", `test/image_worker_host_test.dart` "a dropped connection continues from its received byte on the ", `test/restricted_compat_image_test.dart` "a restarted range goes to another candidate that serves ranges, "
- **Code:** `lib/core/network/compat/continued_fetch.dart`, `lib/core/network/compat/network_policy_ladder.dart`
