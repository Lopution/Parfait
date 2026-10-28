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
  repeated cursor is an `ApiParseError` and is never requested. Search
  pins every request key, except a duration search's `start_date` and
  `end_date`: the cursor keeps the range the search began with, and each
  page's next_url must carry the dates of the request it answers.
- **Why:** A cursor pointing off the API origin would have sent the token
  elsewhere; a repeated cursor looped forever. A duration search left open
  past local midnight refused every next page.
- **Check:** `test/next_page_parser_test.dart` "a next_url may never leave the Pixiv API origin", `test/feed_generation_commit_test.dart` "duplicate next cursor fails before entity commit or cursor advance", `test/paged_feed_refill_test.dart` "a rejected or repeated cursor fails the load like a page's own", `test/search_catalog_test.dart` "search cursors accept the new filter parameters"
- **Code:** `lib/core/network/next_page_parser.dart`

### PAGING-10 Local filters cover every discovery list, novels alike
- **Rule:** Recommended, ranking, search, user works, related works and
  New filter each page through `PagedFeedController.filterPageIds`: the
  local R-18 block (R-18G included) and AI block, and in hide mode the
  author, tag and work mutes. A novel feed sets `novelIds` and reads the
  page's novels and the novel store (`x_restrict`, `novel_ai_type`,
  author and tags), never an illust that shares the id. In blur mode a
  muted novel row blurs its cover and shows the reason as its title until
  a tap reveals it, in its own id space. Saved lists (bookmarks, history,
  watch later, watchlist) never filter; the server's `is_muted` is unused.
  A page restored from its snapshot passes the filters again.
- **Why:** Novels ignored mutes and the block, novel ranking hid a novel
  whenever an R-18 illust shared its id, R-18G passed the R-18 block, and
  related works and New showed blocked works (user decision 10-27). A
  block switched on rebuilt the feed from a snapshot written without it.
- **Check:** `test/paged_feed_refill_test.dart` "hide mode drops mute hits, blur keeps them; novels read novels"; `test/local_block_filter_test.dart` "C9 local block: R-18 (and R-18G) and AI switches, illusts and "; `test/novel_entry_test.dart` "a muted novel shows the reason until a tap reveals it"; `test/new_content_feed_test.dart` "the local block filters New works and novels (R7)"; `test/illust_detail_page_test.dart` "requests related works only once the section is on screen; "; `test/feed_snapshot_cold_start_test.dart` "a restored snapshot passes the filters switched on since"
- **Code:** `lib/core/paging/paged_feed_controller.dart`, `lib/core/settings/local_block_filter.dart`, `lib/core/mute/mute_predicate.dart`, `lib/app/widgets/novel_entry.dart`

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
