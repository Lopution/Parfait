import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_store.dart';

class _StubAccountStore extends AccountStore {
  _StubAccountStore();

  @override
  Future<AccountState> build() async => _stateFor('100');

  void switchCurrentTo(String id) {
    state = AsyncData(_stateFor(id));
  }
}

AccountState _stateFor(String currentId) => AccountState(
  status: AccountStatus.ready,
  accounts: const [
    Account(id: '100', userId: 100, name: 'a'),
    Account(id: '200', userId: 200, name: 'b'),
  ],
  currentId: currentId,
);

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [accountStoreProvider.overrideWith(_StubAccountStore.new)],
    );
    addTearDown(container.dispose);
  });

  BookmarkStore store() => container.read(bookmarkStoreProvider.notifier);

  group('BookmarkStore mutation lifecycle', () {
    test(
      'begin is non-optimistic and pending suppresses duplicates (R4/R5)',
      () {
        const key = BookmarkKey(BookmarkEntityType.illust, 1);

        final op = store().beginAdd(key, BookmarkRestrict.public);
        expect(op, isNotNull);
        expect(
          store().entryOf(key)!.bookmarked,
          isFalse,
          reason: 'must not flip before commit',
        );
        expect(store().entryOf(key)!.isPending, isTrue);

        expect(
          store().beginAdd(key, BookmarkRestrict.private),
          isNull,
          reason: 'pending entry suppresses a second begin',
        );
        expect(store().beginDelete(key), isNull);
      },
    );

    test('commit flips confirmed state and bumps the revision gate (R4)', () {
      const key = BookmarkKey(BookmarkEntityType.illust, 1);
      final s = store();
      final revisionAtFetch = s.revisionNow();

      final op = s.beginAdd(key, BookmarkRestrict.private)!;
      expect(s.revisionNow(), greaterThan(revisionAtFetch));
      s.commit(op);

      final entry = s.entryOf(key)!;
      expect(entry.bookmarked, isTrue);
      expect(entry.restrict, BookmarkRestrict.private);
      expect(entry.isPending, isFalse);
      expect(entry.confirmedRevision, op.revision);
      expect(entry.error, isNull);
    });

    test('delete commit clears bookmark and restrict', () {
      const key = BookmarkKey(BookmarkEntityType.illust, 9);
      final s = store();
      s.observeRemote(key, bookmarked: true, snapshotRevision: 0);

      final op = s.beginDelete(key)!;
      s.commit(op);

      final entry = s.entryOf(key)!;
      expect(entry.bookmarked, isFalse);
      expect(entry.restrict, isNull);
    });

    test('fail restores confirmed view and surfaces the error (R5)', () {
      const key = BookmarkKey(BookmarkEntityType.illust, 2);
      final s = store();

      final op = s.beginDelete(key)!;
      s.fail(op, const FormatException('boom'));

      final entry = s.entryOf(key)!;
      expect(entry.bookmarked, isFalse);
      expect(entry.isPending, isFalse);
      expect(entry.error, isA<FormatException>());
    });

    test('late completion of a superseded op is dropped (R5)', () {
      const key = BookmarkKey(BookmarkEntityType.illust, 3);
      final s = store();

      final first = s.beginAdd(key, BookmarkRestrict.public)!;
      // Settle the first op as failed, then complete a second one.
      s.fail(first, StateError('stale'));
      final second = s.beginAdd(key, BookmarkRestrict.public)!;
      s.commit(second);
      expect(s.entryOf(key)!.bookmarked, isTrue);

      // A late commit of the FIRST op must not change anything.
      s.commit(first);
      expect(s.entryOf(key)!.bookmarked, isTrue);
      expect(s.entryOf(key)!.confirmedRevision, second.revision);

      // A late fail of the second op must not un-confirm it either.
      s.fail(second, StateError('late'));
      expect(s.entryOf(key)!.bookmarked, isTrue);
      expect(s.entryOf(key)!.error, isNull);
    });
  });

  group('BookmarkStore remote snapshot merge (R2)', () {
    test('seeds unknown keys from remote values', () {
      const key = BookmarkKey(BookmarkEntityType.illust, 10);
      store().observeRemote(key, bookmarked: true, snapshotRevision: 0);
      expect(store().entryOf(key)!.bookmarked, isTrue);
    });

    test('ignores snapshots older than the local confirmation', () {
      const key = BookmarkKey(BookmarkEntityType.illust, 11);
      final s = store();

      final op = s.beginAdd(key, BookmarkRestrict.public)!;
      s.commit(op);
      final confirmedAt = s.revisionNow();

      // Fetch started BEFORE the commit → stale snapshot → ignored.
      s.observeRemote(
        key,
        bookmarked: false,
        snapshotRevision: confirmedAt - 1,
      );
      expect(s.entryOf(key)!.bookmarked, isTrue);

      // Fetch started AFTER the commit → fresh snapshot may differ.
      s.observeRemote(
        key,
        bookmarked: false,
        snapshotRevision: confirmedAt + 1,
      );
      expect(s.entryOf(key)!.bookmarked, isFalse);
    });

    test('ignores snapshots while an operation is pending', () {
      const key = BookmarkKey(BookmarkEntityType.illust, 12);
      final s = store();
      s.beginAdd(key, BookmarkRestrict.public);
      s.observeRemote(key, bookmarked: false, snapshotRevision: 999);
      expect(
        s.entryOf(key)!.bookmarked,
        isFalse,
        reason: 'the pending op owns the truth until it settles',
      );
    });
  });

  group('BookmarkStore account scoping (R8)', () {
    test('state resets when the current account changes', () {
      const key = BookmarkKey(BookmarkEntityType.illust, 20);
      final op = store().beginAdd(key, BookmarkRestrict.public)!;
      store().commit(op);
      expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isTrue);

      (container.read(accountStoreProvider.notifier) as _StubAccountStore)
          .switchCurrentTo('200');
      container.invalidate(bookmarkStoreProvider);

      expect(
        container.read(bookmarkStoreProvider)[key],
        isNull,
        reason: 'account B must not observe account A bookmark state',
      );
    });
  });
}
