# State Management

> How state is managed in this project.

---

## Overview

Riverpod is the owner for app and server state. `Notifier`/`AsyncNotifier`
providers expose typed state and receive repositories through provider
dependencies; feature pages watch that state and dispatch typed actions. A
page keeps only view-local state that has no other consumer, using `State` or
`setState` (the novel reader's layout/page selection is an example).

The app does not create a second global service locator. Durable preferences,
secure credentials, history, and recovery records remain behind their core
repositories; widgets do not read their storage APIs directly.

---

## State Categories

| State kind | Owner | Example |
|---|---|---|
| View-local | feature state/view-model | reader page selection, open sheet state |
| Shared domain | Riverpod `Notifier`/store | `IllustStore`, `UserStore`, `BookmarkStore` |
| Server/feed | `AsyncNotifier` or `PagedFeedController` | initial, refresh, and load-more phases |
| Durable local | core repository | `SettingsRepository`, `HistoryRepository`, `CredentialStore` |
| Route/restoration | `GoRouter` typed facade and Flutter restoration | tab branch, search filter, viewer page |

Feeds keep ordered IDs while canonical entities stay in their domain store.
Settings selectors and account identity are exposed through fine-grained typed
providers so consumers do not depend on a whole aggregate unnecessarily.

---

## When to Use Global State

Promote state to a shared provider/store when it is observed by more than one
page, must survive a feature rebuild, represents an account boundary, or is a
durable/server contract. Keep it local when it only controls one widget's
presentation and has no domain consumer.

Account-scoped stores and feed families watch the current account boundary.
Route state that must survive restoration belongs in typed path/query values;
an in-memory route `extra` is only a first-frame snapshot.

---

## Server State

### Shared Entity Store Merge Contract (`IllustStore.mergeAll`)

**What**: `IllustStore` (`lib/core/entity/illust_store.dart`) is the single account-scoped copy of illust entities; feeds hold only ordered ID lists, so Recommended cards, Detail page and Viewer must observe identical data. `mergeAll` is the only write path for API payloads. Callers pass `EntityMergeSource.feed` (default) or `EntityMergeSource.detail` (`illust_detail_controller.dart` is the only authoritative site).

**Merge direction depends on [EntityMergeSource]** (`illust_store.dart` `mergeAll`):

| Field | `EntityMergeSource.feed` | `EntityMergeSource.detail` | Why |
|---|---|---|---|
| `isBookmarked` | BookmarkStore authority when bound; else new OR old | same BookmarkStore authority | BookmarkStore owns mutations; neither source writes the flag directly |
| `metaPages` / `metaSinglePageOriginalUrl` | keep old when incoming empty | incoming wins | feed refresh must not strip viewer/download URLs |
| `caption` / `tags` | keep old non-empty when incoming empty | incoming may be empty and overwrite | feed is sparse; detail empty values are real server state (C3) |
| `visible` | `new && old` (AND; `false` sticks) | incoming may set `visible=false` | shipped feed still ANDs; a feed `visible=false` hides a previously visible work. Detail `false` is the authoritative overwrite (C3) |
| `pageCount` | `max(new, old)` | incoming may shrink | a feed `page_count=1` must not erase a detail multi-page count; detail may reduce it |

**Rule for new `IllustEntity` fields**: every field added to `IllustEntity` MUST get an explicit merge decision in `mergeAll` (for both sources) plus a merge test in `test/illust_store_test.dart`. Fields defaulting to "newer wins" are acceptable only when a real endpoint always re-sends them.

**Wrong**: calling `store.mergeAll([fresh])` then rendering a captured pre-merge entity — read back via `store.get(id)` after merging (detail controller does exactly this so Ready state shows merged data).

### Canonical Mutation Store Protocol (`BookmarkStore`, lib/core/bookmark/)

**What**: cross-page mutable flags (bookmarked today; extensible to followed/liked) live in `BookmarkStore`, keyed by `(accountId, entityType, entityId)`. UI is a pure subscriber; entities sync via `illustStoreProvider`'s `onConfirmed` closure (one-way dependency — the store must NEVER `ref.read` the entity store or Riverpod circular-dependency errors appear at runtime).

**Mutation protocol**: `begin` records a non-optimistic pending entry (UI shows `CupertinoActivityIndicator` 24px) and dedupes concurrent ops per key → repository call → `commit`/`fail` validate the operation revision against the pending one (late responses from stale revisions are dropped). Remote snapshots enter via `observeRemote`, gated by the same revision clock. Every awaited repository call is wrapped in try/catch that ends in `fail` so pending spinners can never stick.

**Network contract (pixiv_http_client)**: token-expiry triggers the single-flight refresh on **401 OR 400 whose body contains `invalid_grant`** — observed live: `/v1/illust/recommended` surfaces an expired token as 400 invalid_grant, not 401. A plain 400 (parameter error) must NOT refresh. Diagnostics: non-2xx responses attach a clamped body snippet to `ApiHttpError.detail` (never contains credentials).

### Canonical User and Follow Protocol (`UserStore`, `FollowStore`, lib/core/user/)

**What**: `UserStore` is the account-scoped canonical map for user previews and
detail entities; `FollowStore` owns confirmed/pending/error relationship state
keyed by `(account, userId)`. Profile, relation cards and future Search/
Comments surfaces read these stores rather than keeping page-local user
objects or follow booleans.

**Mutation and merge rules**:

- Follow mutations are non-optimistic: `beginAdd`/`beginDelete` records a
  revision and pending operation, the repository call is awaited, and only
  `commit` changes the confirmed value. `fail` releases pending and keeps the
  previous confirmed value visible. Late completions and remote snapshots older
  than the confirmed revision are ignored.
- A fetch site captures `FollowStore.revisionNow()` before its request and
  passes it to `UserStore.mergeAll`. A detail/preview merge can enrich identity
  and profile fields, but the follow store's confirmed value is authoritative.
- A detail controller that writes into `UserStore` must `ref.read` the initial
  entity snapshot and watch only the current-account boundary. Watching the
  entire store from that controller makes its own merge invalidate the request
  and can create an unbounded detail-request loop.
- Account changes recreate/reset both stores before the new account's response
  is rendered; user IDs are not globally portable relationship keys.

### Cancellable Paged Feed Contract (`PagedFeedController`, `lib/core/paging/`)

**What**: every feed keeps only ordered entity IDs and owns an independent
cursor/state machine. The single fetch hook is
`fetchPageForContext(FeedRequestContext context)` (`paged_feed_controller.dart`).
There is no `fetchPage` / `fetchPageCancellable` pair; a subclass must never
throw `UnimplementedError('use fetchPageForContext')` to disown a second
contract (C12). Cancellation lives on `context.cancelToken`.

**State rules**:

- Initial, refresh, and load-more phases are independent. A cancelled
  request returns its active phase to `idle`, preserves loaded IDs and the
  last valid cursor, and does not become an error state.
- A new request supersedes an older one. Late results from a superseded
  request must not overwrite the current phase or cursor.
- `PagedFeedState.copyWith(initialError: null)` and
  `copyWith(loadMoreError: null)` explicitly clear an error; omitted error
  arguments preserve the prior value. This requires a sentinel rather than
  `??` for nullable error fields.
- Presentation: only the initial phase (`showInitialSpinner` /
  `AsyncValue.loading`) maps to the page's first-load skeleton. Refresh
  and load-more must keep the loaded list mounted; a feed that falls back
  to the skeleton on refresh is a regression (see
  component-guidelines.md "First-Load Skeletons" and the Shared
  Pull-to-Refresh Contract).
- A non-empty server cursor must pass the feed's `validateCursor` allowlist
  before it is stored. A rejected cursor is an observable `ApiParseError` and
  must never be requested.

**Account boundary**: a feed family keyed by a mode/filter must watch the
current account ID and reset on account change. Shared entity providers
must likewise be recreated or cleared at that boundary so account A's
entities cannot be rendered during account B's load.

**Tests**: each cancellable feed covers cancellation without an error,
late-result suppression, cursor rejection, per-filter independence, and
account-switch reset.

### Generation-Scoped Feed Commit Contract (`FeedRequestContext`, `FeedCommitGate`)

#### 1. Scope / Trigger

This contract applies when a paged feed fetches shared entities and can overlap
refresh, append, account, credential, network, selector, or lifecycle changes.
It is the required boundary for Recommended, Ranking, New, Search, and Profile
feeds.

#### 2. Signatures

```dart
class FeedRequestContext {
  final String feedKey;
  final String? accountId;
  final int generation;
  final int page;
  final String? cursor;
  final CancelToken cancelToken;
}

Future<FeedPage> fetchPageForContext(FeedRequestContext context);
bool FeedCommitGate.commit(
  FeedRequestContext context, {
  required String? accountId,
  required void Function() action,
});
```

`FeedPage` contains ordered IDs, a nullable validated candidate cursor, and an
optional commit callback. The callback is the only place a repository page may
merge into `IllustStore`, `NovelStore`, or `UserStore`.

#### 3. Contracts

- A controller creates the immutable context before issuing the request. Its
  `feedKey` includes every family selector (mode, query, filter, sort, or
  profile key); account ID is captured from the same boundary snapshot.
  There is no `credentialRevision` on the context (C1): overlapping work is
  fenced by generation plus `cancelToken`.
- A repository parses/normalizes into `FeedPage` and performs no shared-store
  write. The controller validates `next_url` before invoking the callback, then
  commits entity merge, stable ID dedupe, cursor, page, and phase from the same
  active context without an intervening await.
- Refresh increments generation, clears the prior generation's committed
  cursor set, and cancels old append work. A repeated current or previously
  committed cursor is an `ApiParseError`; its page cannot merge or advance the
  cursor.
- Account boundary changes are watched synchronously by the
  provider, so a family instance rebuilds and old entity ownership/list/cursor
  state is not reused. Disposal invalidates the gate even when transport
  cancellation cannot physically stop the response. Token refresh does not
  rebuild the feed (C1).
- A rejected active response leaves existing list/cursor/entity data intact and
  surfaces the appropriate initial, refresh, or load-more error. A stale or
  cancelled response records bounded metadata-only telemetry and cannot alter
  UI state or shared stores.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Feed key, generation, or account is inactive | Reject commit; record stale/boundary telemetry; do not merge or update cursor/state |
| Cancellation or provider disposal | Reject commit; record cancellation/disposed telemetry; do not publish a network error or entity |
| Unknown/foreign/invalid cursor | Raise `ApiParseError` before the page callback; preserve current list and cursor |
| Current or previously committed cursor repeats | Raise `ApiParseError` before entity merge or cursor advance |
| Same ID appears on a page | Merge the last server-ordered entity snapshot and keep one stable list ID |
| Refresh response reorders/deletes IDs | Replace the generation's ordered list; removed IDs are not retained as feed ghosts |
| Load-more response overlaps existing IDs | Append only unseen IDs in server order; keep the prior IDs and valid cursor |

#### 5. Good / Base / Bad Cases

- Good: page 2 for the active query updates an existing ID, adds new IDs in
  server order, and advances exactly one validated cursor.
- Base: refresh completes while a non-cancellable append is in flight; refresh
  owns the final list and the late append is visible only in discard telemetry.
- Bad: a repository calls `store.mergeAll` immediately after parsing and only
  later asks whether the request is current; a stale account response then
  contaminates the shared store even if the visible ID list is protected.

#### 6. Tests Required

- Fake delayed responses must assert refresh-before-append, account switch,
  cancellation, and disposal against list IDs, shared entities, cursor, and
  discard telemetry.
- Same-ID update, duplicate-ID, disjoint-page, refresh reorder/delete, and
  repeated-cursor tests must assert exact ordering and no ghost IDs.
- Each migrated feed keeps its endpoint/selector cursor allowlist tests;
  `flutter analyze` and focused feed tests are required before commit.
- Device evidence must distinguish feed unit/build validation from MuMu
  emulator validation; no physical-device result may be inferred.

#### 7. Wrong vs Correct

**Wrong**: `fetchPage` parses a response and calls `store.mergeAll(page.items)`
before checking whether refresh, account, or disposal replaced its request.

**Correct**: return a `FeedPage` with a deferred callback, validate its cursor,
then call `FeedCommitGate.commit(context, action: ...)`; only the accepted
transaction may merge entities and let the controller publish IDs/cursor/phase.

### Media Resource Ownership Contract (`UgoiraAsset`, `lib/core/ugoira/`)

An animated-media load owns exactly one disk temporary archive, one random-access
index, one bounded decoded-frame cache and one playback scheduler. The asset
closes the index and deletes its temporary file; the cache owns every resident
`ui.Image` and disposes it on replacement, eviction or clear. A viewer may
retain only the current bounded window, and must stop the scheduler before
route/lifecycle teardown.

GIF post-processing is a user-visible job with one owned pending MediaStore
item and one worker isolate. It must check cancellation between frames and
before finalize, abort on failure/cancellation, dispose the worker, and emit
exactly one terminal snapshot. Quantization must not run synchronously on the
UI isolate or retain the complete decoded-frame list.

The post-process record uses its own versioned recovery key and an explicit
Ugoira owner prefix; its synthetic GIF URL must never enter the ordinary
DownloadManager retry queue. Startup recovery loads that namespace before the
normal media scan. Since a restart cannot reconstruct the in-memory
`UgoiraAsset`, queued/running/finalizing/canceling/retryable records become
`orphaned` with an explicit reload error, while failed/canceled/succeeded
records remain observable. A pending row is cleaned only through the exact
owner marker; unknown ordinary-download rows are left untouched.

### Image Worker Contract (`ImageWorker`, `WorkerImageProvider`, `lib/core/image/`)

#### 1. Scope / Trigger

Most Pixiv images load in a background isolate: fetch, disk cache and
scheduling all run there, and the main isolate only decodes the committed
file. This contract applies when adding an image surface or a preload, when
changing which images use the worker, and when touching the worker's
protocol, lifetime, cache or lanes. The images the worker does not load
follow the Image Scheduling Contract below.

#### 2. Signatures

```dart
typedef ImageWorkerStarter = Future<ImageWorkerClient> Function(
    ImageWorkerConfig config, ImageDemand demand);
class ImageWorker implements ImageFetcher {
  ImageWorker({required ImageWorkerStarter start,
      required Future<ImageWorkerConfig> Function() config, int maxStarts = 3});
  final ImageDemand demand; // the worker's own; outlives any one isolate
  ImageWorkerState get state; // idle/starting/running/stopped/gaveUp/disposed
  Future<FetchResult> fetch(String url, {required ImageFetchPriority priority});
  void Function() watchProgress(String url, ImageProgressListener listener);
  Future<File?> cachedFile(String url); // disk only; starts the worker
  Future<void> configChanged();
  Future<ImageWorkerSnapshot> snapshot(); // probe page; never starts one
  Future<Map<String, NetworkRouteKind>> routeSnapshot(); // never starts one
}
final imageWorkerProvider = Provider<ImageWorker>(…); // once per container
class WorkerImageProvider extends ImageProvider<WorkerImageProvider> {
  WorkerImageProvider(ImageFetcher worker, String url,
      {ImageFetchPriority priority = ImageFetchPriority.foreground}); // == by url
}
class ImageWorkerUnavailable implements Exception { final String reason; }
class FetchFailure implements Exception { final int? statusCode; }
typedef ImageProgressListener = void Function(int received, int? total);
class ImageProgressThrottle { bool shouldReport(int received, int? total); }
```

#### 3. Contracts

- Pipeline choice: every `PixivImage` with a `ProviderScope` loads through
  the worker — capped or not, with or without `progress`, original files
  included. Only outside a scope (no worker) does the legacy stack load it.
  `preload` applies the same rule, so a warm-up lands on the entry the
  widget showing it resolves.
- The worker path renders `OctoImage(ResizeImage(WorkerImageProvider))` (the
  bare provider when uncapped) with `CachedNetworkImage`'s fades,
  placeholder and gapless hand-off. A decode is recorded on its first frame
  in `imageBuilder`.
- Progress is a subscription by URL, not part of a fetch: one decode entry
  serves resolvers with and without a ring (Hero phase, card-tap warm-up),
  so the first resolver must not decide whether bytes are reported.
  `watchProgress` counts listeners per URL and sends `watch` on the first
  and `watch off` after the last; every worker that starts, a replacement
  included, is told every watched URL. The host reports only watched URLs:
  the first bytes at once, then each further tenth of a known total at most
  every 100 ms (`ImageProgressThrottle`); without a total only the first
  report goes out. A disk hit transfers nothing and reports nothing.
  `PixivImage` turns reports into `ImageLoadProgress.ofBytes` and goes back
  to `idle` on the stream's frame or error, as on the legacy pipeline.
- Decode identity is (url, decode width, pipeline). Transition history, the
  completion log and the last decode per URL are keyed by it. A stand-in
  (Hero hand-off, tier underlay) paints a decode that actually completed —
  a guessed width or pipeline is a different cache entry and fetches. A tier
  record says nothing about which pipeline decoded it.
- Lifetime: the isolate starts on the first fetch. A dead worker fails its
  pending requests with `ImageWorkerUnavailable` and is replaced on the next
  fetch, at most `maxStarts` starts per session; after that every fetch fails.
  Every death and failed start goes to the crash log. There is no fallback to
  the legacy stack.
- Cancel and promote: widgets hold their URL in `ImageWorker.demand`. A URL
  with a request in flight that nobody wants after the 500 ms release grace
  is cancelled; a queued fetch is dropped (`ImageFetchDropped`), a streaming
  one is never interrupted. `onHeld` promotes a queued background fetch.
  The viewer's neighbour window is a prefetch window on `ImageWorker.demand`.
- Inside the worker: a disk hit answers before any lane; a miss queues on the
  foreground (8) or background (2) lane, coalesced by URL. The disk cache is
  `parfait_images_v2` in the temp directory, 256 MB LRU, written tmp+rename.
- Cache reuse: `cachedFile` answers from the worker's disk cache without
  queuing or fetching. Downloads (and the viewer's save, which is a
  download) use it as `DownloadManager.cacheLookup`; the in-app widget
  refresh reads covers through it (`WidgetFeedLoader.cachedImage`), while
  the background widget isolate has no worker and downloads. It starts the
  worker like `fetch`. A miss, a file evicted before it is read, or an
  unavailable worker falls back to the network with a log line. Sharing
  sends a link and needs no file.
- Route diagnostics: the worker's policy learns image-host routes the main
  policy never sees. `routeSnapshot` asks the running worker for its
  `effectiveRouteSnapshot` (empty when none runs; it never starts one, and
  a worker that does not answer within `statusTimeout` fails it). The
  network page lists those entries after the main policy's, each marked
  `networkRouteForImages`; a failed answer shows only the main routes and
  logs it.
- Originals in the worker: an `/img-original/` fetch asks for its first
  1 MiB range; a sized 206 from byte 0 continues in parallel ranges
  (Segmented Transfer Contract) on the worker's own
  `SegmentBudget(limit: ImageWorkerHost.segmentLimit)` (3), so no permit
  crosses the isolate boundary. A 200 is the whole file; anything else,
  a 206 from another offset or without a total included, fails with its
  status. Progress counts against the whole length. Closing the host ends
  running ranged transfers.
- Config: settings, mirror, DoH, ECH, mode and network identity reach the
  isolate as a whole `ImageWorkerConfig` (`configChanged`); a network
  identity change arrives through `NetworkAccessPolicy.onRevisionAdvanced`.
  Route learning goes back to the main isolate's stores (see HTTP Client
  Ownership in `backend/directory-structure.md`); an exhausted host reaches
  the main policy's `onImageHostExhausted`.
