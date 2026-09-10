# Database Guidelines

> SQLite conventions for the local browsing-history store.

## Overview

The app has one local history database, `history.db`, owned by
`HistoryDatabase` in `lib/core/history/history_database.dart`. It uses
`sqflite` on Android/iOS and `sqflite_common_ffi` on desktop and in tests. The
database opens lazily once per Riverpod provider container and closes when the
container is disposed. `HistoryRepository` is the only application CRUD and
outbox boundary.

## Schema and Query Patterns

The current schema version is `2` and contains:

- `history_records`, keyed by an autoincrement `id`, with
  `(account_id, content_type, content_id)`, UTC `last_viewed_at`, compact title
  and author snapshot fields, optional cover/content/novel-anchor fields,
  `visible_duration_ms`, and `snapshot_version`;
- `pixiv_history_outbox`, keyed by `(account_id, content_type, content_id)`,
  with accumulated duration, last-viewed time, attempt count, and the next
  retry timestamp.

The database creates `history_records_identity` for the logical content key,
`history_records_order` for account/time pages, and
`pixiv_history_outbox_ready` for account/retry selection. History pages order
by `last_viewed_at DESC, id DESC`; `HistoryRepository` binds values through
`whereArgs` or query arguments and returns typed `HistoryRecord` objects.
The database stores a compact `HistorySnapshot`, never the original Pixiv JSON
or novel body.

```dart
final page = await repository.page(
  accountId: accountId,
  contentType: HistoryContentType.illust,
);
```

## Transactions and Ownership

`commitView` writes the local row and, when requested, the newly observed Pixiv
duration in one transaction. `clear` removes local rows and that account's
outbox together. Account removal uses `clearOutbox` only, so local history
remains available to the user.

Outbox flushes are serialized by the repository. A successful remote add
deletes the matching row; a failed add increments attempts and records bounded
backoff before surfacing `HistorySyncException`. A changed account stops the
flush with `HistoryAccountChangedException` and does not submit under the new
account.

## Migrations and Test Factories

Schema v1 already contains the compact history and outbox tables. The v1→v2
migration adds `snapshot_version` with default `1`. Unsupported future schema
versions are reported rather than silently opened as an older shape.

Production selects the platform factory through
`historyDatabaseFactory(useMobileSqflite: ...)`. Tests pass
`databaseFactoryFfi` and a unique temporary `databasePath` to
`HistoryDatabase`; this avoids sharing an on-disk database between parallel
test isolates. `test/history_persistence_test.dart` covers migration, indexes,
CRUD, account isolation, transaction behavior, and `EXPLAIN QUERY PLAN`.

## Naming and Common Mistakes

Use snake_case table/column/index names matching the existing schema and keep
storage conversions in `HistoryRecord` / `PixivHistoryOutboxEntry`. Do not
open a second connection per operation, write full API payloads, use a shared
default FFI path in tests, or submit an outbox row after its account boundary
has changed.
