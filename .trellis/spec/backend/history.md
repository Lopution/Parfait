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
  one transaction.
- **Why:** Opening per operation raced concurrent first opens.
- **Check:** `test/history_persistence_test.dart` "commits local row and merged outbox duration atomically"
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
  is visible and the app is in the foreground; no periodic timer. Pixiv
  sync starts at 10 s and merges only the unsubmitted duration.
- **Why:** A one-second periodic timer counted background time and woke
  the app.
- **Check:** `test/history_persistence_test.dart` "HistoryTracker counts only elapsed visible segments and no timer"
- **Code:** `lib/core/history/history_tracker.dart`

### HIST-04 The outbox never crosses accounts
- **Rule:** Outbox flushes are serialized; a success deletes the row, a
  failure keeps it with bounded backoff. A changed account stops the flush
  before submitting. Removing an account clears only its outbox, keeping
  local rows, so re-adding it does not flush old work.
- **Why:** Account A's views were submitted under account B.
- **Check:** `test/history_persistence_test.dart` "flushes successful work and retains failures with backoff" "clear removes only the selected account and its outbox"
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
