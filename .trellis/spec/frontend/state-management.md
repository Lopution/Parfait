# State Management

> How state is managed in this project.

---

## Overview

<!--
Document your project's state management conventions here.

Questions to answer:
- What state management solution do you use?
- How is local vs global state decided?
- How do you handle server state?
- What are the patterns for derived state?
-->

(To be filled by the team)

---

## State Categories

<!-- Local state, global state, server state, URL state -->

(To be filled by the team)

---

## When to Use Global State

<!-- Criteria for promoting state to global -->

(To be filled by the team)

---

## Server State

<!-- How server data is cached and synchronized -->

### Shared Entity Store Merge Contract (`IllustStore.mergeAll`)

**What**: `IllustStore` (lib/core/entity/illust_store.dart) is the single account-scoped copy of illust entities; feeds hold only ordered ID lists, so Recommended cards, Detail page and Viewer must observe identical data. `mergeAll` is the only write path for API payloads.

**Merge direction is per-field and monotonic** — newer parse wins by default, EXCEPT these regression guards:

| Field | Direction | Why |
|---|---|---|
| `isBookmarked` | BookmarkStore authority, gated by `bookmarkSnapshotRevision` | BookmarkStore owns all bookmark mutations (see below); fetches must capture `bookmarks.revisionNow()` BEFORE the request and pass it as `bookmarkSnapshotRevision` — a snapshot older than the store's confirmed revision is ignored so it cannot overwrite a local mutation; when the snapshot is current, its value is authoritative (covers server-side deletes made elsewhere) |
| `metaPages` / `metaSinglePageOriginalUrl` | keep old when incoming empty | detail → feed refresh must not strip viewer/download URLs |
| `caption` / `tags` | keep old non-empty when incoming empty | trimmed payloads must not erase richer values already rendered (parent AC: 详情字段不倒退) |
| `visible` | `new && old` (AND) | `visible: false` sticks once seen |
| `pageCount` | `max(new, old)` | a feed's `page_count=1` must not erase a detail multi-page count |

**Rule for new `IllustEntity` fields**: every field added to `IllustEntity` MUST get an explicit merge decision in `mergeAll` plus a merge test in test/illust_store_test.dart asserting the no-regression direction. Fields defaulting to "newer wins" are acceptable only when a real endpoint always re-sends them.

**Wrong**: calling `store.mergeAll([fresh])` then rendering a captured pre-merge entity — read back via `store.get(id)` after merging (detail controller does exactly this so Ready state shows merged data).

### Canonical Mutation Store Protocol (`BookmarkStore`, lib/core/bookmark/)

**What**: cross-page mutable flags (bookmarked today; extensible to followed/liked) live in `BookmarkStore`, keyed by `(accountId, entityType, entityId)`. UI is a pure subscriber; entities sync via `illustStoreProvider`'s `onConfirmed` closure (one-way dependency — the store must NEVER `ref.read` the entity store or Riverpod circular-dependency errors appear at runtime).

**Mutation protocol**: `begin` records a non-optimistic pending entry (UI shows `CupertinoActivityIndicator` 24px) and dedupes concurrent ops per key → repository call → `commit`/`fail` validate the operation revision against the pending one (late responses from stale revisions are dropped). Remote snapshots enter via `observeRemote`, gated by the same revision clock. Every awaited repository call is wrapped in try/catch that ends in `fail` so pending spinners can never stick.

**Network contract (pixiv_http_client)**: token-expiry triggers the single-flight refresh on **401 OR 400 whose body contains `invalid_grant`** — observed live: `/v1/illust/recommended` surfaces an expired token as 400 invalid_grant, not 401. A plain 400 (parameter error) must NOT refresh. Diagnostics: non-2xx responses attach a clamped body snippet to `ApiHttpError.detail` (never contains credentials).

---

## Common Mistakes

<!-- State management mistakes your team has made -->

(To be filled by the team)
