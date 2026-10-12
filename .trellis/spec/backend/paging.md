---
prefix: PAGING
applies_to:
  - lib/core/paging/**
  - lib/core/network/data_worker.dart
  - lib/core/network/next_page_parser.dart
  - lib/core/*/*_feed*.dart
  - lib/core/*/*_repository.dart
reviewed: 2026-10-12
---

# Paged feeds, commits and the data worker

## Contents

- [Feed controller](#feed-controller)
- [Commit gate](#commit-gate)
- [Paging pace](#paging-pace)
- [Data worker](#data-worker)

## Feed controller

### PAGING-01 One fetch hook per feed
- **Rule:** A `PagedFeedController` subclass implements only
  `fetchPageForContext(FeedRequestContext)`; cancellation comes from
  `context.cancelToken`. No second fetch method, and no
  `UnimplementedError` to disown one.
- **Why:** Two fetch contracts let some feeds bypass cancellation and the
  commit gate.
- **Check:** `test/feed_generation_commit_test.dart`
- **Code:** `lib/core/paging/paged_feed_controller.dart`

### PAGING-02 Cancellation is idle, not an error
- **Rule:** Initial, refresh and load-more phases are independent. A
  cancelled request returns its phase to idle and keeps the loaded ids and
  the last valid cursor.
- **Why:** Cancelled refreshes showed error pages.
- **Check:** `test/ranking_feed_test.dart` "cancel returns an active feed to idle without an error"
- **Code:** `lib/core/paging/paged_feed_controller.dart`

### PAGING-03 Error fields clear only when passed null
- **Rule:** `PagedFeedState.copyWith(initialError: null)` and
  `copyWith(loadMoreError: null)` clear the error; an omitted argument keeps
  it. Nullable fields use a sentinel, never `??`.
- **Why:** `??` made an error impossible to clear, or cleared it on every
  copy.
- **Check:** manual
- **Code:** `lib/core/paging/paged_feed_controller.dart`

### PAGING-04 Cursors pass an allowlist before they are stored
- **Rule:** A non-empty `next_url` passes the feed's `validateCursor`
  allowlist (endpoint, origin, thread) before it is stored. A rejected or
  repeated cursor is an `ApiParseError` and is never requested.
- **Why:** A cursor pointing off the API origin would have sent the token
  elsewhere; a repeated cursor looped forever.
- **Check:** `test/illust_store_test.dart` "a cursor may not move the client off the Pixiv API origin", `test/feed_generation_commit_test.dart` "duplicate next cursor fails before entity commit or cursor advance"
- **Code:** `lib/core/network/next_page_parser.dart`

## Commit gate

### PAGING-05 Repositories return pages; only the gate writes stores
- **Rule:** A repository parses into a `FeedPage` whose optional commit
  callback is the only place it merges into shared stores. The controller
  validates the cursor, then runs `FeedCommitGate.commit` with the request
  context; ids, cursor, phase and entity merge happen together without an
  await in between. The context's `feedKey` includes every selector.
- **Why:** A repository merging right after parsing let a stale or
  other-account response contaminate the shared store.
- **Check:** `test/feed_generation_commit_test.dart` "refresh wins over a late append and drops its entity/cursor commit" "account switch fences a late response and rebuilds the feed" "dispose fences a response without reading the disposed ref"
- **Code:** `lib/core/paging/feed_request_context.dart`

### PAGING-06 Refresh starts a new generation
- **Rule:** Refresh increments the generation, clears the committed
  cursor set and cancels old appends. A refresh replaces the ordered list;
  load-more appends only unseen ids in server order. Token refresh does not
  rebuild a feed.
- **Why:** Late appends mixed generations and left ghost ids.
- **Check:** `test/feed_generation_commit_test.dart` "active append commits same-ID updates and keeps server order"
- **Code:** `lib/core/paging/paged_feed_controller.dart`

## Paging pace

### PAGING-07 Automatic load-more keeps a reader's pace
- **Rule:** Automatic pages are at least 1 s apart, counted from the
  previous return, refill hops included. After 30 pages back to back the
  feed pauses with a "continue" tail until a 5 s idle gap or the user's
  tap. The first load, a refresh and the first page after either are never
  held. Local feeds (history) use `FeedPagingPolicy.unlimited`.
- **Why:** The detail pager's near-end trigger and fast flings fired page
  requests back to back, risking rate limits.
- **Check:** `test/feed_paging_policy_test.dart` "pages wait out the interval; the first after a load goes at once" "a run of pages pauses at the budget; continue grants a new one" "refill hops are paced like pages"
- **Code:** `lib/core/paging/feed_paging_policy.dart`

## Data worker

### PAGING-08 Parsing runs on the data worker with sendable closures
- **Rule:** Repositories map pages through `PixivHttpClient.getParsed`,
  whose `parse` is a top-level or static function, or a closure built in a
  non-async static factory over sendable values; never a closure over
  `this` or created in an async body. Store merges stay on the UI isolate.
- **Why:** Unsendable closures failed only in release, where the isolate
  worker runs.
- **Check:** `test/data_worker_test.dart` "InlineDataWorker rejects work the isolate worker could not carry"
- **Code:** `lib/core/network/data_worker.dart`

### PAGING-09 Widget tests use InlineDataWorker
- **Rule:** Widget tests that go through the real `pixivHttpClientProvider`
  override `dataWorkerProvider` with `InlineDataWorker`.
- **Why:** Fake time never delivers an isolate's reply, so the test hung.
- **Check:** manual
- **Code:** `lib/core/network/data_worker.dart`
