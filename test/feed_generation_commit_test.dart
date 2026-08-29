import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/paging/paged_feed_controller.dart';

import 'helpers/illust_fixtures.dart';

IllustEntity _illust(int id, {String? title}) {
  final json = illustJson(id);
  if (title != null) json['title'] = title;
  return parseIllust(json);
}

class _StubAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [Account(id: 'account-a', userId: 1, name: 'tester')],
    currentId: 'account-a',
  );
}

class _SwitchableAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [
      Account(id: 'account-a', userId: 1, name: 'tester'),
      Account(id: 'account-b', userId: 2, name: 'tester 2'),
    ],
    currentId: 'account-a',
  );

  void switchToB() {
    state = const AsyncData(
      AccountState(
        status: AccountStatus.ready,
        accounts: [
          Account(id: 'account-a', userId: 1, name: 'tester'),
          Account(id: 'account-b', userId: 2, name: 'tester 2'),
        ],
        currentId: 'account-b',
        credentialRevision: 1,
      ),
    );
  }
}

class _DeferredFeedController extends PagedFeedController {
  _DeferredFeedController(this.keyValue);

  final String keyValue;
  final requests = <FeedRequestContext>[];
  final completions = <Completer<FeedPage>>[];

  @override
  String get feedKey => keyValue;

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(String? cursor) {
    fail('the generation-aware hook must be used by this feed');
  }

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) {
    requests.add(context);
    final completion = Completer<FeedPage>();
    completions.add(completion);
    return completion.future;
  }
}

final _deferredFeedProvider =
    AsyncNotifierProvider.family<
      _DeferredFeedController,
      PagedFeedState,
      String
    >(_DeferredFeedController.new);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('condition did not become true');
}

ProviderContainer _container() => ProviderContainer(
  overrides: [accountStoreProvider.overrideWith(_StubAccountStore.new)],
);

