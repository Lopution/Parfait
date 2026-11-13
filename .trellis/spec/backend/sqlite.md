---
prefix: SQLITE
applies_to:
  - lib/core/sqlite/**
  - lib/core/history/history_database.dart
  - lib/core/paging/feed_database.dart
  - lib/core/watchlater/watch_later_database.dart
  - lib/core/localnovel/local_novel_database.dart
reviewed: 2026-11-13
---

# Shared SQLite connections and downgrade policy

### SQLITE-01 One lazy connection and shared lifecycle per database
- **Rule:** Every local SQLite owner delegates factory selection and connection
  lifecycle to `SqliteDatabase` (`sqliteDatabaseFactory`). Omitted
  `databasePath` uses `sqflite.inMemoryDatabasePath` (`singleInstance: false`)
  under `FLUTTER_TEST` and `<getDatabasesPath>/<databaseName>`
  (`singleInstance: true`) in production; under `FLUTTER_TEST`, FFI uses
  `databaseFactoryFfiNoIsolate`. Concurrent first opens share one future,
  concurrent `close()` calls await the same close future (skipping
  `openDatabase` if closed while resolving the default path), and later access
  throws `StateError`.
- **Why:** Duplicated factory helpers and `open`/`close` boilerplate drifted
  across the four databases; isolate-backed FFI replies bypassed `testWidgets`
  fake-async zones, shared `:memory:` instances leaked rows between tests, and
  concurrent `close()` callers previously returned before the connection closed.
- **Check:** `test/sqlite_database_test.dart` "sqliteDatabaseFactory selects mobile sqflite or FLUTTER_TEST FFI" "concurrent first database access opens once" "concurrent close waits for in-flight openDatabase to finish closing" "close during async default path skips openDatabase and rejects open" "routes default path to memory in test and <databasesPath>/<name> when enabled" "close is safe when never opened or failed and blocks later opens"
- **Code:** `lib/core/sqlite/sqlite_database.dart`

### SQLITE-02 A database a newer build left is never opened as older
- **Rule:** Every database owner sets `onDowngrade` explicitly. `feeds.db`, a
  cache, is dropped and created afresh (`onDatabaseDowngradeDelete`), its queued
  actions with it. `history.db`, `watchlater.db` and `local_novels.db` refuse
  to open (`SqliteDatabase.refuseDowngrade`) with a `StateError` naming the
  database and both versions; their feature shows its load error. `close()`
  after a failed open completes quietly.
- **Why:** Without `onDowngrade` sqflite lowers the version and keeps the newer
  tables, so the newer build, back again, re-ran a migration it had run and
  the database stopped opening.
- **Check:** `test/database_downgrade_test.dart` "a database a newer build left behind"
- **Code:** `lib/core/sqlite/sqlite_database.dart`, `lib/core/history/history_database.dart`, `lib/core/paging/feed_database.dart`, `lib/core/watchlater/watch_later_database.dart`, `lib/core/localnovel/local_novel_database.dart`