- Errors: the host catches at its message boundary and reports
  `WorkerErrorEvent` to the crash log; an HTTP status arrives as
  `FetchFailure.statusCode`, and `PixivImage` treats 403/404/410 from either
  pipeline as permanent.

#### 4. Tests Required

`disk_image_cache_test.dart`, `image_fetch_scheduler_test.dart`,
`image_worker_host_test.dart`, `image_worker_client_test.dart`,
`image_worker_test.dart`, `worker_image_provider_test.dart`,
`pixiv_image_pipelines_test.dart` (nothing reaches the legacy cache while
a worker exists), `image_load_progress_test.dart`,
`pixiv_image_retry_test.dart` (a capped image and an original) and
`pixiv_image_variants_test.dart`. Widget tests use the helpers in
`test/helpers/image_network.dart`: `inProcessImageWorker` (real host,
protocol, cache and scheduler; only the `http.Client` is scripted) and
`stalledImageWorker` (never comes up; for setup-only assertions). Real IO
advances in `runAsync` turns between pumps (`pumpIoUntil`). A test that
leaves a worker transfer in flight ends with `unmountPastReleaseGrace`: the
release arms a re-check timer that must not outlive the test. A test world
that answers the path_provider channel must override `imageWorkerProvider`,
or the production provider spawns a real isolate.

#### 5. Wrong vs Correct

**Wrong**: a `wantsProgress` flag on the fetch, or progress read from the
worker image stream's chunk events — a card-tap warm-up resolves the entry
first, and the detail page's ring attached later never sees a byte.

**Correct**: `ImageWorker.watchProgress(url, …)` next to a listener on the
stream the widget resolves, which only returns the ring to `idle`.

### Image Scheduling Contract (`PriorityFileService`, `ImageDemand`, `lib/core/network/compat/`)

#### 1. Scope / Trigger

Pixiv images outside a `ProviderScope` — the only ones the worker does not
load — go through the shared image `CacheManager`, whose file service is
`PriorityFileService`. This contract applies when adding such an entry
point or preload, or when touching lane sizes.

#### 2. Signatures

