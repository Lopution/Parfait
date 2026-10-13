---
prefix: STORE
applies_to:
  - lib/core/entity/**
  - lib/core/bookmark/**
  - lib/core/user/**
  - lib/core/mutation/**
  - lib/core/actionqueue/**
  - lib/core/comments/**
  - lib/core/watchlist/**
  - lib/core/auth/account_store.dart
  - lib/core/illust/**
reviewed: 2026-10-13
---

# Stores, mutations and the account boundary

## Contents

- [Providers and canonical stores](#providers-and-canonical-stores)
- [Optimistic toggles](#optimistic-toggles)
- [Mutation ownership](#mutation-ownership)
- [Account boundary](#account-boundary)

## Providers and canonical stores

### STORE-01 Providers behind an error state do not retry
- **Rule:** A `FutureProvider` or throwing `AsyncNotifier` behind a page
  with its own error state and retry button sets `retry: (_, _) => null`.
  Controllers that catch into their state need nothing.
- **Why:** Riverpod's default retry held the value in loading for about
  40 s, so the page spun instead of showing its error.
- **Check:** `test/novel_reader_chrome_test.dart` "a failed detail reaches the error state at once"
- **Code:** `lib/core/novel`

### STORE-02 Entities have one canonical copy
- **Rule:** Illusts, users, comments, bookmark and follow state live in
  their account-scoped store; feeds hold ordered ids only. Pages never
  keep a local copy of an entity or a bookmark/follow flag. After a merge,
  read the entity back with `store.get(id)`.
- **Why:** Cards, the detail page and the viewer showed different data for
  the same work.
- **Check:** `test/illust_store_test.dart` "cross-page duplicate IDs collapse in the store"
- **Code:** `lib/core/entity/illust_store.dart`, `lib/core/user/user_store.dart`

### STORE-03 Every IllustEntity field has a merge decision per source
- **Rule:** `IllustStore.mergeAll` is the only write path for API payloads,
  and a feed payload is sparse while a detail payload is authoritative. A
  new `IllustEntity` field gets an explicit decision for both
  `EntityMergeSource.feed` and `.detail` plus a test. Current decisions:

  | Field | Feed | Detail |
  |---|---|---|
  | `isBookmarked` | `BookmarkStore` decides | `BookmarkStore` decides |
  | page URLs | keep old when empty | incoming wins |
  | `caption`, `tags` | keep old when empty | incoming, even empty |
  | `visible` | `new && old` | incoming |
  | `pageCount` | `max(new, old)` | incoming |
  | series | incoming only when the payload has the key | same |

- **Why:** Feed refreshes stripped viewer and download URLs and erased
  multi-page counts; a snapshot without the series key forgot the series.
- **Check:** `test/illust_store_test.dart` "feed merge does not regress caption/tags/pageCount" "detail merge may overwrite empty caption/tags, visible=false, smaller pageCount" "a payload that does not mention series keeps the known one"
- **Code:** `lib/core/entity/illust_store.dart`

### STORE-04 Mutation stores never read entity stores
- **Rule:** `BookmarkStore` and `FollowStore` push confirmed changes to
  entity stores through the `onConfirmed` callback; they never `ref.read`
  the entity store.
- **Why:** The reverse read created a Riverpod circular dependency at
  runtime.
- **Check:** manual
- **Code:** `lib/core/user/user_store.dart`, `lib/core/bookmark`

### STORE-05 Detail controllers do not watch the store they write
- **Rule:** A detail controller that merges into `UserStore` or
  `IllustStore` reads its initial snapshot with `ref.read` and watches
  only the current-account boundary. A follow fetch captures
  `FollowStore.revisionNow()` before the request and passes it to the
  merge.
- **Why:** Watching the whole store made the controller's own merge
  invalidate it: an unbounded detail-request loop.
- **Check:** manual
- **Code:** `lib/core/user`, `lib/core/illust`

## Optimistic toggles

### STORE-06 Show the wish, confirm only on commit
- **Rule:** Bookmark, follow and watchlist entries keep the confirmed
  value apart from `wish`; widgets render `entry.shown`. Only `commit`
  changes the confirmed value, and only confirmed changes reach entity
  stores. `fail` rolls back to the confirmed value with the classified
  error, unless the user already tapped away (then `cancelled`, silent).
- **Why:** Waiting for the server made every tap feel dead; publishing
  unconfirmed values leaked failed writes into other pages.
- **Check:** `test/bookmark_flow_test.dart` "the shown value flips before the server answers" "failure restores the confirmed icon and surfaces error (R5)" "a failure the user already tapped away from stays silent"
- **Code:** `lib/core/bookmark`, `lib/core/user/follow_store.dart`, `lib/core/watchlist`

### STORE-07 One request per target; the last tap wins
- **Rule:** A tap on an unsettled entry only records the wish. The action
  that started the request runs `settleToggle`, which sends one follow-up
  after the commit if the wish differs. Never send the opposite request
  while one is in flight. A re-add after a delete restores the deleted
  visibility and tags.
- **Why:** Two writes in flight can land on the server in either order; a
  private bookmark tapped back mid-delete came back public.
- **Check:** `test/bookmark_flow_test.dart` "an odd number of taps sends only the first request" "an even number of taps follows up once the first answers" "tapping back mid-delete keeps a private bookmark private"
- **Code:** `lib/core/mutation/mutation_models.dart`

### STORE-08 Queued intents can be taken back, running ones cannot
- **Rule:** A connectivity failure queues the intent and marks the entry
  `queued`. A tap on a queued entry calls `ActionQueue.dropPending`; a row
  already running cannot be dropped and the tap is ignored.
  `markRunning` claims only a still-pending row.
- **Why:** A row dropped after `nextReady` read it replayed anyway.
- **Check:** `test/action_queue_test.dart` "a dropped pending row never replays, even if already read", `test/watchlist_test.dart` "a tap on a queued watch takes the intent back"
- **Code:** `lib/core/actionqueue`

### STORE-13 The queue recovers interrupted replays and wakes itself
- **Rule:** A queue's first drain (one queue per process) returns rows a
  killed process left `running` to pending with their `attempt`; one with
  a newer pending intent of the same key is deleted instead. After each
  drain an owner keeps one wake timer, due at the later of the cooldown's
  end and the first row backoff; an enqueue arms one cooldown. A network
  restore clears the cooldown and drains. Leaving an account parks it:
  the wake is cancelled and a running drain stops after its current row.
- **Why:** A replay cut short by a kill stayed `running` and the intent
  was lost; in the foreground nothing drained after a cooldown, a backoff
  or a restore; a wake must never replay under the next account.
- **Check:** `test/action_queue_test.dart` "the first drain replays interrupted rows; newer intents win" "cooldown, backoff and a fresh enqueue wake the queue" "retryNow skips the cooldown; a parked owner stays asleep" "recoverInterrupted and nextPendingAt through sqlite", `test/action_replay_test.dart` "a network restore replays the queue inside its cooldown"
- **Code:** `lib/core/actionqueue`

### STORE-09 Remote snapshots never overwrite unsettled entries
- **Rule:** `observeRemote` ignores a snapshot while the entry is pending
  or holds a wish, and ignores snapshots older than the last confirmation.
- **Why:** A feed refresh landing mid-request flipped the heart back.
- **Check:** `test/bookmark_store_test.dart` "ignores snapshots while an operation is pending" "ignores snapshots older than the local confirmation"
- **Code:** `lib/core/bookmark`

## Mutation ownership

### STORE-10 Writes are owned by an account envelope
- **Rule:** Every authenticated write that can outlive a widget begins in
  `MutationLedger` with the current account; the dedupe key is
  `(accountId, entityType, entityId, operation)`, without the credential
  revision. Only a still-active envelope commits. Account switch, logout
  and owner disposal cancel active owners; a rebuilt ledger never
  resurrects pending work.
- **Why:** Late responses wrote into another account's store; a token
  refresh invalidated in-flight writes.
- **Check:** `test/mutation_ownership_test.dart` "account switch cancels owner and rejects a late bookmark response" "reopening a rebuilt ledger keeps telemetry but not pending work"
- **Code:** `lib/core/mutation`

### STORE-11 Comments publish only after the server answers
- **Rule:** Sending or deleting a comment stays pending until the API
  succeeds; no optimistic entity is published. Replies carry an explicit
  `(illustId, parentCommentId, rootCommentId)` context, because the
  replies endpoint may omit the parent. Deleting another user's comment
  fails before any request.
- **Why:** A reordered page updated the wrong thread when results were
  matched by list index.
- **Check:** `test/comments_replies_test.dart` "actions do not publish before API success and enforce owner delete" "late send completion is dropped and root delete clears descendants"
- **Code:** `lib/core/comments`

## Account boundary

### STORE-12 Account-scoped state resets before the new account renders
- **Rule:** Account-scoped stores and feed families watch the current
  account and reset before the new account's responses render. Feeds use
  generation and cancellation, mutations the account id, downloads the
  account id plus destination identity. `credentialRevision` re-keys only
  the home widget's display state.
- **Why:** User ids and pending maps are not portable across accounts;
  re-keying feeds on token refresh lost tab stacks.
- **Check:** `test/bookmark_store_test.dart` "state resets when the current account changes"
- **Code:** `lib/core/auth/account_store.dart`
