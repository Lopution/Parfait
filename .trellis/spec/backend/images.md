---
prefix: IMG
applies_to:
  - lib/core/image/**
  - lib/core/ugoira/**
  - lib/app/pixiv_image.dart
  - lib/app/image_tier_cache.dart
  - lib/app/widgets/image_load_progress.dart
reviewed: 2026-10-19
---

# Image pipeline and animated media

## Contents

- [One pipeline](#one-pipeline)
- [Demand, lanes and retry](#demand-lanes-and-retry)
- [Tests](#tests)
- [Ugoira](#ugoira)

## One pipeline

### IMG-01 Every Pixiv image goes through PixivImage and the worker
- **Rule:** Every Pixiv CDN image, originals included, is painted by
  `PixivImage` or warmed by `PixivImage.preload`; both load through the
  image worker isolate. Never paint `WorkerImageProvider` directly. There
  is no fallback pipeline: `PixivImage` must sit under a `ProviderScope`.
- **Why:** A surface painting the provider directly held no demand, so a
  prefetch queued for it was never promoted, and it skipped retry,
  progress and the decode history.
- **Check:** `test/pixiv_image_pipelines_test.dart`
- **Code:** `lib/app/pixiv_image.dart`, `lib/core/image/image_worker.dart`

### IMG-02 Progress is a subscription by URL
- **Rule:** Load progress comes from `ImageWorker.watchProgress(url, …)`,
  never from a flag on the fetch or the image stream's chunk events. Every
  worker that starts, a replacement included, is told every watched URL.
- **Why:** A card-tap warm-up resolved the entry first, so the detail
  page's ring attached later never saw a byte.
- **Check:** `test/image_worker_test.dart` "progress reaches each watcher of a URL until it stops", `test/image_load_progress_test.dart` "PixivImage reports the download it is painting"
- **Code:** `lib/core/image/image_worker.dart`

### IMG-03 A decode is identified by URL and width
- **Rule:** Decode identity is `(url, decode width)`. A stand-in (Hero
  hand-off, tier underlay) paints only a decode that actually completed;
  never a guessed width. A request whose own width has not decoded paints
  the URL's uncapped decode or its last decode when that is at least as
  wide.
- **Why:** A guessed width is another cache entry and fetched again; a
  detail page returning from the viewer's wider preview dropped to its
  placeholder.
- **Check:** `test/pixiv_image_pipelines_test.dart` "a card frame stands in while the original loads" "a wider decode paints a narrower request at once"
- **Code:** `lib/app/pixiv_image.dart`, `lib/app/image_tier_cache.dart`

### IMG-04 A dead worker is replaced a bounded number of times
- **Rule:** The isolate starts on the first fetch. A dead worker fails its
  pending requests with `ImageWorkerUnavailable` and is replaced on the next
  fetch, at most `maxStarts` per session; every death goes to the crash
  log. Snapshots for diagnostics never start a worker.
- **Why:** An endless respawn loop burned the battery when the isolate
  crashed on start.
- **Check:** `test/image_worker_test.dart` "a worker that dies is replaced on the next request" "failed starts are retried until the budget is spent" "a snapshot never starts a worker"
- **Code:** `lib/core/image/image_worker.dart`

### IMG-05 Downloads reuse the worker's disk cache
- **Rule:** Downloads and the viewer's save read cached files through `ImageWorker.cachedFile` before going to the
  network; a miss or eviction falls back with a log line.
- **Why:** Saving an image already on screen downloaded it again.
- **Check:** `test/image_worker_test.dart` "a cache lookup starts the worker and answers from its disk"
- **Code:** `lib/core/image/image_worker.dart`, `lib/core/download`

### IMG-12 The worker writes files without an IOSink
- **Rule:** Code in the image worker writes files through an awaited
  `RandomAccessFile` (`open`, `writeFrom`, `close`), never
  `File.openWrite`. `DiskImageCache.store` recreates its directory before
  each write and cancels the body when it cannot write.
- **Why:** An IOSink whose file cannot be opened reports the error as
  uncaught and never completes its flush. An uncaught error is fatal in
  the worker, so clearing the cache while the app ran killed the worker on
  the next image.
- **Check:** `test/disk_image_cache_test.dart` "a directory cleared while the app runs is recreated by the next write" "a write the cache cannot hold fails alone and lets go of the body"
- **Code:** `lib/core/image/disk_image_cache.dart`

## Demand, lanes and retry

### IMG-06 Widgets hold their URL; unwanted fetches are dropped
- **Rule:** Every mounted `PixivImage` holds its URL in
  `ImageWorker.demand` (new before releasing old). A URL stays wanted for
  500 ms after release. An in-flight request nobody wants is cancelled: a
  queued fetch drops with `ImageFetchDropped`, a streaming one finishes,
  except an original (`/img-original/`): its first range and every
  further range stop, its partial file is deleted, and its URL leaves the
  books at once, so asking again starts a fresh flight. A first `hold` or
  any `holdFor` promotes a queued background fetch.
- **Why:** Flinging a feed queued hundreds of images the user never saw;
  Hero flights and re-layouts briefly release and re-hold. Originals the
  user swiped past in the viewer kept downloading megabytes each and
  slowed the one on screen; a thumbnail is done in a moment, and stopping
  it would cost the next one a new connection.
- **Check:** `test/image_fetch_scheduler_test.dart` "a foreground interest promotes a queued background fetch" "a transfer already streaming is never interrupted by a cancel" "an original nobody wants stops; one still shared runs on", `test/image_worker_host_test.dart` "an original nobody wants stops, and asking again starts afresh", `test/image_demand_test.dart` "a released URL stays wanted for the grace period"
- **Code:** `lib/core/image/image_demand.dart`, `lib/core/image/image_fetch_scheduler.dart`, `lib/core/image/image_worker_host.dart`

### IMG-07 Two lanes: foreground 8, background 2
- **Rule:** Background priority is only for `PixivImage.preload` without a
  user request; everything else is foreground. A user-asked preload (card
  tap, opening the viewer) is foreground with a 10 s `holdFor`. A disk hit
  answers before any lane.
- **Why:** Prefetches starved visible images of transfer slots.
- **Check:** `test/image_fetch_scheduler_test.dart` "lane caps hold; a finished transfer admits the next waiter", `test/pixiv_image_preload_test.dart` "a preload the user asked for skips the queued prefetch"
- **Code:** `lib/core/image/image_fetch_scheduler.dart`

### IMG-08 Retry belongs to the visible image
- **Rule:** A failed preload is not retried and never reported through
  `FlutterError.onError`. The visible `PixivImage` retries a transient
  failure after 1 s, 3 s and 8 s, then shows a retry button; 403, 404 and
  410 are permanent. A retry evicts the `ResizeImage`-wrapped key the
  widget resolves.
- **Why:** Preload failures flooded the crash log; evicting the bare
  provider key missed the cached error, so retry did nothing.
- **Check:** `test/pixiv_image_retry_test.dart` "three failed retries end in a manual retry button" "a missing image is asked for once; the button asks again", `test/pixiv_image_preload_test.dart`
- **Code:** `lib/app/pixiv_image.dart`

## Tests

### IMG-09 Image tests run the real worker host
- **Rule:** Widget tests use `inProcessImageWorker` (real host, cache and
  scheduler; only `http.Client` scripted) or `withStalledImages`. A test
  leaving a transfer in flight ends with `unmountPastReleaseGrace`. A test
  world that answers the path_provider channel overrides
  `imageWorkerProvider`. Tests reusing a URL clear `imageCache` in
  `setUp`.
- **Why:** The production provider spawned a real isolate; the release
  re-check timer outlived the test; a cached error answered without the
  network.
- **Check:** manual
- **Code:** `test/helpers/image_network.dart`

## Ugoira

### IMG-10 An animated work owns its resources and frees them
- **Rule:** A ugoira load owns one temporary archive, one index, one
  bounded frame cache and one scheduler. The cache disposes every
  `ui.Image` it evicts or replaces; the viewer stops the scheduler before
  teardown.
- **Why:** Undisposed frames and temp files leaked across viewers.
- **Check:** `test/ugoira_test.dart` "evicts the least recently used frame and disposes it"
- **Code:** `lib/core/ugoira`

### IMG-11 GIF export is a cancellable worker job with one terminal state
- **Rule:** GIF export quantizes in a worker isolate, checks cancellation
  between frames and before finalize, owns one pending MediaStore item and
  emits exactly one terminal snapshot. It never holds the full decoded
  frame list on the UI isolate. Its recovery record uses its own key and
  owner prefix and never enters the download retry queue; after a restart
  an unfinished export becomes `orphaned`.
- **Why:** Quantization on the UI isolate froze the app; a synthetic GIF
  URL in the download queue retried forever.
- **Check:** `test/ugoira_test.dart` "GIF quantization runs through the bounded worker and is decodable" "cancellation aborts only the owned pending output", `test/download_recovery_test.dart` "interrupted Ugoira output is orphaned and its owned pending row is cleaned"
- **Code:** `lib/core/ugoira/ugoira_export.dart`, `lib/core/ugoira/ugoira_recovery.dart`