```dart
enum ImageFetchPriority { foreground, background }
class PriorityFileService extends FileService {
  PriorityFileService({required http.Client httpClient, ImageDemand? demand,
      SegmentBudget? segmentBudget}); // see Segmented Transfer Contract
  static const foregroundSlots = 8, backgroundSlots = 2;
  void promote(String url);
}
class ImageDemand {
  void Function(String url)? onHeld; // wired to promote
  void hold(String url); void release(String url);
  void holdFor(String url, Duration ttl);
  void setPrefetchWindow(Object owner, Set<String> urls);
  void clearPrefetchWindow(Object owner);
  bool wants(String url);
}
class ImageFetchDropped implements Exception {}
enum ImagePreloadResult { decoded, dropped, failed }
static Future<ImagePreloadResult> PixivImage.preload(…, {ImageDemand? demand,
    ImageFetchPriority priority = ImageFetchPriority.background});
class ImageLoadProgress { const .idle(); const .loading([double? fraction]);
    factory .ofBytes(int received, int? total); } // both pipelines
PixivImage(…, {ValueNotifier<ImageLoadProgress>? progress}); // also .detail
class ImageLoadProgressOverlay { ImageLoadProgressOverlay({required progress}); }
```

`PixivNetworkFactory.imageDemand` is the app's single demand, shared with
`imageCacheManager`'s file service.

#### 3. Contracts

- `WebHelper` never queues (`concurrentFetches` admits everything); its FIFO
  would put a visible image behind every queued prefetch. Real concurrency is
  the two gates: foreground 8, background 2. A permit is held until the body
  ends, is cancelled, or the 45 s hold limit fires; handlers set later through
  `onDone`/`onError`/`asFuture` keep the release.
- Background = requests carrying the prefetch marker (`PixivImage.preload`
  with background priority). Everything else is foreground.
- `WebHelper` merges requests for one URL, so a visible image whose URL is
  queued as prefetch never reaches the service by itself. `ImageDemand.onHeld`
  (first `hold`, every `holdFor`) calls `promote`: the queued waiter moves to
  the foreground gate and gives its slot back there.
- A queued waiter whose turn comes while `wants(url)` is false completes with
  `ImageFetchDropped`: no request, no file. `wants` is true while held, inside
  a `holdFor` ttl, inside any prefetch window, or within 500 ms of the last
  release (Hero flights, re-layout). Immediate admissions and transfers
  already streaming are never checked or interrupted.
- Holders: every legacy `PixivImage` holds its effective URL while mounted
  (hold new before releasing old).
  User-asked preloads (card tap → detail tier, `openImageViewer`) are
  foreground and `holdFor` 10 s. Without a `ProviderScope` nothing registers
  and nothing is dropped. A `failed` preload is not retried — retrying is the
  visible widget's job.
- `preload` never reports through `FlutterError.onError`; a non-drop failure
  is a `debugPrint`, and a failed image is never recorded as decoded.
