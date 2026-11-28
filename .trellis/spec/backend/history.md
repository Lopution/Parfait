---
prefix: HIST
applies_to:
  - lib/core/history/**
  - lib/features/history/**
reviewed: 2026-11-28
---

# Browsing history

## Contents

- [Storing and recording](#storing-and-recording)
- [Reading](#reading)

## Storing and recording

### HIST-01 One connection, owned by the repository
- **Rule:** `HistoryDatabase` opens `history.db` lazily once per provider
  container and closes it on dispose (schema v4 with composite B-tree
  indexes `history_records_type_order` and `history_records_author`,
  SQLite 3.22+ compatible without FTS5). All access goes through
  `HistoryRepository`; a write that touches a record and the outbox uses
  one transaction. Backup merges (`mergeAll`), overwrites (`replaceAll`),
  and multi-select deletes (`deleteAll`) each run in one transaction and
  emit a single change notification; rows the table refuses
  (`HistoryRecord.checkStorable`) fail the file at parse, before an import
  writes anything.
- **Why:** Opening per operation raced concurrent first opens; per-row
  transactions during backup restore or multi-delete caused N WAL fsyncs
  and N stream refreshes. An overwrite that cleared history row by row left
  it empty on failure.
- **Check:** `test/history_persistence_test.dart` "commits local row and merged outbox duration atomically" "mergeAll, deleteAll, v4 indexes, and search coalescing keep history fast and atomic"; `test/backup_test.dart` "a row overwrite cannot store leaves the old history whole" "rejects structurally malformed fields"
- **Code:** `lib/core/history/history_database.dart`, `lib/core/history/history_repository.dart`

### HIST-02 Store a compact snapshot, never payloads
- **Rule:** A record holds typed content kind and id, UTC time, account,
  visible duration and `HistorySnapshot` fields only (display fields plus
  flattened newline-delimited `tagsText` for local search, nullable for
  legacy rows); novel progress is a paragraph id plus offset. Full API
  JSON, captions and novel bodies never enter the database. A corrupt row
  surfaces a format error instead of a fabricated entity.
- **Why:** Full API JSON and novel bodies bloated the database, while
  compact tag text keeps local search useful when artwork titles are
  generic.
- **Check:** `test/history_persistence_test.dart` "surfaces a corrupt row instead of fabricating history" "upgrades v2 rows to v3 with null tags_text and preserves data"
- **Code:** `lib/core/history/history_snapshot.dart`, `lib/core/history/history_models.dart`

### HIST-03 Count visible foreground time only, without timers
- **Rule:** `HistoryTracker` accumulates stopwatch segments while the route
  is visible, the app is in the foreground and the content is active
  (`HistoryVisibility.active`); no periodic timer. In the detail pager
  only the settled page is active (`DetailPageActivity`). Content never
  visible writes no row, not even when it closes. Pixiv sync starts at
  10 s and merges only the unsubmitted duration.
- **Why:** A one-second periodic timer counted background time and woke
  the app. The pager's prebuilt neighbours share the route, so opening one
  work recorded the works beside it too, and sent them to pixiv after ten
  seconds; closing the pager wrote every page it had built.
- **Check:** `test/history_persistence_test.dart` "HistoryTracker counts only elapsed visible segments and no timer"; `test/illust_detail_pager_test.dart` "only the settled page writes to the history"
- **Code:** `lib/core/history/history_tracker.dart`, `lib/core/history/history_visibility.dart`

### HIST-04 The outbox never crosses accounts
- **Rule:** Outbox flushes are serialized; a success deletes the row as
  it was sent (a visit merged into it during the POST keeps it), a
  failure keeps it with bounded backoff. A rejection is thrown
  (`HistorySyncException`); a connectivity-class failure
  (`isConnectivityError`: no network, 5xx, 429) only logs, since every page
  visit flushes and would report the same outage again. A changed account stops the flush
  before submitting. Removing an account clears only its outbox, keeping
  local rows, so re-adding it does not flush old work.
- **Why:** Account A's views were submitted under account B.
- **Check:** `test/history_persistence_test.dart` "flushes successful work and retains failures with backoff" "a server error waits out its backoff without a report" "a visit made while its POST is in flight stays queued" "clear removes only the selected account and its outbox"
- **Code:** `lib/core/history/history_repository.dart`, `lib/core/auth/account_store.dart`

### HIST-05 Switches stop writes, never delete
- **Rule:** Turning off local history or Pixiv sync stops new writes for
  that channel and keeps existing rows. Both switches live in the history
  page's overflow menu, reachable signed out.
- **Why:** Users lost history by toggling a switch.
- **Check:** `test/history_page_test.dart` "an empty history with recording off offers to turn it on"
- **Code:** `lib/features/history`

### HIST-06 Tests use their own database path
- **Rule:** Tests pass `databaseFactoryFfi` and a unique temporary
  `databasePath` to `HistoryDatabase`.
- **Why:** Parallel test isolates sharing the default FFI path corrupted
  each other's data.
- **Check:** `test/history_persistence_test.dart` "opens one versioned schema and upgrades v1 rows"
- **Code:** `lib/core/history/history_database.dart`

### HIST-07 Writes to the local rows announce themselves
- **Rule:** `HistoryRepository.changes` fires after each write that
  changes the local rows: a view, a delete that removed a row, a clear, a
  restore. Outbox writes stay silent. The provider closes the stream on
  dispose. A view that stays mounted (the Me tab's recent row) re-reads on
  it. The history page's feed is auto-disposed, so each open reads
  afresh; open, it keeps its order (on screen, and under a page it
  opened: the image flying back lands on the card it left), and hidden on
  another tab with nothing over it, it re-reads out of sight.
- **Why:** The Me tab's recent row kept what it read when first built;
  the history page kept the list of its first open for the whole session.
- **Check:** `test/history_persistence_test.dart` "announces writes to the local rows, not to the outbox"; `test/history_page_test.dart` "each open reads afresh; open, the order holds; hidden, it catches up"
- **Code:** `lib/core/history/history_repository.dart`, `lib/core/history/history_feed_controller.dart`, `lib/features/history/history_page.dart`

## Reading

### HIST-08 The history feed pages after the last row read
- **Rule:** The history feed's cursor is the last loaded row's
  (`last_viewed_at`, id); `HistoryRepository.page(contentType:, query:, after:)`
  applies content-type and tokenized SQLite filters (escaped `LIKE` over
  `title`/`author_name`/`tags_text`, indexed `UNION` lookup for positive
  integer `content_id`/`author_id` tokens), coalesces overlapping
  interactive searches via a single-flight gate, and reads past the cursor
  in `last_viewed_at DESC, id DESC` order, never by offset, telling whether
  another page follows from the same read (one row more), not from a second
  count. A failed first read shows `FeedError` with retry, not the empty
  view. A reader that needs every row (the backup export) reads them in
  one statement (`HistoryRepository.all`), not page by page.
- **Why:** Offset paging skipped an unread row for each loaded row
  deleted, in-memory filtering missed unloaded history rows, and a read
  error said "no history" with no way to retry. An export read in pages
  while views arrived wrote some rows twice and dropped others: a view
  moves its row to the top, behind the reader, whether pages go by offset
  or by cursor. A delete between a page's read and its count ended the
  paging early.
- **Check:** `test/history_page_test.dart` "deleting a loaded record never skips one on the next page (B11)${overlapping ? ', nor comes back with that page' : ''}" "a failed first read offers a retry, not \"no history\" (B10)"; `test/history_persistence_test.dart` "a delete while a page is read leaves the rest reachable" "searches title, author, tags, IDs and pages filtered results"; `test/backup_test.dart` "views recorded during an export neither repeat nor drop a row"
- **Code:** `lib/core/history/history_feed_controller.dart`, `lib/core/history/history_repository.dart`, `lib/features/history/history_page.dart`, `lib/features/history/history_body.dart`, `lib/core/backup/backup_service.dart`
