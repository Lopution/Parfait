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

### Canonical User and Follow Protocol (`UserStore`, `FollowStore`, lib/core/user/)

**What**: `UserStore` is the account-scoped canonical map for user previews and
detail entities; `FollowStore` owns confirmed/pending/error relationship state
keyed by `(account, userId)`. Profile, relation cards and future Search/
Comments/Live surfaces read these stores rather than keeping page-local user
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
cursor/state machine. A transport-aware feed may override
`fetchPageCancellable(String? cursor, CancelToken cancelToken)`; the default
delegates to `fetchPage` for feeds whose transport has no cancellation hook.

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
- Only `assets/emojis/` (10 columns) and `assets/stamps/` (5 columns) are
  used by the composer. Translation is a transient overlay and never
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
- Widget tests assert explicit reply/translate/delete actions, 10/5 grids and
  the initial/load-more retry states. A device check must distinguish API
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
  that channel and does not delete existing local rows automatically.
- `HistoryTracker` uses production `StopwatchHistoryClock`; it accumulates
  only route-visible foreground segments. It has no periodic timer. Pixiv
  enqueueing starts at 10 seconds and only the newly unsubmitted duration is
  merged into the outbox.
- The history page reads the indexed rows, uses `IllustStore`/`NovelStore` when
  a richer entity is already present, and renders the stored snapshot when an
  entity was deleted or is unavailable. Delete and clear are account-scoped.

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
- The normal image route is `i.pximg.net` over HTTPS/system DNS. The fixed IP
  is an explicit legacy/emergency choice and is never a migration default.
- Translation credentials are not fields in `AppSettings.toJson()`. A
  `SecretSettingRef` may identify a secure-storage record, but the record's
  secret stays in `CredentialStore`.

---

## Common Mistakes

<!-- State management mistakes your team has made -->

(To be filled by the team)