- Retry belongs to the visible `PixivImage`. A transient failure (anything but
  `HttpExceptionWithStatus` 403/404/410) retries by itself after 1 s, 3 s and
  8 s; a permanent or exhausted one shows a refresh `IconButton` (tooltip
  `imageRetry`) when the box is at least 48×48, else the broken-image icon. A
  retry evicts the `ResizeImage`-wrapped key the widget resolves (the
  loader's own eviction misses it) and bumps the `CachedNetworkImage` key.
  A manual retry restores the three automatic ones; a URL change resets them;
  dispose cancels a pending one.
- Progress: `PixivImage.progress` follows the same stream the widget
  resolves (no second decode), attached after the frame; on the worker the
  bytes come from `watchProgress` (Image Worker Contract). `loading` starts
  at the first bytes, so connecting or queued fetches report nothing; an
  image or error goes back to `idle`, and a new key resets to `idle` first.
  The overlay shows after 300 ms of `loading`, is `IgnorePointer`, and sits
  outside any Hero (and outside the viewer's zoom). The detail page passes
  its notifier only after the Hero phase; flight `popChild`s never get one.
  The notifier's owner outlives the image.

#### 4. Tests Required

`priority_file_service_test.dart` (lanes, promotion, drop at turn, no leak,
grace, no interruption, `WebHelper` admits all), `image_demand_test.dart`,
`pixiv_image_preload_test.dart` (no `ProviderScope`, so the legacy stack).
The image chain is real (`test/helpers/image_network.dart`); only the HTTP
client and the path_provider channel are fakes, and disk work runs inside
`runAsync`. Retry, progress and the hold test (`pixiv_image_variants_test.dart`)
run on the worker now (Image Worker Contract) and clear `imageCache` in
`setUp` — a cached error or image for the same URL answers without asking
the network.

#### 5. Wrong vs Correct

**Wrong**: a new image surface paints `Image(CachedNetworkImageProvider(url))`
directly — nothing holds the URL, so a queued fetch for it can be dropped.

**Correct**: paint through `PixivImage` (or warm through `PixivImage.preload`
with a registered window or a foreground `holdFor`).

### Segmented Transfer Contract (`SegmentedFetch`, `SegmentBudget`, `lib/core/network/compat/segmented_fetch.dart`)

#### 1. Scope / Trigger

Large Pixiv files (`/img-original/` images, downloads) are fetched as
parallel byte ranges so one slow CDN connection cannot set the pace. This
applies when touching `ImageWorkerHost._openInRanges`,
`PriorityFileService._fetch`, `DownloadManager._open`, the budgets, or
adding another bulk transfer.

#### 2. Signatures

```dart
class SegmentBudget { SegmentBudget({int limit = 6}); bool tryAcquire(); void release(); }
final segmentBudgetProvider = Provider<SegmentBudget>(…); // main isolate
class RangeResponse { factory RangeResponse.fromHttp(http.StreamedResponse r); }
typedef RangeOpen = Future<RangeResponse> Function(int start, int endInclusive,
    {String? ifRange, required NetworkCancelSignal cancel});
class SegmentedFetch {
  SegmentedFetch({required RangeOpen open, required SegmentBudget budget,
      int segmentBytes = 1 << 20, int maxParallel = 4, DateTime Function()? clock});
  static const maxRestarts = 2;
  int get fetchedBytes;
  Stream<List<int>> continueFrom(RangeResponse first, {NetworkCancelSignal? cancel});
  void close();
}
class SegmentedFetchMismatch implements Exception {}
class SegmentedFetchCancelled implements Exception {}
DownloadManager({…, SegmentBudget? segmentBudget}); // null = single stream
```

#### 3. Contracts

- The caller opens the first range (`bytes=<offset>-<offset + 1 MiB − 1>`)
  itself and continues only from a 206 whose `Content-Range` carries the
  total. A 200 is used as a plain single stream; the image cache returns
  any other answer as is, and the download manager keeps its 200/416 resume
  branches.
- The first connection is covered by its image lane or download slot; up to
  `maxParallel − 1` more come from the isolate's `SegmentBudget`: on the
  main isolate the one `segmentBudgetProvider` (not the network factory,
  which is rebuilt per policy, limit 6), in the image worker its own
  (limit 3). Together with the worker's 10 image lanes and 3 download jobs
  that is at most ~22 connections per host. No budget left = the first
  connection does everything.
- Every later segment sends `If-Range` with the first ETag. A segment that is
  not a 206 with exactly its range and the same total fails the whole
  transfer with `SegmentedFetchMismatch`, never retried — stitching it in
  would mix two files.
- A segment is restarted from the byte it reached after 5 s without bytes, or
  when it has run ≥ 3 s, has > 256 KiB left and streams under a third of the
  median pace (other active segments plus the last 8 finished ones). A
  dropped connection retries the same way. Each segment gets at most
  `maxRestarts`; after that an error fails the transfer and a stall is left
  to the transport's idle timeout.
- Workers claim only segments within `maxParallel` of the next undelivered
  one: that is the backpressure and the memory cap (≤ 4 MiB per transfer).
- Cancelling (signal or `close()`) closes every connection, returns the
  budget and ends the output with `SegmentedFetchCancelled`; the download
  manager maps it to `DownloadCancelledException`.
- Images: only `/img-original/` paths segment, and the lane holds one slot
  for the whole transfer. The worker sends no conditional headers, so every
  range asks the same (Image Worker Contract). The legacy image cache
  returns a synthetic 200 with the total length and no `content-range`, so
  `WebHelper` and its cache format are unchanged; its later segments drop
  `If-None-Match`/`If-Modified-Since` (a 304 cannot be stitched).
- Downloads: below 2 MiB remaining the rest follows on one connection
  (`maxParallel = 1`). `receivedBytes` shows `resumeOffset + fetchedBytes`
  (bytes fetched ahead of the sink included), while the resume anchor stays
  the sink's `storedBytes`. A first 206 without a total or from another
  offset fails before writing. The updater's manager passes no budget.

#### 4. Tests Required

`segmented_fetch_test.dart` (sizes around segment edges, budget caps, slow
and stalled restarts, restart limit, If-Range, mismatch, cancel and
close-before-listen, paused reader) runs in `fakeAsync` against a paced
in-memory server. The `an original file` group in
`image_worker_host_test.dart`, `priority_file_service_test.dart` group
`originals` and the `parallel ranges` group in `download_resume_test.dart`
run the real worker host / cache manager / download manager over in-memory
range servers (`RangeServingClient`, `_RangeTransport`).

#### 5. Wrong vs Correct

**Wrong**: awaiting `subscription.cancel()` when tearing down a segment — in
`fakeAsync` the root-zone future never settles, and a body that errors on
teardown surfaces as an uncaught error.

**Correct**: `subscription.cancel().ignore()`, then close the response.

### Comments and Replies Contract (`CommentStore`, `lib/core/comments/`)

#### 1. Scope / Trigger

This contract applies to the comments feature because it crosses the Pixiv
HTTP API, shared entity state, paged feed state, composer actions and the
account boundary. A comment must have one canonical entity copy; a feed may
store only ordered IDs.

#### 2. Signatures

```dart
Future<CommentPage> fetchComments(int illustId, {String? cursor});
Future<CommentPage> fetchReplies(
  int rootCommentId, {
  required int illustId,
  String? cursor,
});
Future<CommentEntity> addComment(CommentAddRequest request);
Future<void> deleteComment(int commentId);
```

`CommentEntity` keeps `id`, `illustId`, `parentCommentId` and
`rootCommentId` as separate positive IDs. `parentCommentId == null` means a
root comment; a root's `rootCommentId` is its own `id`.

#### 3. Contracts

- Root list: `GET /v3/illust/comments?illust_id=<id>`.
- Reply list: `GET /v2/illust/comment/replies?comment_id=<root-id>`.
- Add: `POST /v1/illust/comment/add` form fields `illust_id`, optional
  `comment`, optional `stamp_id`, and optional `parent_comment_id`.
- Delete: `POST /v1/illust/comment/delete` form field `comment_id`.
- List responses contain `comments` and nullable `next_url`; entries contain
  `id`, `comment`, `date`, `user`, `has_replies`, and optional `stamp`.
  The replies endpoint may omit a parent field, so the repository supplies
  the active root context without confusing it with the direct parent.
- `CommentStore` indexes roots by `illustId`, replies by `rootCommentId`, and
  mutation state by an operation key plus monotonically increasing revision.
  Send/delete state is pending until the API succeeds; no optimistic entity
  is published.
- The composer bundles only `assets/emojis/`. Stamps are not bundled: picker
  cells load `commentStampUrl(id)` and stamp comments load the API's
  `stampUrl`, both through `PixivImage.feed`. Grid columns are width-driven (emoji ≈48dp cells clamped 3–10, stamps ≈96dp
  cells clamped 2–5) so narrow screens keep minimum touch targets. Translation is a transient overlay and never
  replaces or persists the original comment text.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Non-positive illust/comment/root ID | Throw a parse/argument error before request |
| Reply request without `parentCommentId` | Reject; never send a root-shaped reply |
| Empty text and no stamp | Reject locally; keep composer content |
| Unknown endpoint/identity in `next_url` | Reject cursor as `ApiParseError`; never request it |
| Duplicate pending send/delete for the same operation key | Suppress the second request without consuming a revision |
| API/transport/parse failure | End pending state, keep confirmed data, surface a retry/error state |
| Late completion from an older revision or account | Drop it without changing the current thread |
| Delete for a non-owner | Throw `CommentPermissionException` before API call |

#### 5. Good / Base / Bad Cases

- Good: a reply to root `100` sends `parent_comment_id=100`, is inserted in
  the `rootCommentId=100` index only, and increments root `100`'s count after
  success.
- Base: a comment list page with `next_url == null` renders the loaded IDs or
  the explicit empty state; refresh failure preserves existing IDs.
- Bad: using a visible list index, `rootCommentId` or another comment's ID as
  the delete/send key, or adding a local comment before the server response.

#### 6. Tests Required

- Entity parsing asserts root/reply/stamp fields and rejects invalid IDs/date.
- Repository tests assert exact paths, query/form fields, response parsing and
  cursor endpoint/identity allowlists.
- Store tests assert dedupe, root/reply index isolation, reply count changes,
  root descendant removal, duplicate suppression and late revision drops.
- Action tests assert no entity appears before API success and non-owner delete
  makes zero repository calls.
- Widget tests assert explicit reply/translate/delete actions, width-driven
  emoji/stamp grid columns and the initial/load-more retry states. A device check must distinguish API
  read success from unperformed real-account mutations.

#### 7. Wrong vs Correct

**Wrong**: `replies[comment.id] = localComments` and then mutate the item at
the same list index after a delayed add response. A reordered page can update
the wrong thread.

**Correct**: normalize each response to `CommentEntity`, merge it into the
canonical store by `comment.id`, and route the confirmed result through the
operation's explicit `(illustId, parentCommentId, rootCommentId)` context.

### Browsing History Contract (`HistoryRepository`, `HistoryTracker`)

#### 1. Scope / Trigger

This contract applies to local and Pixiv browsing history. Detail and Novel
routes wrap their loaded, viewable content in `HistoryVisibility`; the wrapper
starts and pauses a `HistoryTracker` from route visibility and
`AppLifecycleState`. History is account-scoped and does not run for a signed-out
route.

#### 2. Signatures

```dart
Future<void> HistoryRepository.upsert(HistoryRecord record);
Future<HistoryPageResult> HistoryRepository.page({
  required String accountId,
  int offset = 0,
  int limit = 30,
});
Future<void> HistoryRepository.commitView({
  required HistoryRecord record,
  required bool writeLocal,
  required bool enqueuePixiv,
  required Duration unsubmittedPixivDuration,
});
Future<void> HistoryRepository.flushOutbox({
  required String accountId,
  required PixivHistoryRemote remote,
});
```

`HistoryRecord` stores typed content kind/ID, UTC `lastViewedAt`, account ID,
visible duration and the fields in `HistorySnapshot` only. Novel progress is a
paragraph ID plus offset; it is not a copy of the novel body or API JSON.

#### 3. Contracts

- `HistoryDatabase` owns one lazy-opened `history.db` connection per Riverpod
  container and closes it when the container is disposed. Every operation goes
  through `HistoryRepository`; writes combining a local row and an outbox row
  use one SQLite transaction.
- `history_records` has a unique `(account_id, content_type, content_id)`
  index and a recent-access index. Upsert updates the same logical row and
  history pages order by `last_viewed_at DESC, id DESC`.
- `pixiv_history_outbox` is keyed by account/content and merges duration. A
  successful `/v2/user/browsing-history/illust/add` call deletes that row;
  failures retain it with bounded exponential/hourly backoff. Flushes are
  serialized and never report success after a failed request.
- Local history reads `localHistoryEnabledProvider`; Pixiv sync reads
  `pixivHistoryEnabledProvider`. Disabling either switch stops new writes for
  that channel and does not delete existing local rows automatically. The
  two switches live in the history page's overflow menu (checkable
  `AppMenuEntry`s), not on a settings page — they stay reachable signed out
  because they are global settings.
- `HistoryTracker` uses production `StopwatchHistoryClock`; it accumulates
  only route-visible foreground segments. It has no periodic timer. Pixiv
  enqueueing starts at 10 seconds and only the newly unsubmitted duration is
  merged into the outbox.
- The history page reads the indexed rows, uses `IllustStore`/`NovelStore` when
  a richer entity is already present, and renders the stored snapshot when an
  entity was deleted or is unavailable. Delete and clear are account-scoped.
- A history page keeps a monotonically increasing request generation for its
  initial load/refresh and load-more calls. A load-more response may append or
  publish an error only when its captured generation still matches the active
  one; refresh, clear, account switch, and widget disposal invalidate older
  generations. This prevents a late page from the previous account/list from
  reappearing after the visible list was reset.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Empty account or non-positive content ID | Reject before SQLite work |
| Invalid/corrupt row or unsupported content type | Surface a format error; do not fabricate an entity |
| Migration/open failure | Keep the error visible to the caller; do not silently replace the database |
| Local history disabled | Do not write a new local row and do not auto-delete old rows |
| Pixiv request offline/rate-limited | Keep outbox work, schedule bounded retry, surface sync failure |
| Account changes during flush | Stop before submitting under the new account; retain old-account outbox |
| Route covered/backgrounded | Pause the stopwatch and commit the accumulated segment |
| Concurrent first open/flush | Share the connection/flush tail; never open per operation or double-submit a row |
| Refresh/clear/account switch while page append is in flight | Drop the stale append and its error; do not mix generations in the visible list |

#### 5. Good / Base / Bad Cases

- Good: reopening illust `42` under account `a` updates one row to the top;
  reopening it under account `b` creates an independent row.
- Base: a short view is present in local history but remains below Pixiv's
  minimum duration threshold; a later visible segment can cross the threshold
  and enqueue the merged duration once.
- Bad: storing `illust.toJson()` or novel text in the database, counting
  background time with `Timer.periodic`, or flushing an account-A row after the
  active account changed to B.

#### 6. Tests Required

- Repository tests cover schema v1→v2 migration, version/index presence,
  upsert/order/page/count/delete/clear, account isolation and transaction
  outbox merging.
- Tracker tests use an injected clock to cover pause/resume, threshold
  crossing, repeated leave events and the absence of periodic timing.
- Outbox tests cover success deletion, failure backoff, serialized flush and
  account-change retention.
- Widget/detail/novel tests cover snapshot hydration fallback and explicit
  settings/history entry points. Device checks must distinguish local DB
  persistence from real-account Pixiv submission; no mutation is performed
  without an explicit test account action.
- History-page tests cover refresh-before-append and account-switch-before-
  append; assert that the old page neither changes the new records nor leaves
  a stale load-more error visible.

#### 7. Wrong vs Correct

**Wrong**: open `history.db` inside every `count`, `query` and `delete`, store a
full API object, and increment browsing time from a one-second periodic timer.

**Correct**: let the keep-alive repository own one connection, write only the
typed compact snapshot in a transaction, and commit Stopwatch elapsed time at
visibility/lifecycle boundaries through the account-scoped outbox.

### Versioned Settings Contract (`AppSettings`, `SettingsRepository`)

**What**: ordinary preferences are represented by the immutable `AppSettings`
aggregate and persisted as `replica.settings.v2`. `SettingsRepository` reads
the complete allowlisted preference map once, validates each field against its
own fallback, and migrates the old `replica.guide_completed`,
`replica.language`, `replica.theme`, and beta56 `settings` JSON shapes without
deleting the source data.

**Mutation rules**:

- `SettingsController` queues writes and awaits the selected operation before
  publishing the new `AsyncData`; a failed write leaves the previous value
  visible and returns `SettingsWriteException` for the UI to surface.
- Theme, image source, quality, history, block, translation-provider and
  download-cap consumers use typed providers. The download manager updates its
  scheduler cap without replacing active jobs.
- The normal image route is `i.pximg.net` over HTTPS. Image URLs are never
  rewritten to an IP or a mirror; steering a connection to a resolved address
  belongs to the exact-host network policy, which keeps the original hostname
  for `Host` and certificate verification.
- Translation credentials are not fields in `AppSettings.toJson()`. A
  `SecretSettingRef` may identify a secure-storage record, but the record's
  secret stays in `CredentialStore`.

### Restricted Pixiv Network Policy Contract (`NetworkAccessPolicy`)

#### 1. Scope / Trigger

This contract applies when a native Pixiv API, OAuth, image-cache, media
download or widget-background request needs the mainland compatibility path.
The policy is app-scoped and must not become a generic proxy or a URL-rewriting
service. The ordinary platform login WebView and non-Pixiv providers keep
their own transports.

#### 2. Signatures

```dart
http.Client clientFor(PixivDestinationPurpose purpose, NetworkRoute route);
Future<ResolvedHost> resolve(
  PixivDestination destination, {
  NetworkCancelSignal? cancelSignal,
});
void setMode(NetworkMode mode);
NetworkRevision advanceNetworkRevision({String? networkIdentity});

Future<EchConfigResult> lookupEchConfig(
  String frontHost, {
  required NetworkRevision revision,
  NetworkCancelSignal? cancelSignal,
});
```

`PixivPolicyHttpClient` and `PolicyDownloadTransport` are the shared native
consumers.

#### 3. Contracts

- The default mode is `NetworkMode.automatic`. Cold order is decided by
  `NetworkAccessPolicy._fallbackTiersFor`
  (`lib/core/network/compat/network_policy.dart`): Cloudflare hosts
  (appApi/oauth/accountsWeb/pixivWeb) use
  `ech → dohRealSni → direct → insecureNoSni`; image hosts (`i.pximg.net` /
  `s.pximg.net`) use `ech → noSni → dohRealSni → direct → insecureNoSni`;
  third-party image mirrors use `noSni → dohRealSni → direct` and never
  enter the ECH or insecure tiers.
  Host/group memory promotes the last successful kind, except on pixiv
  image hosts (next bullet). `insecureNoSni`
  (empty SNI, no certificate verification, persisted/bundled
  bootstrap 210.140.139.155/133) is always the last fallback. Production
  forces `insecureNoSniEnabled: true` with no user switch
  (`network_providers.dart:29`). A failed fast address is cooled for 30
  seconds (`_kFastRouteCooldown`). `NetworkMode.directOnly` closes
  compatibility route pools and prevents resolver fallback.
- Pixiv image hosts stay on ECH (`_prefersEch`, `network_policy_ladder.dart`).
  Their origin addresses (noSni) answer faster but are throttled to tens of
  KB/s inside the wall, so: no cold race; a remembered non-ECH route is used
  only while ECH is cooling down and is dropped otherwise; the image group
  preference records only `ech`. Two consecutive ECH failures (a
  fallback-eligible transport error or an unbuildable ECH tier) cool ECH
  for 1 minute, doubling after every failed retry up to 10 minutes;
  failures during a cooldown do not escalate it, one ECH success clears it,
  and mode/revision changes forget it. A cooling ECH tier moves to the end
  of the walk instead of being skipped.
- Cold image GET/HEAD on a mirror host with no host/group memory races the
  top two tiers (`_raceColdTiers`); the first response wins and the loser
  is drained. API/OAuth and pixiv image hosts stay serial.
- Image and download exits run over HTTP/1.1
  (`RhttpClientFactory.httpVersionFor`), one connection per concurrent
  transfer: a single shared HTTP/2 connection let one throttled flow stall
  every image. Other exits negotiate h2/http1.1 via ALPN. Image exits carry
  a connect budget and the stream guard (15 s headers, 15 s body idle)
  instead of a total timeout.
- Auto image source (`AutoImageSource.race`) fetches the same 1200px
  master from every candidate in parallel and ranks by bytes/second over
  up to 256 KB, timed from the request (first byte included), within a
  10 s total budget. A body cut off by the deadline ranks on what arrived
  if it reached 32 KB, and otherwise loses.
- `PixivDestinationRegistry` matches exact ASCII HTTPS hosts by purpose:
  `app-api.pixiv.net`, `oauth.secure.pixiv.net`, `accounts.pixiv.net`,
  `www.pixiv.net`, `i.pximg.net` and `s.pximg.net` as applicable. Userinfo,
  fragments, IP literals, trailing dots, IDN input and non-443 ports are
  rejected.
- The resolver returns public A/AAAA candidates with source, TTL and
  `NetworkRevision`. A secure-DNS connector changes only the TCP destination;
  the original URI remains responsible for TLS SNI, certificate hostname
  verification and the HTTP `Host` header.
- `PixivFastRouteStore` (`network_fast_route_store.dart`) accepts only the
  allowlisted Pixiv hosts and public IP literals. It persists the last
  successful address, falls back to the bundled bootstrap map after
  restart, and refreshes each host from DoH in the background. Its address
  is a last-fallback connection bootstrap, never a URL rewrite.
- `PixivHttpClient` shares an uncancelled GET in flight only when the URI and
  bearer token match. Cancellation-aware calls remain independent, and the
  response is not retained after completion, so pull-to-refresh never receives
  stale business data from this optimization.
- Only DNS, connect, timeout, reset and handshake-class failures may move a
  request to the next route tier. The business request is the route
  attempt: no separate probe is paid. Each tier is attempted at most
  once; GET/HEAD may also retry on timeout, while POST, the token exchange
  and every request with a possible body advance only when the failure
  proves the request never reached the server (DNS, connect, reset, TLS
  handshake) — a delivered outcome (HTTP response, timeout after send,
  auth/parse/certificate error) is surfaced and never repeated.
- `DohResolver.lookupEchConfig` (`secure_resolver.dart`) caches only
  validated config bytes and front addresses for the clamped HTTPS-RR TTL
  and current `NetworkRevision`. Concurrent calls without cancellation
  share one in-flight query (single-flight); a cancellation-aware call
  remains independently cancellable and only a completed success populates
  the cache. ECH config is queried via Alibaba DoH
  (`https://dns.alidns.com/dns-query`, 223.5.5.5/223.6.6.6) then Cloudflare.
- After a verified `ech`, `dohRealSni` or `noSni` success, the policy may put
  that route kind first for the matching destination group (`cloudflare`,
  `image`, `imageMirror`; the `image` group accepts only `ech`). Group
  memory uses each target host's own addresses and is cleared on transport
  failure, expiry, mode changes and revision changes. The kind (never an
  address) is also persisted per network identity through `RouteKindStore`
  and seeded at warm-up and on revision change, filtered by the same
  per-group rule.
  `insecureNoSni` is never a cold-start first choice; after one success it
  may be promoted by host/group memory like any other kind. The bootstrap
  address map is allowlisted in `network_fast_route_store.dart`.
- `NetworkProbeReport.dnsDisagrees` is diagnostic evidence only. A reached ECH
  response (including HTTP 403/404) or a non-421 empty-SNI response remains
  the actionable conclusion; HTTP 421 keeps empty-SNI unavailable.
- Diagnostics contain canonical host, purpose, route, DNS source, IP family,
  failure, latency, capability and network revision only. They do not contain
  query strings, cookies, tokens, bodies or full addresses.
- Account changes, network revision changes, mode changes and disposal close
  old pools.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Non-Pixiv, suffix, IDN, IP, trailing-dot, userinfo, fragment or non-443 URI | Reject before a request or route is created |
| Direct eligible transport failure in `Automatic` mode | Resolve public candidates for the exact canonical host and try strict candidates |
| Persisted fast address fails with a transport error | Invalidate the address for this process, cool the fast tier for 30 seconds, and move on to the next tier |
| HTTP, auth, rate-limit, parse, cancellation, timeout-after-send or certificate failure | Surface the failure; never re-send the request on another tier |
| POST, token exchange, or body possibly sent | Advance to the next tier only on delivery-proven failures (DNS, connect, reset, TLS handshake); never on timeout or HTTP answers |
| Resolver result has wrong host/revision or no public address | Reject as a secure-resolution failure |
| Account/network/mode boundary | Advance/replace revision and close pools |
| ECH config TTL or revision expires | Drop the config and query again; never reuse stale bytes |
| ECH/no-SNI transport succeeds while DNS sets differ | Report the route as usable and retain DNS disagreement as an extra field |
| One ECH failure on a pixiv image host | Only that request falls back; the next request starts on ECH again |
| Second consecutive ECH failure on a pixiv image host | Cool ECH (1 → 2 → 4 → 8 → 10 min); use the remembered stand-in tier meanwhile, ECH last |
| Persisted non-ECH `image` group kind from an older version | Ignore it at seeding; the next ECH success overwrites it |

#### 5. Good / Base / Bad Cases

- Good: an empty `GET` to a known Pixiv host in `Automatic` mode starts on
  the ECH tier (or the remembered kind), preserves the canonical hostname
  for the HTTP `Host` value, and walks remaining undelivered kinds on
  transport failure; `insecureNoSni` is last. Diagnostics record only route
  metadata.
- Base: an API `429` or certificate mismatch is returned immediately, while
  `DirectOnly` uses the original strict HTTPS client without resolver work.
- Good: after one verified ECH request, a second Cloudflare-host request uses
  its own resolved address with the remembered ECH kind and cached HTTPS-RR
  config inside the same revision.
- Good: API, OAuth, image-cache, download and widget requests all obtain their
  client from `PixivNetworkFactory`; the first Automatic request is
  attempt-first (no preflight) and does not require a `HEAD` probe.
- Good: two uncancelled GETs for the same URI and bearer token share one
  transport flight, while a cancelled caller does not cancel the shared work.
- Bad: rewriting an image URL to an IP/mirror, accepting
  `evil.pixiv.net`, logging the request body, or re-sending a bookmark `POST`
  after its socket may have delivered the body (timeout/HTTP response).
  Treating a DNS mismatch as the primary conclusion after ECH returned HTTP
  404 is also wrong.

#### 6. Tests Required

- Registry tests cover purpose separation and all canonicalization rejection
  cases.
- Resolver tests cover public A/AAAA filtering, answer-name/type matching,
  TTL bounds, response-size limits, cancellation and revision binding.
- Policy tests cover ECH-first cold selection, eligible-only fallback,
  original-host requests, no POST replay, pool invalidation and
  diagnostics redaction.
- ECH resolver tests cover TTL/revision invalidation, defensive result copies,
  uncancelled in-flight sharing, and cancellation that cannot poison the
  shared cache. Policy tests cover group preference, cross-host address
  isolation, insecure-tier non-promotion, and failure invalidation.
- Pixiv image-host tests cover the serial ECH-only cold start, single-failure
  fallback, the cooldown schedule and its cap, reset on ECH success and on
  revision change, ECH as the last resort while cooling, and that origin
  successes are neither shared nor persisted. Mirror tests cover the cold
  race. Factory tests pin HTTP/1.1 for image exits and ALPN elsewhere.
  Auto-source tests cover throughput ranking and partial measurements.
- Probe tests cover DNS disagreement as secondary evidence, ECH HTTP 403/404,
  empty-SNI 421, and the all-paths-failed conclusion.
- Protocol parser tests use repository-owned deterministic bytes (or a
  checked-in fixture builder) and run without ambient files or network I/O.
  A live capture may document provenance in task research, but tests must not
  read `/tmp`, a home-directory capture, or another machine-local path.
- Factory tests prove API, OAuth, image cache and downloads share the policy;
  source audits prove translation, updater and reverse-image paths do not enter
  the Pixiv compatibility connector.
- Fast-route tests prove the bootstrap map is host-allowlisted, persists
  across restart, cools a failed address, and refreshes DoH in the
  background. API client tests prove identical uncancelled GETs are
  single-flight and cancellation is isolated.
- Device evidence must distinguish API 35 MuMu emulator coverage from an
  unavailable API 36 matrix and physical-device coverage.

#### 7. Wrong vs Correct

**Wrong**: rewrite a Pixiv URL to an IP, use a fast address for an unlisted host,
or let a failed bootstrap address delay every subsequent request without a
cooldown.

**Correct**: allowlist the exact Pixiv destination and purpose, retain the
original hostname for the HTTP `Host` value, reuse the bounded fast route only
for the known bootstrap host map as the last Automatic fallback, and walk the
remaining undelivered kinds after a transport failure.

The internal compatibility `insecureNoSni` tier intentionally omits SNI
and certificate verification. It is the last Automatic fallback for the
allowlisted Pixiv hosts in `PixivFastRouteStore`, forced on in production
(`network_providers.dart:29`) with no user-facing switch, and does not
rewrite URLs or the HTTP `Host` value. All other hosts and the earlier
strict ladder tiers retain normal hostname and certificate verification.
The fixed address map is bounded bootstrap state, not a generic proxy.

---

### Novel Typed Markup and Reader Commit Contract

#### 1. Scope / Trigger

This contract applies to Pixiv Novel body parsing, long-text layout and the
horizontal reader. It is triggered by any change to `NovelContentMapper`,
`NovelMarkupParser`, `NovelLayoutEngine` or reader relayout/restore logic.
The parser is a JSON-body adapter, not an HTML/CSS execution environment.

#### 2. Signatures

```dart
NovelMarkupDocument NovelMarkupParser.parse(
  String source, {
  CancelToken? cancelToken,
  NovelMarkupProgressCallback? onProgress,
});
Future<NovelMarkupParseResult> NovelMarkupParser.parseCancellable(
  String source, {
  CancelToken? cancelToken,
  NovelMarkupProgressCallback? onProgress,
});
Future<NovelLayout> NovelLayoutEngine.layoutDocumentCancellable({
  required NovelMarkupDocument document,
  required String contentVersion,
  required Size viewport,
  required NovelLayoutStyle style,
  required Color textColor,
  required Brightness brightness,
  CancelToken? cancelToken,
  NovelLayoutBudget budget,
  NovelLayoutProgressCallback? onProgress,
});
NovelReaderLayoutContext NovelReaderCommitGate.beginLayout({
  required String contentVersion,
  required String? chapterId,
  required int pageIndex,
  CancelToken? cancelToken,
});
```

#### 3. Contracts

- `NovelMarkupToken` is a sealed typed AST family: text, `newpage`, chapter,
  ruby, page/URI jump, Pixiv image, uploaded image, unknown and explicit
  budget-exceeded fallback. Every marker keeps `rawText`, `rawName`, source
  offset and an unmodifiable raw-attribute map.
- `NovelMarkupDocument.blocks` preserves paragraph, page-break and chapter
  boundaries. `NovelParagraph.tokens` and `inlineMarks` expose compatibility
  spans; valid image tokens expose only a validated identifier through
  `NovelImageLoadRequest`, never a URL or file path.
- URI jumps use `PixivDestinationRegistry` with `pixivWeb` purpose. Page jumps
  require a positive decimal page. Image identifiers are allowlisted before a
  shared image/network consumer can resolve them.
- `NovelMarkupBudget` bounds source UTF-16 units, token count, marker size and
  diagnostics. `NovelLayoutBudget` bounds paragraphs, text units, measured
  lines, pages and chunk size. Async work yields at chunk boundaries and
  reports monotonic progress.
- `NovelReaderCommitGate` carries content version, chapter ID, selected page,
  generation and cancellation from the layout request to the commit. A late
  result may not update `_layout`, page count, `PageController` or history
  anchor after a newer generation, content/chapter change or disposal.
- The reader chrome runs off one stage-owned `AnimationController`. The
  user's intent (`_chromeVisible`) and the rendered state
  (`_chromeHidden == controller.isDismissed`) are separate; the passive
  progress hint exists in the tree only while the controller is dismissed,
  so it can never paint under the exiting bottom bar. Reduced-motion jumps
  the controller instead of animating.
- The novel-series provider is an `autoDispose` family kept alive by the
  reader stage itself (`ref.watch` in the stage build — a build-time
  `ref.listen` re-subscribes on every rebuild with a dispose gap that
  refetches, and a manual subscription does not hold autoDispose). One
  fetch happens per reader session; chrome reveals reuse it. Riverpod's
  default failure retry is disabled on the provider (`retry: (_, _) =>
  null`) so the localized error strip persists until the user taps retry,
  which is the only path that invalidates and refetches. The series strip
  is a fixed 48 dp `_SeriesBarRow` in all four states — loading, failure
  with retry, missing-current-entry (navigation dead-ended, no watchlist
  cursor write) and data — so it never resizes under the bottom chrome.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| `[[newpage]]` | Emit a page-break token/block; it has no payload or navigation side effect |
| `[[chapter:title]]` | Emit a chapter token/block; layout starts its heading at a page boundary |
| malformed ruby/marker or unknown name | Emit a typed invalid/unknown token, preserve the raw marker and record a bounded diagnostic |
| foreign/non-HTTPS jump URI | Emit an invalid `NovelJumpToken`, show raw fallback, and never navigate |
| non-positive Pixiv ID or path/URL uploaded-image identifier | Emit an invalid typed image token and no load request |
| source/token/layout budget exceeded | Emit/throw explicit budget state; never return a silently truncated successful body |
| cancel, superseded generation, changed content/chapter or disposed reader | Discard result without UI/store/history commit |

#### 5. Good / Base / Bad Cases

- Good: parse `[[rb:漢字 > かんじ]]`, a positive page jump and an exact
  `https://www.pixiv.net/...` jump into typed tokens while preserving Unicode
  display text and raw attributes.
- Base: a long body is measured in finite chunks; progress reaches complete,
  the layout cache is keyed by content/style/viewport, and a new font size
  cancels the old calculation before its commit.
- Bad: regex-replace every marker, execute body HTML, turn a foreign URI into
  a WebView route, resolve an image token into an arbitrary file/URL, or catch
  cancellation and publish the partial old-generation pages as new content.

#### 6. Tests Required

- Parser fixtures assert every typed token, raw attributes, Unicode, empty
  paragraphs, nested/unterminated markers and invalid jump/image fallbacks.
- Budget tests assert finite token/source/diagnostic counts, explicit overflow,
  chunk yields and progress; layout tests assert page/chapter boundaries,
  cache identity, max limits and cancellation.
- Gate tests assert old content/chapter/disposed results do not run their
  action, while a current result commits and preserves a changed page choice.
- Existing reader widget tests retain horizontal `PageView`, 30% tap zones,
  stable anchors and percentage behavior.

#### 7. Wrong vs Correct

**Wrong**: let `NovelContentMapper` remove any `[[...]]` substring, pass its
payload to an HTML/WebView or arbitrary URL loader, and call `setState` after
an async layout without checking content/chapter generation.

**Correct**: scan into immutable typed tokens with visible fallback and raw
diagnostics, expose only allowlisted image/jump targets, run bounded
cancel/yield-aware layout, and let `NovelReaderCommitGate` authorize the one
complete current-generation commit.

### Account-Owned Mutation Contract (`MutationEnvelope`, `MutationLedger`)

#### 1. Scope / Trigger

This contract applies to every authenticated write that can outlive a widget
callback, including Bookmark, Follow, Comments and the future Profile edit
adapter. It is required when a request can overlap a duplicate tap, reverse
operation, account/credential change or provider disposal. It does not create
a durable offline queue.

#### 2. Signatures

```dart
class MutationEnvelope {
  final String accountId;
  final String entityType;
  final String entityId;
  final String operation;
  final String clientMutationId;
  final DateTime createdAt;
  final MutationOwner owner;
  final int revision;
}

MutationEnvelope? MutationLedger.begin({
  required MutationBoundary boundary,
  required String entityType,
  required String entityId,
  required String operation,
  String? ownerId,
});
void commit(MutationEnvelope envelope);
void fail(MutationEnvelope envelope, Object error);
bool cancel(MutationEnvelope envelope);
```

Feature stores wrap the envelope in their typed operation and expose only the
cancel signal to their repository adapter. `MutationLedger` owns active
identity, dedupe, supersede, cancellation and bounded metadata-only discard
events; it never persists request bodies or credentials.

#### 3. Contracts

- A begin is allowed only with the current usable account. The exact dedupe
  key is `(accountId, entityType, entityId, operation)` (C1: no
  `credentialRevision` on the envelope — same-account token refresh does not
  invalidate an in-flight write). An active exact duplicate is
  suppressed, while another operation on the same target cancels and records
  the old owner as `superseded` before registering the new revision.
- Feature stores keep the last server-confirmed value separate from pending
  presentation state. Only a still-active envelope can commit; a late result
  cannot update the confirmed value, another account, or a disposed provider.
- Terminal status is observable as `idle`, `pending`, `confirmed`, `failed`,
  `cancelled` or `superseded`. Cancellation clears the pending marker without
  manufacturing a server-confirmed change; ordinary failures preserve the
  previous confirmed value and retain the classified error.
- Account switch, logout, credential-refresh invalidation and owner disposal
  cancel active owners. A provider rebuild may
  reopen an empty ledger to retain bounded discard telemetry, but it never
  resurrects a pending request.
- Bookmark, Follow and Comment repository calls pass the envelope's
  `CancelToken` and set `allowAuthReplay: true` (C2). `PixivHttpClient.post`
  defaults to `allowAuthReplay: false`. On an explicit auth rejection (401, or
  400 `invalid_grant`) the opted-in mutation may refresh once and replay the
  original body exactly once (`maxRetries = 1`); a second 401 is surfaced
  without another replay. Timeout, reset, or an unknown outcome never replay
  here. Transport `canReplay` remains GET/HEAD with an empty body only.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| no usable account or invalid entity ID | reject before registering a mutation; surface the normal typed error |
| exact active duplicate | return `null`; keep the original request and pending state |
| opposite operation on the same target | cancel old owner, record `superseded`, and accept only the new envelope's result |
| account/network boundary changed | cancel and discard the old envelope; never write the new account's store |
| provider/page disposed | cancel owner; late completion is discarded and does not publish an API error |
| 401 or invalid refresh | use shared auth policy; invalid refresh becomes observable `ApiUnauthorized` and no mutation replay |
| 403/404/429/network/5xx | preserve classified error (`ApiRateLimited.retryAfter` included), clear pending, retain confirmed state |

#### 5. Good / Base / Bad Cases

- Good: a delayed bookmark add carries account A's envelope, a reverse delete
  supersedes it, and only the delete's server confirmation updates the shared
  bookmark/entity stores.
- Base: a Bookmark/Follow/Comment POST with `allowAuthReplay: true` refreshes
  once and replays the original body exactly once; a second 401 is surfaced.
  The default (`allowAuthReplay: false`) still never replays a body.
- Bad: mark a bookmark true when the request starts, retry a possibly-sent
  comment body after refreshing, or keep an unscoped pending map that becomes
  visible after switching from account A to B.

#### 6. Tests Required

- Envelope tests assert all identity fields, owner cancellation, no secret in
  diagnostics, exact dedupe, reverse supersede and bounded discard telemetry.
- Store/action tests use delayed fakes to assert non-optimistic pending,
  server-confirmed commit, failed/429/401 state, cancellation, disposal,
  account switch, late response suppression, cancel-token forwarding and
  cross-page synchronization for Bookmark, Follow and Comments.
- HTTP client tests assert one shared refresh; a POST with the default
  `allowAuthReplay: false` does not replay its body; an opted-in mutation
  (`allowAuthReplay: true`) replays once then surfaces a second 401. Error
  tests retain `Retry-After` and classified 403/404/5xx/network outcomes.
- Full test, analyze, task validation and `git diff --check` are required;
  Android evidence must state `MuMu emulator-tested, not physical-device-tested`
  and distinguish API 35 coverage from any unavailable API 36 coverage.

#### 7. Wrong vs Correct

**Wrong**: use a widget-local boolean as server truth, retry every failed
mutation through a generic queue, or let a late future call `commit` after the
account boundary changed.

**Correct**: create one immutable account/revision envelope, pass its cancel
signal to the existing adapter, gate every terminal transition against the
active owner, publish only server-confirmed data, and keep classified failure
or discard telemetry visible without persisting a pending write.

### Download and Ugoira Job Recovery Contract (`DownloadManager`, `UgoiraExportJob`, `lib/core/download/`)

Download work is an account- and policy-scoped job, not a widget-local future.
Every submission captures an immutable `(accountId, DownloadDestination,
illust/page/frame, format)` snapshot. The recovery owner is
`accountId + DownloadDestination.identity` (C4); it does not include a
process-local `credentialRevision`. A product submission must have a usable
account. The built-in destination identity is `album:parfait`; a persisted
legacy `'Pictures/Parfait'` path migrates to `DownloadDestination.builtin`
and matches that same owner. Legacy in-memory test submissions may remain
unowned only when the manager is explicitly configured for that test boundary.

The manager exposes `queued`, `running`, `canceling`, `finalizing`,
`succeeded`, `failed`, `canceled`, `retryable` and `orphaned`. Only the first
three successful/failed/canceled outcomes plus `orphaned` are terminal;
`retryable` requires an explicit user retry and is never opened automatically
after recovery. Each
job emits one terminal event. Groups capture one submission boundary and
aggregate child states without replacing child ownership.

Group integrity is an explicit runtime invariant: each task belongs to the
group captured in its submission snapshot, a group's `jobIds` contain only
its current tasks, and removing the last child removes the group. A fresh
submission replaces an existing terminal task for the same identity; when
the old attempt has a resumable output, its resume anchor and frozen name
transfer to the new attempt. `submitGroup` returns one task per request plus
an optional group snapshot; a null group means every request deduped onto a
live task from an earlier group. Retrying after an account change may dedupe
into another live group, but never adds that task to the old group.

Pending output is owned by an opaque owner record containing the job and
account identity; it must not expose temporary filesystem paths or
credentials. MediaStore writes use pending rows and become visible only after
successful finalize. Abort, finalize and terminal cleanup are idempotent and
must be guarded against duplicate callbacks. Owner checks run before output
creation, before transport/write/finalize, and while streaming. A provider
returning `null` after logout is a boundary change, not permission to fall
back to the submission-time context.

On process recovery, only a record whose job, owner, account and
destination identity exactly match the current context may be restored as
`retryable`; recovery does not auto-start it (C5). Mismatched, invalid or
unknown records become observable `orphaned` records. Pending MediaStore rows
are cleaned only through an exact owner match (C22); unmatched pending rows
are reported and never blindly deleted. Cleanup failure remains visible in
recovery diagnostics and in the Download Tasks page (`/downloads`,
`DownloadTasksPage`),
where `retryable` and `orphaned` jobs stay user-visible. A crash observed in
`finalizing` is treated as `orphaned` rather than retried, because the output
may already have become visible. Group membership is rebuilt from child
snapshots before the recovered group status is exposed. HTTP `Retry-After` and the
stable auth/rate/network/storage/permission/decode/resource failure classes
are retained in the job snapshot without storing request headers or tokens.

Before recovery restores any jobs, records are deduplicated by `dedupeKey` and
only the newest `snapshot.submittedAt` is kept. Older records are removed,
their unfinished pending outputs are cleaned through their exact owner, and
their job IDs are reported in `DownloadRecoveryReport.supersededJobIds`; old
groups are never registered.

A submission snapshot may also carry optional **display fields** —
`thumbnailUrl` and `totalPages` — that let the management list render the
work thumbnail and a page label without re-fetching the entity. They are
presentation-only: they never enter `dedupeKey` or owner checks, and
records persisted before they existed decode them as `null` and must still
recover — the row then falls back to the placeholder and the bare file
name.

The snapshot also freezes the resolved `displayName` at submission time and
persists it in the recovery record, so a restored job writes the file name
the user submitted even when the naming rule or entity fields (title,
artist, series data) would resolve differently today. Stored names are
re-validated on decode (`validateDisplayName`); a record written before the
field existed carries no key and falls back to recomputing the name from
the restored request, while an invalid stored value fails decoding as
`DownloadRecoveryDataException` like any other corrupt field (the load
fails and `recover()` reports it as the recovery error). `retry` resubmits
with the job's frozen name instead of recomputing it: the restored request
does not carry every template input (`{author_id}`, `{w}`, `{h}`, series
fields), so a recomputed name would come out with empty segments.

Ugoira export follows the same owner fence, bounded frame/pixel/output
budgets, cancellation checks and one pending output. It emits `finalizing`
before the sink finalize call and publishes success only after finalize
returns. API 29+ pending-row behavior is verified through the Android bridge;
API 35 MuMu evidence must remain separate from any unavailable API 36 run.

### Startup, navigation, and residual `credentialRevision` (09-01 C)

**C1 residual surface**: `credentialRevision` is not a global world version.
It is defined and incremented on `AccountStore` (`account_store.dart`) and
consumed only by the home-widget domain as an account *display-state* re-key
(name/avatar/set; see `widget_coordinator.dart` and `widget_feed_loader.dart`).
Feeds use generation + cancel. Mutations use `accountId` + operation identity.
Download/Ugoira use `accountId + DownloadDestination.identity`. Profile drafts
are account-id scoped.

**C5 bootstrap**: `ParfaitApp.initState` reads `downloadManagerProvider`
(`app.dart`). That constructs the manager and fires a one-time recovery scan.
Recovery never auto-resends a download; the user retries from the Download
Tasks page (`/downloads`).

**C6 widget gate**: `WidgetCoordinator.start` / `ensureStarted` consult
`WidgetInstanceGate` (`hasAnyWidget` on Android). No live instance means no
account subscription, no feed load, and no WorkManager schedule. App lifecycle
resume re-checks the gate so a widget added while the app is alive starts
without a restart.

**C7 lazy home tabs**: `HomePage` keeps `_visitedTabs` + `_tabChildren`. Cold
start builds only the current tab. The first visit to another tab inserts it
into the `IndexedStack` and keeps it alive, so scroll position and controller
state survive a switch back. Unvisited tabs are `SizedBox.shrink()` and issue
no feed requests.

**C8 user deep links**: a `UserRoute` delivered to `HomePage` calls
`showUserPage`. An `UnknownRoute` from a VIEW intent is rejected by
`IntentRouter` as `RejectedAndroidIntent`; the home page shows the existing
rejection snackbar and stays on the current page.

**C14 ladder**: `_runLegacyLadder` is deleted. `runLadder` is attempt-first
and has no `probe` parameter. Route-order and replay rules live in the
Restricted Pixiv Network Policy Contract above — do not duplicate them here.

**C21 account removal**: `AccountStore.removeAccount` calls
`HistoryRepository.clearOutbox(accountId)` only. Local history rows stay;
the user still clears them through the existing history UI. Re-adding the
same account must not flush an outbox left from the previous lifecycle.

### Android Platform Boundary Contract (`IntentRouter`)

Android platform messages are untrusted input. `AndroidIntentChannel` may
forward only action, opaque URI, MIME, read-grant and bounded-size metadata;
it must never forward cookies, credentials or file contents. `IntentRouter`
then performs the final typed validation: VIEW accepts only the exact Pixiv
schemes/hosts/paths, SEND requires the single `EXTRA_STREAM` content URI,
explicit read permission, a concrete `image/*` subtype and a bounded positive
size. Unknown actions, extras, URI shapes and malformed channel payloads are
observable rejections, not empty routes.

The login WebView does not police navigation. Whatever Pixiv's own login
endpoint chooses to load — including third-party identity providers and
`oauth.secure.pixiv.net` — is allowed to load, because a navigation allowlist
can only reject destinations Pixiv itself selected. The real boundary is the
authorization code: it is bound to a live one-use PKCE session, `state` is
compared when the callback carries one, and a missing, empty or duplicated
`code` is rejected. Callback path shape and unknown callback parameters are
not grounds for rejection; the real callback is
`pixiv://account/login?code=...&via=...`.

Only `AppLifecycleState.detached` terminates a PKCE session. Reading a
verification code, using a third-party IdP or a full-screen IME all leave the
foreground, so any stricter lifecycle rule breaks login. Recoverable errors
keep the session and say so; only unrecoverable ones abort it.

Root back handling follows the Predictive Back Contract in
component-guidelines.md: the Recommended root delegates to the system, and
every other branch root returns to Recommended.

Android evidence must identify the verified MuMu serial, state/API level,
proxy/VPN state, WebView provider, route and failure scope. `MuMu
emulator-tested, not physical-device-tested` is required wording; API 35
results do not satisfy an API 36 criterion and must retain an explicit API 36
blocker when no API 36 image is available.

### Reverse Image Input and Provider Contract

Reverse-image search has one controller for both the in-app picker and Android
`ACTION_SEND`. The platform adapter may carry only opaque `content://`
metadata and an app-private temporary-file handle; image bytes, cookies and
provider credentials never cross into diagnostics, snapshots or ordinary
settings. The controller validates the concrete MIME type, file signature,
dimensions, pixel budget and encoded-size limit before exposing a preview, and
owns exactly one temporary file until every terminal path has attempted
cleanup.

Provider implementations expose a typed capability (`structuredApi`,
`interactiveWebView` or `unavailable`) and typed outcomes. A provider cannot
turn an HTML/challenge response into result cards, silently scrape a web page,
or return an empty success when credentials, ToS/privacy review or capability
evidence is missing. There is no native result list: a definitive no-match
page is a bare `ReverseImageSearchSuccess`, and every other result shows in
the engine's own page. The controlled WebView and external opens accept only
strict HTTPS destinations. An unavailable
provider is rendered as a visible terminal failure with retry/cancel behavior;
it is not a hidden mock.

The platform boundary rejects non-content URI shapes, missing read grants,
unknown MIME/size metadata and paths outside the owned cache. Cancellation,
provider failure, route disposal and cleanup failure remain observable, and a
new upload may not reuse a previous flow's temporary file.

### Profile Edit Contract (`ProfileEditController`, `lib/core/profile/`)

Profile editing is an account-scoped draft, not a second user cache. A draft
captures the account id, authoritative
base values and the typed `ProfileCapabilities` returned by the selected
official route (C1: no `credentialRevision` on the draft). `ProfilePatch`
contains only fields that differ from that base;
unsupported dirty fields remain visible as field errors and are never sent.

The controller checks the owner before loading, submitting and committing a
response. Account-id changes cancel the request,
release owned image selections and discard late results. A confirmed response
is committed persistence-first to `AccountStore`, then merged into the
canonical `UserStore`; verification-pending, field-error, cancellation and
failure outcomes never update confirmed metadata. Store commits must recheck
that the current account owns the returned user.

Current passwords are an ephemeral submit input. They must not be part of
`ProfileDraft`, persistence, prefilled form values or failure diagnostics, and
must be cleared in the submit request's `finally` path. Selected profile images
are owned handles with bounded MIME/signature/dimension/size validation and
exactly-once cleanup on replacement, cancel, dispose and every terminal
response.

The approved write path is the in-app `PixivWebProfileEditRepository` transport
(see `.trellis/spec/backend/in-app-web-profile.md`). `ProfileEditChannel.web`
names that HTTP adapter, not a profile-edit WebView. The page keeps the native
form and Save button; the ordinary OAuth login WebView only supplies the
`www.pixiv.net` session cookie. Save must issue real HTTP through
`PixivPolicyHttpClient` / `PixivDestinationPurpose.pixivWeb`. Missing
`PHPSESSID` is an explicit unavailable outcome, never a local-only success,
mock, or read-only downgrade. Do not open a second WebView for profile
editing.

### Android Home Widget Snapshot and Background Contract

#### 1. Scope / Trigger

This contract applies to the Flutter-to-Android home-widget boundary. It is a
cross-process render cache, not a second account or credential store. It covers
Recommend/Refresh `RemoteViews`, cold-start background generation,
account/credential/network ownership and widget click routing.

#### 2. Signatures

```dart
Future<void> WidgetSnapshotStore.write(
  WidgetSnapshot snapshot,
  Map<String, List<int>> images,
);
Future<void> WidgetSnapshotStore.clear();
Future<WidgetFeedResult> WidgetFeedLoader.load();
```

```kotlin
fun WidgetUpdateCoordinator.ensurePeriodic(
  context: Context,
  accountRevision: Long = 0,
)
fun WidgetUpdateCoordinator.requestOneShotRefresh(context: Context): Boolean
```

The Dart background entrypoint is `widgetBackgroundMain`; native
`WidgetBackgroundWorker` invokes it through a controlled Flutter engine and
returns a typed outcome (`written`, `no_account`, `auth_required` or
`transient`). Native widget code never creates an API, credential, DNS, proxy
or TLS client.

#### 3. Contracts

- `active.json` is schema version `1` and contains only `schemaVersion`, a
  truncated non-reversible `accountKey`, non-negative `accountRevision`,
  `generatedAtMs`, and up to eight items. Each item contains positive
  `illustId`/`userId`, bounded title/user name and a file name, never a URL,
  cookie, token, credential or plaintext account identifier.
- The snapshot directory contains `active.json`, `.write.lock` and `images/`.
  Writers stage uniquely named image files and a temporary pointer, then flip
  `active.json` last. Native reads only files below this directory and accepts
  only the referenced image names.
- A successful generation captures account id and credential revision before
  the request and rechecks both immediately before publication. Account or
  credential changes make the result `superseded`; they must not publish or
  clear the newer owner's state. The `auth_required` branch compares the
  account id only: handling a 401 is what marks the account as needing
  re-auth, which advances the credential revision, so comparing revisions
  there would classify every real auth failure as `superseded` and leave stale
  artwork on the home screen.
- Covers: an in-app refresh first asks the image worker's disk cache
  (`cachedImage`), with the same byte cap as a download; the background
  isolate has no worker and downloads every cover.
- `no_account` and same-account `auth_required` clear the snapshot. A
  transient network, parse, image or storage error retains the same-account
  last-good snapshot and uses bounded WorkManager retry. No result is changed
  into an empty success.
- Periodic work uses one constrained unique name per widget family and account
  revision with `KEEP`; refresh clicks use one-shot `KEEP`. Work is tagged for
  cancellation when the last widget is removed. The minimum interval and
  retry count remain bounded; no resident timer/service is introduced.
- Pending intents are explicit, immutable, non-exported and data-unique per
  widget slot. The accepted deep-link shape is exactly
  `parfait://illusts/<positive-id>`; extra query/fragment/authority forms
  are rejected before navigation.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Missing, malformed, unknown-version or oversize snapshot | Render the explicit open-app/empty state; never render partial fields |
| Missing, unreferenced, unsafe or oversize image | Keep last-good generation on write failure; native render falls back to open-app state |
| Account not ready or credential missing | Clear render state and report `no_account` only when absence is established; unreadable storage remains transient |
| Account or credential revision changes in flight | Return `superseded`; do not clear or publish across the boundary |
| HTTP/auth/rate/parse/network/image/storage failure | Preserve classified failure and same-account last-good; retry only through bounded WorkManager policy |
| Widget resize/update storm | Coalesce unique work with `KEEP`; do not cancel an in-flight generation on every system update |
| Last Recommend/Refresh widget deleted | Cancel the family schedule, and cancel all widget work only when both families are absent |
| Unsupported click/deep-link or non-positive id | Reject without navigation and surface the existing failure state |

#### 5. Good / Base / Bad Cases

- Good: Flutter downloads covers through the shared exact-host image policy,
  writes a secret-free generation, and native renders it after verifying the
  account revision and bounded bitmap budget.
- Base: a cover request times out while an older generation belongs to the
  same account; the older generation remains visible and one bounded retry is
  enqueued.
- Bad: copying a refresh token into `SharedPreferences` or WorkData,
  privatizing the compatibility route in native code instead of using the
  shared policy, deleting `active.json` before a new generation is staged, or
  replaying a stale account's result after an account change.

#### 6. Tests Required

- Snapshot tests assert schema/version, integer and text bounds, account-key
  binding, age/corruption rejection, exact image references and no secret
  fields.
- Store tests inject a failed second-image stage and assert the previous
  pointer and images remain readable, while temporary staged files are not
  published.
- Loader tests use delayed account/credential revisions to assert
  `superseded`, same-account last-good retention, and account-invalid clear.
  One test must pin that a real 401 for the current account returns
  `auth_required` and clears the snapshot, never `superseded`.
- Android JVM tests assert integer-overflow-safe bitmap budgets, stale-time
  overflow handling, provider export flags, unique family/revision work names,
  `KEEP` policies and bounded retries.
- MuMu evidence must identify the verified serial, API level, proxy/VPN and
  NAT/route scope, and say `MuMu emulator-tested, not physical-device-tested`.
  API 35 evidence does not satisfy an API 36 acceptance criterion; absent API
  36 capability evidence remains an explicit blocker.

#### 7. Wrong vs Correct

**Wrong**: let native read the secure account database, keep a token in
`RemoteViews`, clear the active pointer before downloading replacement images,
or treat every background exception as an empty successful widget.

**Correct**: publish a bounded, versioned, secret-free snapshot atomically
from the shared Dart auth/network path, gate publication on account and
credential revisions, preserve same-account last-good on transient
failure, and make native rendering fail closed with unique bounded work.

### Signed Updater and Distribution Flavor Contract (`UpdateService`, `lib/core/updater/`)

#### 1. Scope / Trigger

This contract applies to the About update flow and its Android flavor
boundary. It covers signed release metadata, app-private APK downloads,
unknown-source installation, process recovery, and the F-Droid no-network
path. The updater is not a Pixiv API or image-download route.

#### 2. Signatures

```dart
Future<UpdateCheckResult> UpdateService.check({
  UpdateChannel channel = UpdateChannel.stable,
});
Future<UpdateApplyResult> UpdateService.apply(
  UpdateRelease release, {
  bool confirmed = false,
});
Future<void> UpdateService.cancel();
Future<UpdateCapability> UpdateService.capability();
UpdateManifest UpdateManifest.parse(String raw);
```

```kotlin
// Both product flavors expose this channel; only the GitHub source set
// implements verification, APK validation and installer intents.
parfait/updater:
  getCapability -> { flavor, enabled, storeManaged }
  getPlatformInfo -> { packageName, version, versionCode,
                       signingCertificateSha256 }
```

#### 3. Contracts

- A manifest is bounded to 64 KiB and must contain exactly `schema`,
  `repository`, `tag`, `channel`, `version`, `versionCode`, and `asset`.
  The repository is `Lopution/Parfait`, the tag is `v<version>`, and the
  asset contains an exact positive `size`, lowercase 64-character `sha256`,
  the fixed package name and lowercase installed-certificate digest.
- Manifest and detached signature are fetched only from exact HTTPS GitHub
  release hosts. Redirects are manual, bounded, and revalidated at every hop;
  manifest bytes are verified by the compile-time Ed25519 public key before
  parsing or exposing a release. Missing/invalid key or signature is a typed
  invalid result, never an available update.
- `UpdateService.apply` requires `confirmed == true`, is single-flight, and
  uses the exact signed URL through `DownloadManager` target `updaterApk`.
  The stream writes to app-private `files/updates/`; final length, SHA-256,
  package and APK signer are checked before `FileProvider` installation.
- Durable update state contains only `downloadId`, version/versionCode,
  signed asset identity, package/certificate digests and the owned path. On
  restart it is reused only when the same manager task, target, URL, display
  name and verified file still match. A missing or mismatched task/file is
  cleaned and the next download requires the same explicit user confirmation.
- The GitHub flavor declares the minimum install permission and requests the
  Android per-source grant before an install intent. The intent uses a
  `content://` URI, read grant and the controlled `updates/` FileProvider
  path. F-Droid declares no install permission and its provider checks the
  native store capability before constructing any updater `HttpClient`.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| F-Droid capability or store-managed build | No manifest/signature/APK network request; render the store explanation and no inert update button |
| Unknown schema/keys, malformed semver/channel/tag, oversize body or foreign URL | Reject before typed release creation; keep `release == null` |
| Missing/invalid signature or missing public key | Return `invalid`; never expose `UpdateAvailable` |
| HTTP 429, socket/timeout or bounded redirect failure | Return rate-limited/offline/typed failure; do not retry through another route |
| Current version is equal/newer or stable sees beta | Return `noUpdate`/`prerelease`; do not install |
| User has not confirmed | Return `requiresConfirmation`; no download or install call |
| Size/hash/package/signer mismatch | Abort and delete the owned APK; return a typed failure |
| Process restart with exact durable task and file | Reattach/verify that task; never auto-resume a different URL or hash |
| Unknown-source permission absent or installer rejects | Surface permission/failure; retain only the explicitly recoverable owned state and never claim installation success |

#### 5. Good / Base / Bad Cases

- Good: a signed manifest points to an allowlisted `.apk`, the exact task
  streams it into `files/updates`, all identity checks pass, and the user
  confirms before the system installer receives a content URI.
- Base: the process restarts after a partial updater task; recovery finds the
  same task identity as `retryable`, and an explicit apply action retries that
  exact task after clearing the partial file.
- Bad: treating a GitHub API response, release title or redirect alone as a
  trust root; accepting a public key supplied by the manifest; copying the APK
  to shared storage; sending a F-Droid check request; or silently reinstalling
  after an unknown-source denial.

#### 6. Tests Required

- Manifest tests assert exact keys/schema/repository/tag/channel/semver,
  bounds and strict asset URL policy; service tests cover valid, invalid and
  missing signatures, 429/offline, no-update and stable-prerelease states.
- Download tests assert streaming sink usage, exact size/hash cleanup,
  package/signer verification delegation, explicit confirmation, single-flight
  check/apply and exact durable recovery identity.
- Flavor contract tests assert product flavors, compile-time fields, merged
  manifest permission differences, source-set separation, FileProvider paths
  and F-Droid About store text without a button.
- Android builds must run `assembleGithubDebug`, `assembleFdroidDebug`,
  `assembleGithubRelease` and `assembleFdroidRelease`; device evidence must
  identify flavor, API, proxy/VPN state and whether the installer permission
  branch was actually exercised.

#### 7. Wrong vs Correct

**Wrong**: fetch the latest GitHub release JSON, trust its APK URL, download
the bytes into shared storage, and call `ACTION_VIEW` without checking the
installed certificate or asking the user.

**Correct**: gate by compile-time distribution capability, fetch bounded
manifest/signature over exact HTTPS hosts, verify the detached signature before
parsing, stream through the updater-owned DownloadManager target, verify every
identity field, require confirmation, and install only through a controlled
content URI with an observable Android permission result.

## Common Mistakes

- Keeping a page-local copy of an entity, bookmark, or follow flag instead of
  reading the canonical store.
- Rebuilding a router or feed family on token refresh and losing tab stacks or
  scroll state.
- Letting a repository merge shared entities before the feed commit gate has
  accepted the request generation.
- Using a second controller for a framework-owned animation, refresh, or tab
  transition.
- Publishing a stale account response after the provider or route has been
  disposed.
- Loading a Pixiv image outside `PixivImage`/`PixivImage.preload`, or
  warming one without a hold or window in the demand of the pipeline that
  will show it: nothing can promote the fetch, and it may be dropped.
