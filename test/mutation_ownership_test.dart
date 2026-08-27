import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/bookmark/bookmark_actions.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_repository.dart';
import 'package:pixiv_func/core/bookmark/bookmark_store.dart';
import 'package:pixiv_func/core/comments/comment_store.dart';
import 'package:pixiv_func/core/entity/comment_entity.dart';
import 'package:pixiv_func/core/mutation/mutation_models.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/user/follow_store.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _SwitchableAccountStore extends AccountStore {
  _SwitchableAccountStore();

  @override
  Future<AccountState> build() async => _state('a');

  void switchTo(String id) => state = AsyncData(_state(id));
}

AccountState _state(String currentId) => AccountState(
  status: AccountStatus.ready,
  accounts: const [
    Account(id: 'a', userId: 10, name: 'A'),
    Account(id: 'b', userId: 20, name: 'B'),
  ],
  currentId: currentId,
  credentialRevision: currentId == 'a' ? 1 : 2,
);

class _BookmarkRepository implements BookmarkRepository {
  final requests = <String>[];
  final tokens = <CancelToken?>[];
  final gate = Completer<void>();

  @override
  Future<void> addIllust(
    int id,
    BookmarkRestrict restrict, {
    CancelToken? cancelToken,
  }) async {
    requests.add('add:$id');
    tokens.add(cancelToken);
    await gate.future;
  }

  @override
  Future<void> deleteIllust(int id, {CancelToken? cancelToken}) async {
    requests.add('delete:$id');
    tokens.add(cancelToken);
    await gate.future;
  }
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('mutation envelope has explicit owner and non-secret identity', () {
    final owner = MutationOwner(id: 'screen-1', accountId: 'a');
    final envelope = MutationEnvelope(
      accountId: 'a',
      credentialRevision: 4,
      entityType: 'illust',
      entityId: '42',
      operation: 'bookmark.add',
      clientMutationId: 'mutation-1',
      createdAt: DateTime.utc(2026, 8, 28),
      networkRevision: const NetworkRevision(9),
      owner: owner,
      revision: 1,
    );

    expect(envelope.accountId, 'a');
    expect(envelope.credentialRevision, 4);
    expect(envelope.entityType, 'illust');
    expect(envelope.entityId, '42');
    expect(envelope.operation, 'bookmark.add');
    expect(envelope.clientMutationId, 'mutation-1');
    expect(envelope.owner, same(owner));
    expect(envelope.isCancelled, isFalse);
    owner.cancel();
    expect(envelope.isCancelled, isTrue);
    expect('$envelope', isNot(contains('token')));
  });

  test('reopening a rebuilt ledger keeps telemetry but not pending work', () {
    final ledger = MutationLedger();
    const boundary = MutationBoundary(
      accountId: 'a',
      credentialRevision: 1,
      networkRevision: NetworkRevision(0),
    );
    final envelope = ledger.begin(
      boundary: boundary,
      entityType: 'illust',
      entityId: '42',
      operation: 'bookmark.add',
    )!;

    ledger.dispose();
    expect(envelope.owner.isCancelled, isTrue);
    expect(ledger.isActive(envelope), isFalse);
    expect(ledger.discardEvents.single.reason, MutationDiscardReason.disposed);

    ledger.reopen();
    expect(ledger.isActive(envelope), isFalse);
    final replacement = ledger.begin(
      boundary: boundary,
      entityType: 'illust',
      entityId: '42',
      operation: 'bookmark.add',
    );
    expect(replacement, isNotNull);
    expect(ledger.discardEvents, hasLength(1));
  });