void main() {
  test(
    'refresh wins over a late append and drops its entity/cursor commit',
    () async {
      final container = _container();
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final provider = _deferredFeedProvider('recommended:illust');
      final controller = container.read(provider.notifier);
      final committed = <String>[];
      final store = IllustStore();

      final initialFuture = container.read(provider.future);
      await _waitUntil(() => controller.requests.length == 1);
      final initialContext = controller.requests.single;
      expect(initialContext.feedKey, 'recommended:illust');
      expect(initialContext.accountId, 'account-a');
      expect(initialContext.credentialRevision, 0);
      expect(initialContext.generation, 1);
      expect(initialContext.page, 1);
      expect(initialContext.cursor, isNull);
      controller.completions
          .removeAt(0)
          .complete(
            FeedPage(
              ids: [1, 2],
              nextCursor: 'cursor-1',
              commit: (_) {
                committed.add('initial');
                store.mergeAll([_illust(1), _illust(2)]);
              },
            ),
          );
      await initialFuture;

      final appendFuture = controller.loadMore();
      await _waitUntil(() => controller.requests.length == 2);
      final appendContext = controller.requests[1];
      final appendCompletion = controller.completions[0];
      expect(appendContext.generation, 1);
      expect(appendContext.page, 2);
      expect(appendContext.cursor, 'cursor-1');

      final refreshFuture = controller.refresh();
      await _waitUntil(() => controller.requests.length == 3);
      final refreshContext = controller.requests[2];
      final refreshCompletion = controller.completions[1];
      expect(refreshContext.generation, 2);
      expect(refreshContext.page, 1);
      expect(refreshContext.cursor, isNull);
      refreshCompletion.complete(
        FeedPage(
          ids: [2, 3],
          nextCursor: null,
          commit: (_) {
            committed.add('refresh');
            store.mergeAll([
              _illust(2, title: 'updated after refresh'),
              _illust(3),
            ]);
          },
        ),
      );
      await refreshFuture;

      // The append response arrived after refresh. Its commit callback must
      // never run, even though the fake transport itself cannot be cancelled.
      appendCompletion.complete(
        FeedPage(
          ids: [4],
          nextCursor: 'stale-cursor',
          commit: (_) {
            committed.add('late-append');
            store.mergeAll([_illust(4)]);
          },
        ),
      );
      await appendFuture;

      final state = container.read(provider).requireValue;
      expect(committed, ['initial', 'refresh']);
      expect(state.ids, [2, 3]);
      expect(state.exhausted, isTrue);
      expect(controller.nextCursor, isNull);
      expect(store.get(4), isNull);
      expect(store.get(2)!.title, 'updated after refresh');
      expect(
        controller.discardEvents.any(
          (event) =>
              identical(event.context, appendContext) &&
              event.reason == FeedDiscardReason.cancelled,
        ),
        isTrue,
      );
    },
  );

  test(
    'active append commits same-ID updates and keeps server order',
    () async {
      final container = _container();
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final provider = _deferredFeedProvider('ranking:day');
      final controller = container.read(provider.notifier);
      final store = IllustStore();

      final initialFuture = container.read(provider.future);
      await _waitUntil(() => controller.requests.length == 1);
      controller.completions
          .removeAt(0)
          .complete(
            FeedPage(
              ids: [1, 2],
              nextCursor: 'cursor-1',
              commit: (_) => store.mergeAll([_illust(1), _illust(2)]),
            ),
          );
      await initialFuture;

      final appendFuture = controller.loadMore();
      await _waitUntil(() => controller.requests.length == 2);
      controller.completions
          .removeAt(0)
          .complete(
            FeedPage(
              ids: [2, 3, 3],
              nextCursor: null,
              commit: (_) => store.mergeAll([
                _illust(2, title: 'same ID updated'),
                _illust(3),
                _illust(3, title: 'duplicate server item'),
              ]),
            ),
          );
      await appendFuture;

      var state = container.read(provider).requireValue;
      expect(state.ids, [1, 2, 3]);
      expect(state.ids.toSet(), hasLength(3));
      expect(state.exhausted, isTrue);
      expect(store.get(2)!.title, 'same ID updated');
      expect(store.get(3)!.title, 'duplicate server item');

      final refreshFuture = controller.refresh();
      await _waitUntil(() => controller.requests.length == 3);
      controller.completions
          .removeAt(0)
          .complete(
            FeedPage(
              ids: [3, 1],
              nextCursor: null,
              commit: (_) => store.mergeAll([_illust(3), _illust(1)]),
            ),
          );
      await refreshFuture;
      state = container.read(provider).requireValue;
      expect(state.ids, [3, 1]);
      expect(state.ids, isNot(contains(2)));
      expect(store.get(2), isNotNull);
    },
  );

  test(
    'duplicate next cursor fails before entity commit or cursor advance',
    () async {
      final container = _container();
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final provider = _deferredFeedProvider('new:following:illust');
      final controller = container.read(provider.notifier);
      var commits = 0;

      final initialFuture = container.read(provider.future);
      await _waitUntil(() => controller.requests.length == 1);
      controller.completions
          .removeAt(0)
          .complete(
            FeedPage(
              ids: [1],
              nextCursor: 'cursor-1',
              commit: (_) => commits++,
            ),
          );
      await initialFuture;

      final appendFuture = controller.loadMore();
      await _waitUntil(() => controller.requests.length == 2);
      controller.completions
          .removeAt(0)
          .complete(
            FeedPage(
              ids: [2],
              nextCursor: 'cursor-1',
              commit: (_) => commits++,
            ),
          );
      await appendFuture;

      final state = container.read(provider).requireValue;
      expect(commits, 1);
      expect(state.ids, [1]);
      expect(state.loadMoreError, isA<ApiParseError>());
      expect(controller.nextCursor, 'cursor-1');
    },
  );

  test('account switch fences a late response and rebuilds the feed', () async {
    final accountStore = _SwitchableAccountStore();
    final container = ProviderContainer(
      overrides: [accountStoreProvider.overrideWith(() => accountStore)],
    );
    addTearDown(container.dispose);
    await container.read(accountStoreProvider.future);
    final provider = _deferredFeedProvider('profile:illust:42');
    final controller = container.read(provider.notifier);
    var oldCommits = 0;
    var newCommits = 0;

    final oldFuture = container
        .read(provider.future)
        .then(
          (value) => value,
          onError: (_, _) => const PagedFeedState(initialPhase: FeedPhase.idle),
        );
    final feedSubscription = container.listen(provider.future, (_, _) {});
    addTearDown(feedSubscription.close);
    await _waitUntil(() => controller.requests.length == 1);
    final oldContext = controller.requests.single;
    accountStore.switchToB();
    await _waitUntil(() => controller.requests.length == 2);
    final newContext = controller.requests[1];
    expect(newContext.accountId, 'account-b');
    expect(newContext.credentialRevision, 1);

    controller.completions[0].complete(
      FeedPage(ids: [10], nextCursor: 'old', commit: (_) => oldCommits++),
    );
    controller.completions[1].complete(
      FeedPage(ids: [20], nextCursor: null, commit: (_) => newCommits++),
    );
    await oldFuture;
    await container.read(provider.future);

    final state = container.read(provider).requireValue;
    expect(oldCommits, 0);
    expect(newCommits, 1);
    expect(state.ids, [20]);
    expect(
      controller.discardEvents.any(
        (event) =>
            identical(event.context, oldContext) &&
            (event.reason == FeedDiscardReason.disposed ||
                event.reason == FeedDiscardReason.cancelled ||
                event.reason == FeedDiscardReason.stale),
      ),
      isTrue,
    );
  });

  test('dispose fences a response without reading the disposed ref', () async {
    final container = _container();
    final provider = _deferredFeedProvider('recommended:illust');
    final controller = container.read(provider.notifier);
    var commits = 0;
    final future = container
        .read(provider.future)
        .then(
          (value) => value,
          onError: (_, _) => const PagedFeedState(initialPhase: FeedPhase.idle),
        );
    await _waitUntil(() => controller.requests.length == 1);

    container.dispose();
    controller.completions.single.complete(
      FeedPage(ids: [99], nextCursor: null, commit: (_) => commits++),
    );
    await future;
    await Future<void>.delayed(Duration.zero);

    expect(commits, 0);
    expect(
      controller.discardEvents.any(
        (event) => event.reason == FeedDiscardReason.disposed,
      ),
      isTrue,
    );
  });

  test('FeedCommitGate rejects account and credential boundary changes', () {
    final gate = FeedCommitGate();
    final token = CancelToken();
    final context = gate.beginRequest(
      feedKey: 'search:cat',
      accountId: 'account-a',
      credentialRevision: 4,
      generation: gate.beginGeneration(),
      page: 1,
      cursor: null,
      cancelToken: token,
    );
    var commits = 0;

    expect(
      gate.commit(
        context,
        accountId: 'account-b',
        credentialRevision: 4,
        action: () => commits++,
      ),
      isFalse,
    );
    expect(commits, 0);
    expect(gate.discardEvents.single.reason, FeedDiscardReason.accountChanged);

    final next = gate.beginRequest(
      feedKey: 'search:cat',
      accountId: 'account-a',
      credentialRevision: 4,
      generation: gate.generation,
      page: 1,
      cursor: null,
      cancelToken: CancelToken(),
    );
    expect(
      gate.commit(
        next,
        accountId: 'account-a',
        credentialRevision: 5,
        action: () => commits++,
      ),
      isFalse,
    );
    expect(commits, 0);
    expect(
      gate.discardEvents.last.reason,
      FeedDiscardReason.credentialChanged,
    );
  });
}
