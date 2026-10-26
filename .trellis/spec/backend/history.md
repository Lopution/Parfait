---
prefix: HIST
applies_to:
  - lib/core/history/**
  - lib/features/history/**
reviewed: 2026-10-12
---

# Browsing history

### HIST-01 One connection, owned by the repository
- **Rule:** `HistoryDatabase` opens `history.db` lazily once per provider
  container and closes it on dispose. All access goes through
  `HistoryRepository`; a write that touches a record and the outbox uses
  one transaction. A backup overwrite replaces an account's rows in one
  transaction (`replaceAll`); rows the table refuses
  (`HistoryRecord.checkStorable`) fail the file at parse, before an import
  writes anything.
- **Why:** Opening per operation raced concurrent first opens. An
  overwrite cleared the history, then inserted row by row: a refused row
  or a death mid-way left it empty.
- **Check:** `test/history_persistence_test.dart` "commits local row and merged outbox duration atomically"; `test/backup_test.dart` "a row overwrite cannot store leaves the old history whole" "rejects structurally malformed fields"
- **Code:** `lib/core/history/history_database.dart`, `lib/core/history/history_repository.dart`

### HIST-02 Store a compact snapshot, never payloads
- **Rule:** A record holds typed content kind and id, UTC time, account,
  visible duration and `HistorySnapshot` fields only; novel progress is a
  paragraph id plus offset. A corrupt row surfaces a format error instead
  of a fabricated entity.
- **Why:** Full API JSON and novel bodies bloated the database.
- **Check:** `test/history_persistence_test.dart` "surfaces a corrupt row instead of fabricating history"
- **Code:** `lib/core/history/history_snapshot.dart`

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
- **Check:** `test/history_page_test.dart` "overflow menu toggles record switches and shows checks"
- **Code:** `lib/features/history`

### HIST-06 Tests use their own database path
- **Rule:** Tests pass `databaseFactoryFfi` and a unique temporary
  `databasePath` to `HistoryDatabase`.
- **Why:** Parallel test isolates sharing the default FFI path corrupted
  each other's data.
- **Check:** `test/history_persistence_test.dart`
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
- **Check:** `test/history_persistence_test.dart` "announces writes to the local rows, not to the outbox"; `test/history_page_test.dart` "each open reads afresh; open, the order holds; hidden, it "
- **Code:** `lib/core/history/history_repository.dart`, `lib/core/history/history_feed_controller.dart`, `lib/features/history/history_page.dart`
