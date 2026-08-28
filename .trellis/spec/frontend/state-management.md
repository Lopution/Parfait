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
  final int credentialRevision;
  final int generation;
  final int page;
  final String? cursor;
  final CancelToken cancelToken;
  final NetworkRevision networkRevision;
}

Future<FeedPage> fetchPageForContext(FeedRequestContext context);
bool FeedCommitGate.commit(
  FeedRequestContext context, {
  required String? accountId,
  required int credentialRevision,
  required NetworkRevision networkRevision,
  required void Function() action,
});
```

`FeedPage` contains ordered IDs, a nullable validated candidate cursor, and an
optional commit callback. The callback is the only place a repository page may
merge into `IllustStore`, `NovelStore`, or `UserStore`.

#### 3. Contracts

- A controller creates the immutable context before issuing the request. Its
  `feedKey` includes every family selector (mode, query, filter, sort, or
  profile key); account ID, credential revision, and network revision are
  captured from the same boundary snapshot.
- A repository parses/normalizes into `FeedPage` and performs no shared-store
  write. The controller validates `next_url` before invoking the callback, then
  commits entity merge, stable ID dedupe, cursor, page, and phase from the same
  active context without an intervening await.
- Refresh increments generation, clears the prior generation's committed
  cursor set, and cancels old append work. A repeated current or previously
  committed cursor is an `ApiParseError`; its page cannot merge or advance the
  cursor.
- Account or credential boundary changes are watched synchronously by the
  provider, so a family instance rebuilds and old entity ownership/list/cursor
  state is not reused. Disposal invalidates the gate even when transport
  cancellation cannot physically stop the response.
- A rejected active response leaves existing list/cursor/entity data intact and
  surfaces the appropriate initial, refresh, or load-more error. A stale or
  cancelled response records bounded metadata-only telemetry and cannot alter
  UI state or shared stores.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Feed key, generation, account, credential, or network revision is inactive | Reject commit; record stale/boundary telemetry; do not merge or update cursor/state |
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
- The normal image route is `i.pximg.net` over HTTPS/system DNS. Image URLs are
  never rewritten to a fixed IP or mirror; compatibility routing belongs to the
  exact-host network policy.
- Translation credentials are not fields in `AppSettings.toJson()`. A
  `SecretSettingRef` may identify a secure-storage record, but the record's
  secret stays in `CredentialStore`.

### Restricted Pixiv Network Policy Contract (`NetworkAccessPolicy`)

#### 1. Scope / Trigger

This contract applies when a native Pixiv API, OAuth, image-cache or media
download request needs the mainland compatibility path. The policy is
app-scoped and must not become a generic proxy or a URL-rewriting service.

#### 2. Signatures

```dart
http.Client clientFor(PixivDestinationPurpose purpose, NetworkRoute route);
Future<ResolvedHost> resolve(
  PixivDestination destination, {
  NetworkCancelSignal? cancelSignal,
});
void setMode(NetworkMode mode);
NetworkRevision advanceNetworkRevision({String? networkIdentity});
```

`PixivPolicyHttpClient` and `PolicyDownloadTransport` are the shared native
consumers. `WebViewRoutePolicy` validates direct navigation and only reports a
loopback route when its AndroidX capability gate is proven.

#### 3. Contracts

- The default mode is `NetworkMode.automatic`: direct HTTPS with system DNS is
  attempted first. `NetworkMode.directOnly` closes compatibility route pools
  and prevents resolver fallback.
- `PixivDestinationRegistry` matches exact ASCII HTTPS hosts by purpose:
  `app-api.pixiv.net`, `oauth.secure.pixiv.net`, `accounts.pixiv.net`,
  `www.pixiv.net`, `i.pximg.net` and `s.pximg.net` as applicable. Userinfo,
  fragments, IP literals, trailing dots, IDN input and non-443 ports are
  rejected.
- System DNS and the optional fixed-endpoint DoH resolver return public A/AAAA
  candidates with source, TTL and `NetworkRevision`. A secure-DNS connector
  changes only the TCP destination; the original URI remains responsible for
  TLS SNI, certificate hostname verification and the HTTP `Host` header.
- Only DNS, connect, timeout and reset failures may try another strict route.
  Empty GET/HEAD requests may be cloned for replay; POST, token exchange and
  every request with a possible body send never replay automatically.
- Diagnostics contain canonical host, purpose, route, DNS source, IP family,
  failure, latency, capability and network revision only. They do not contain
  query strings, cookies, tokens, bodies or full addresses.
- Account changes, network revision changes, mode changes and disposal close
  old pools and clear health state. WebView loopback remains fail-closed until
  AndroidX reverse-bypass capability and lifecycle evidence exist.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Non-Pixiv, suffix, IDN, IP, trailing-dot, userinfo, fragment or non-443 URI | Reject before a request or route is created |
| Direct eligible transport failure in `Automatic` mode | Resolve public candidates for the exact canonical host and try strict candidates |
| HTTP, auth, rate-limit, parse, cancellation, TLS or certificate failure | Surface the failure; never use compatibility fallback |
| POST, token exchange, or body possibly sent | Do not replay across routes |
| Resolver result has wrong host/revision or no public address | Reject as a secure-resolution failure |
| ECH/WebView capability evidence incomplete | Keep the optional route unavailable; do not bind a listener or add a dependency |
| Account/network/mode boundary | Advance/replace revision, close pools and clear health |

#### 5. Good / Base / Bad Cases

- Good: an empty `GET` to `app-api.pixiv.net` tries direct first, then a
  public resolver candidate while preserving `app-api.pixiv.net` for TLS and
  `Host`; diagnostics record only route metadata.
- Base: an API `429` or certificate mismatch is returned immediately, while
  `DirectOnly` uses the original strict HTTPS client without resolver work.
- Bad: rewriting an image URL to an IP/mirror, accepting
  `evil.pixiv.net`, logging the request body, or retrying a bookmark `POST`
  after the socket may have sent its body.

#### 6. Tests Required

- Registry tests cover purpose separation and all canonicalization rejection
  cases.
- Resolver tests cover public A/AAAA filtering, answer-name/type matching,
  TTL bounds, response-size limits, cancellation and revision binding.
- Policy tests cover direct-first selection, eligible-only fallback,
  original-host requests, no POST replay, pool/health invalidation and
  diagnostics redaction.
- Factory tests prove API, OAuth, image cache and downloads share the policy;
  source audits prove translation, updater and reverse-image paths do not enter
  the Pixiv compatibility connector.
- WebView/ECH tests prove incomplete capability evidence is explicit and
  listener-free. Device evidence must distinguish API 35 MuMu emulator
  coverage from an unavailable API 36 matrix and physical-device coverage.

#### 7. Wrong vs Correct

**Wrong**: set `badCertificateCallback` to accept every certificate, replace
the SNI/`Host` with a candidate IP, or use a third-party proxy for every URL.

**Correct**: allowlist the exact Pixiv destination and purpose, try direct
HTTPS first, optionally steer a strict connector to a validated public
candidate while retaining the original hostname, and fail closed when the
capability or failure class is not approved.

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
operation, account/credential change, network revision change or provider
disposal. It does not create a durable offline queue.

#### 2. Signatures

```dart
class MutationEnvelope {
  final String accountId;
  final int credentialRevision;
  final String entityType;
  final String entityId;
  final String operation;
  final String clientMutationId;
  final DateTime createdAt;
  final NetworkRevision networkRevision;
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

- A begin is allowed only with the current usable account, credential
  revision and network policy revision. The exact dedupe key is
  `(accountId, entityType, entityId, operation)`; an active exact duplicate is
  suppressed, while another operation on the same target cancels and records
  the old owner as `superseded` before registering the new revision.
- Feature stores keep the last server-confirmed value separate from pending
  presentation state. Only a still-active envelope can commit; a late result
  cannot update the confirmed value, another account, an old credential
  boundary or a disposed provider.
- Terminal status is observable as `idle`, `pending`, `confirmed`, `failed`,
  `cancelled` or `superseded`. Cancellation clears the pending marker without
  manufacturing a server-confirmed change; ordinary failures preserve the
  previous confirmed value and retain the classified error.
- Account switch, logout, credential-refresh invalidation, network revision
  change and owner disposal cancel active owners. A provider rebuild may
  reopen an empty ledger to retain bounded discard telemetry, but it never
  resurrects a pending request.
- Bookmark, Follow and Comment repository calls pass the envelope's
  `CancelToken` and set `allowAuthReplay: false`. A token refresh may run once
  through the shared account policy, but an operation whose body may have been
  sent is never silently replayed.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| no usable account or invalid entity ID | reject before registering a mutation; surface the normal typed error |
| exact active duplicate | return `null`; keep the original request and pending state |
| opposite operation on the same target | cancel old owner, record `superseded`, and accept only the new envelope's result |
| account/credential/network boundary changed | cancel and discard the old envelope; never write the new account's store |
| provider/page disposed | cancel owner; late completion is discarded and does not publish an API error |
| 401 or invalid refresh | use shared auth policy; invalid refresh becomes observable `ApiUnauthorized` and no mutation replay |
| 403/404/429/network/5xx | preserve classified error (`ApiRateLimited.retryAfter` included), clear pending, retain confirmed state |

#### 5. Good / Base / Bad Cases

- Good: a delayed bookmark add carries account A's envelope, a reverse delete
  supersedes it, and only the delete's server confirmation updates the shared
  bookmark/entity stores.
- Base: a 401 refreshes the credential once, then a non-idempotent Comment
  POST terminates with an observable auth error rather than sending its body a
  second time.
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
- HTTP client tests assert one shared refresh and that a POST with a possible
  body does not replay after refresh; error tests retain `Retry-After` and
  classified 403/404/5xx/network outcomes.
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
Every submission captures an immutable `(account, credential revision, network
revision, illust/page/frame, destination, format)` snapshot. A product
submission must have a usable account and the fixed `Pictures/PixivFunc`
destination; legacy in-memory test submissions may remain unowned only when
the manager is explicitly configured for that test boundary.

The manager exposes `queued`, `running`, `canceling`, `finalizing`,
`succeeded`, `failed`, `canceled`, `retryable` and `orphaned`. Only the first
three successful/failed/canceled outcomes plus `orphaned` are terminal;
`retryable` requires an explicit user retry and is never opened automatically
after recovery. Each
job emits one terminal event. Groups capture one submission boundary and
aggregate child states without replacing child ownership.

Pending output is owned by an opaque owner record containing the job and
account identity; it must not expose temporary filesystem paths or
credentials. MediaStore writes use pending rows and become visible only after
successful finalize. Abort, finalize and terminal cleanup are idempotent and
must be guarded against duplicate callbacks. Owner checks run before output
creation, before transport/write/finalize, and while streaming. A provider
returning `null` after logout is a boundary change, not permission to fall
back to the submission-time context.

On process recovery, only a record whose job, owner, account, credential
revision, network revision and destination exactly match the current context
may be restored as `retryable`; recovery does not auto-start it. Mismatched,
invalid or unknown records become observable `orphaned` records, and known
pending MediaStore rows are cleaned only through their opaque owner. Cleanup
failure remains visible in recovery diagnostics. A crash observed in
`finalizing` is treated as `orphaned` rather than retried, because the output
may already have become visible. Group membership is rebuilt from child
snapshots before the recovered group status is exposed. HTTP `Retry-After` and the
stable auth/rate/network/storage/permission/decode/resource failure classes
are retained in the job snapshot without storing request headers or tokens.

Ugoira export follows the same owner fence, bounded frame/pixel/output
budgets, cancellation checks and one pending output. It emits `finalizing`
before the sink finalize call and publishes success only after finalize
returns. API 29+ pending-row behavior is verified through the Android bridge;
API 35 MuMu evidence must remain separate from any unavailable API 36 run.

### Android Platform Boundary Contract (`IntentRouter`, `WebViewRouteSession`)

Android platform messages are untrusted input. `AndroidIntentChannel` may
forward only action, opaque URI, MIME, read-grant and bounded-size metadata;
it must never forward cookies, credentials or file contents. `IntentRouter`
then performs the final typed validation: VIEW accepts only the exact Pixiv
schemes/hosts/paths, SEND requires the single `EXTRA_STREAM` content URI,
explicit read permission, a concrete `image/*` subtype and a bounded positive
size. Unknown actions, extras, URI shapes and malformed channel payloads are
observable rejections, not empty routes.

Each WebView navigation captures a `WebViewRouteSession` with an exact
destination host set and `NetworkRevision`. A compatibility loopback can only
be opened by an active session after all AndroidX capability gates and a
concrete adapter are present; the default production provider is direct-only
and fail-closed. Owners use idempotent leases, and page disposal, background,
logout, authentication failure or a stale network revision closes the session
and any listener. The route never disables TLS validation, changes SNI/Host,
uses a fixed IP as a security decision or serves a non-Pixiv origin.

OAuth WebView navigation must validate the exact `pixiv://account` callback
against the live one-use PKCE session and matching state before exchange.
Invalid callback parameters and non-Pixiv web navigation are rejected and
discard the session. Root back handling is lifecycle-aware: the one-second
double-back window is cleared when a child route is pushed or the app leaves
the resumed state.

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
evidence is missing. Result mapping sorts by similarity, deduplicates Pixiv
IDs, and permits only strict HTTPS external destinations. An unavailable
provider is rendered as a visible terminal failure with retry/cancel behavior;
it is not a hidden mock.

The platform boundary rejects non-content URI shapes, missing read grants,
unknown MIME/size metadata and paths outside the owned cache. Cancellation,
provider failure, route disposal and cleanup failure remain observable, and a
new upload may not reuse a previous flow's temporary file.

### Profile Edit Contract (`ProfileEditController`, `lib/core/profile/`)

Profile editing is an account-scoped draft, not a second user cache. A draft
captures the account id, credential revision, network revision, authoritative
base values and the typed `ProfileCapabilities` returned by the selected
official route. `ProfilePatch` contains only fields that differ from that base;
unsupported dirty fields remain visible as field errors and are never sent.

The controller checks the owner before loading, submitting and committing a
response. Account, credential or network revision changes cancel the request,
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

If no reviewed App API or approved Web adapter exists for a profile mutation,
the capability is an explicit unavailable outcome. The form may still show the
beta56 fields and read-only values, but Save must remain disabled or fail with
the typed unavailable reason; it must not scrape passwords, inject cookies,
replay a body through another route or synthesize success.

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
- A successful generation captures account id, credential revision and
  `NetworkRevision` before the request and rechecks all three immediately
  before publication. Account, credential or network changes make the result
  `superseded`; they must not publish or clear the newer owner's state.
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
  `pixivfunc://illusts/<positive-id>`; extra query/fragment/authority forms
  are rejected before navigation.

#### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Missing, malformed, unknown-version or oversize snapshot | Render the explicit open-app/empty state; never render partial fields |
| Missing, unreferenced, unsafe or oversize image | Keep last-good generation on write failure; native render falls back to open-app state |
| Account not ready or credential missing | Clear render state and report `no_account` only when absence is established; unreadable storage remains transient |
| Account, credential or network revision changes in flight | Return `superseded`; do not clear or publish across the boundary |
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
  resolving a fixed IP in native code, deleting `active.json` before a new
  generation is staged, or replaying a stale account's result after a network
  revision change.

#### 6. Tests Required

- Snapshot tests assert schema/version, integer and text bounds, account-key
  binding, age/corruption rejection, exact image references and no secret
  fields.
- Store tests inject a failed second-image stage and assert the previous
  pointer and images remain readable, while temporary staged files are not
  published.
- Loader tests use delayed account/credential/network revisions to assert
  `superseded`, same-account last-good retention, and account-invalid clear.
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
from the shared Dart auth/network path, gate publication on account,
credential and network revisions, preserve same-account last-good on transient
failure, and make native rendering fail closed with unique bounded work.

## Common Mistakes

<!-- State management mistakes your team has made -->

(To be filled by the team)