  test('bookmark reverse operation supersedes the old response', () async {
    final container = ProviderContainer(
      overrides: [
        accountStoreProvider.overrideWith(_SwitchableAccountStore.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(accountStoreProvider.future);
    final store = container.read(bookmarkStoreProvider.notifier);
    const key = BookmarkKey(BookmarkEntityType.illust, 42);

    final add = store.beginAdd(key, BookmarkRestrict.public)!;
    final delete = store.beginDelete(key)!;

    expect(add.envelope.owner.isCancelled, isTrue);
    expect(store.entryOf(key)!.pending, same(delete));
    expect(store.entryOf(key)!.status, MutationStatus.pending);

    store.commit(delete);
    store.commit(add);
    expect(store.entryOf(key)!.bookmarked, isFalse);
    expect(store.entryOf(key)!.status, MutationStatus.confirmed);
    expect(store.entryOf(key)!.confirmedRevision, delete.revision);
    expect(
      store.discardEvents,
      contains(
        isA<MutationDiscardEvent>().having(
          (event) => event.reason,
          'reason',
          MutationDiscardReason.superseded,
        ),
      ),
    );
  });

  test(
    'account switch cancels owner and rejects a late bookmark response',
    () async {
      final repository = _BookmarkRepository();
      final container = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWith(_SwitchableAccountStore.new),
          bookmarkRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      const key = BookmarkKey(BookmarkEntityType.illust, 42);
      final action = container.read(bookmarkActionsProvider).toggle(key);
      await Future<void>.delayed(Duration.zero);
      final old = container.read(bookmarkStoreProvider.notifier).entryOf(key)!;
      final operation = old.pending!;

      (container.read(accountStoreProvider.notifier) as _SwitchableAccountStore)
          .switchTo('b');
      await Future<void>.delayed(Duration.zero);
      repository.gate.complete();
      await action;

      expect(operation.envelope.owner.isCancelled, isTrue);
      expect(container.read(bookmarkStoreProvider), isEmpty);
      expect(repository.requests, ['add:42']);
      expect(repository.tokens.single, same(operation.cancelToken));
      expect(
        container
            .read(bookmarkStoreProvider.notifier)
            .discardEvents
            .map((event) => event.reason),
        contains(
          anyOf(
            MutationDiscardReason.accountChanged,
            MutationDiscardReason.credentialChanged,
            MutationDiscardReason.cancelled,
            MutationDiscardReason.disposed,
          ),
        ),
      );
    },
  );

  test(
    'follow and comments operations carry the same account boundary',
    () async {
      final container = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWith(_SwitchableAccountStore.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);

      final follow = container.read(followStoreProvider.notifier).beginAdd(7)!;
      final comment = container
          .read(commentStoreProvider.notifier)
          .beginSend(illustId: 42)!;

      for (final envelope in [follow.envelope, comment.envelope]) {
        expect(envelope.accountId, 'a');
        expect(envelope.credentialRevision, 1);
        expect(envelope.entityId, isNotEmpty);
        expect(envelope.networkRevision.value, isNonNegative);
        expect(envelope.owner.accountId, 'a');
      }
      expect(follow.envelope.entityType, 'user');
      expect(comment.envelope.entityType, 'comment');
    },
  );

  test(
    'comment mutation status distinguishes cancel, failure and confirm',
    () async {
      final container = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWith(_SwitchableAccountStore.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final store = container.read(commentStoreProvider.notifier);

      final cancelled = store.beginSend(illustId: 42)!;
      expect(store.mutationFor(cancelled.key)!.status, MutationStatus.pending);
      expect(store.cancelSend(cancelled), isTrue);
      expect(
        store.mutationFor(cancelled.key)!.status,
        MutationStatus.cancelled,
      );

      final failed = store.beginSend(illustId: 42)!;
      store.failSend(failed, const ApiNetworkError('offline'));
      expect(store.mutationFor(failed.key)!.status, MutationStatus.failed);
      expect(store.mutationFor(failed.key)!.error, isA<ApiNetworkError>());

      final rateLimited = store.beginSend(illustId: 42)!;
      store.failSend(rateLimited, const ApiRateLimited(Duration(seconds: 7)));
      final rateError = store.mutationFor(rateLimited.key)!.error;
      expect(rateError, isA<ApiRateLimited>());
      expect(
        (rateError! as ApiRateLimited).retryAfter,
        const Duration(seconds: 7),
      );

      final confirmed = store.beginSend(illustId: 42)!;
      store.commitSend(
        confirmed,
        CommentEntity(
          id: 700,
          illustId: 42,
          parentCommentId: null,
          rootCommentId: 700,
          user: UserEntity(id: 10, name: 'A', account: 'a'),
          content: 'confirmed',
          createdAt: DateTime.utc(2026, 8, 28),
        ),
      );
      expect(
        store.mutationFor(confirmed.key)!.status,
        MutationStatus.confirmed,
      );
      expect(store.get(700)!.content, 'confirmed');
    },
  );
}
