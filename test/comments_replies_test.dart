import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/comments/comment_actions.dart';
import 'package:pixiv_func/core/comments/comment_assets.dart';
import 'package:pixiv_func/core/comments/comment_feed_controller.dart';
import 'package:pixiv_func/core/comments/comment_models.dart';
import 'package:pixiv_func/core/comments/comment_repository.dart';
import 'package:pixiv_func/core/comments/comment_store.dart';
import 'package:pixiv_func/core/comments/comment_translation.dart';
import 'package:pixiv_func/core/entity/comment_entity.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/features/comments/comment_input.dart';
import 'package:pixiv_func/features/comments/comment_item.dart';
import 'package:pixiv_func/features/comments/comments_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _StubAccountStore extends AccountStore {
  _StubAccountStore();

  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [Account(id: 'account', userId: 10, name: 'tester')],
    currentId: 'account',
  );
}

class _CredentialStore implements CredentialStore {
  final values = <String, Credential>{
    'account': const Credential(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
    ),
  };

  @override
  Future<Credential?> read(String accountId) async => values[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async {
    values[accountId] = credential;
  }

  @override
  Future<void> delete(String accountId) async {
    values.remove(accountId);
  }
}

class _AccountMetadataRepository implements AccountMetadataRepository {
  @override
  Future<AccountMetadataSnapshot> load() async => const AccountMetadataSnapshot(
    accounts: [Account(id: 'account', userId: 10, name: 'tester')],
    currentId: 'account',
  );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

Future<ProviderContainer> _apiContainer(
  Future<http.Response> Function(http.Request) handler,
) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final credentials = _CredentialStore();
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        _AccountMetadataRepository(),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient(
            (_) async => throw StateError('refresh is not expected'),
          ),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client is not wired');
        return client;
      }),
    ],
  );
  final client = PixivHttpClient(
    client: MockClient(handler),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return container;
}

http.Response _jsonValue(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _json(Map<String, dynamic> value) => _jsonValue(value);

Map<String, dynamic> _commentJson(
  int id, {
  int userId = 10,
  String? parentCommentId,
  int? replyCount,
  bool? hasReplies,
  Map<String, dynamic>? stamp,
}) => {
  'id': id,
  'comment': 'comment $id',
  'date': '2026-08-27T10:00:00+09:00',
  'user': {
    'id': userId,
    'name': 'user $userId',
    'account': 'user_$userId',
    'profile_image_urls': <String, String>{},
  },
  'has_replies': hasReplies ?? ((replyCount ?? 0) > 0),
  ...?replyCount == null ? null : {'reply_count': replyCount},
  ...?parentCommentId == null ? null : {'parent_comment_id': parentCommentId},
  ...?stamp == null ? null : {'stamp': stamp},
};

CommentEntity _comment(
  int id, {
  int illustId = 1,
  int userId = 10,
  int? parentCommentId,
  int? rootCommentId,
  int replyCount = 0,
}) => CommentEntity(
  id: id,
  illustId: illustId,
  parentCommentId: parentCommentId,
  rootCommentId: rootCommentId ?? id,
  user: UserEntity(id: userId, name: 'user $userId', account: 'user_$userId'),
  content: 'comment $id',
  createdAt: DateTime.utc(2026, 8, 27),
  hasReplies: replyCount > 0,
  replyCount: replyCount,
);

class _FakeCommentRepository implements CommentRepository {
  final requests = <CommentFeedQuery>[];
  int deleteCalls = 0;
  Completer<CommentEntity>? addCompleter;

  @override
  Future<CommentPage> fetchComments(
    int illustId, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final query = CommentFeedQuery.root(illustId: illustId);
    requests.add(query);
    return CommentPage(
      comments: [_comment(11, illustId: illustId, replyCount: 1)],
      nextUrl: null,
    );
  }

  @override
  Future<CommentPage> fetchReplies(
    int rootCommentId, {
    required int illustId,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final query = CommentFeedQuery.replies(
      illustId: illustId,
      rootCommentId: rootCommentId,
    );
    requests.add(query);
    return CommentPage(
      comments: [
        _comment(
          12,
          illustId: illustId,
          parentCommentId: rootCommentId,
          rootCommentId: rootCommentId,
        ),
      ],
      nextUrl: null,
    );
  }

  @override
  bool validateCursor(CommentFeedQuery query, {required String cursor}) => true;

  @override
  Future<CommentEntity> addComment(
    CommentAddRequest request, {
    CancelToken? cancelToken,
  }) => addCompleter?.future ?? Future.value(_comment(20));

  @override
  Future<void> deleteComment(int commentId, {CancelToken? cancelToken}) async {
    deleteCalls++;
  }
}

void main() {
  test('comment parsing keeps root, parent and stamp fields distinct', () {
    final root = CommentEntity.fromJson(
      _commentJson(100, replyCount: 2),
      illustId: 50,
    );
    final reply = CommentEntity.fromJson(
      _commentJson(101, userId: 11),
      illustId: 50,
      rootCommentId: root.id,
    );
    final stamped = CommentEntity.fromJson(
      _commentJson(
        102,
        stamp: {'stamp_id': 101, 'stamp_url': 'https://example.test/101.jpg'},
      ),
      illustId: 50,
    );

    expect(root.isRoot, isTrue);
    expect(root.rootCommentId, root.id);
    expect(root.parentCommentId, isNull);
    expect(root.replyCount, 2);
    expect(reply.isRoot, isFalse);
    expect(reply.parentCommentId, root.id);
    expect(reply.rootCommentId, root.id);
    expect(stamped.stampId, 101);
    expect(stamped.stampUrl, 'https://example.test/101.jpg');
  });

  test('comment repository maps list, reply and mutation endpoints', () async {
    final paths = <String>[];
    final container = await _apiContainer((request) async {
      paths.add(request.url.path);
      switch (request.url.path) {
        case '/v3/illust/comments':
          expect(request.url.queryParameters, {'illust_id': '50'});
          return _json({
            'comments': [_commentJson(100, replyCount: 1)],
            'next_url':
                'https://app-api.pixiv.net/v3/illust/comments?illust_id=50&offset=30',
          });
        case '/v2/illust/comment/replies':
          expect(request.url.queryParameters, {'comment_id': '100'});
          return _json({
            'comments': [_commentJson(101, userId: 11)],
            'next_url': null,
          });
        case '/v1/illust/comment/add':
          expect(request.method, 'POST');
          expect(request.bodyFields, {
            'illust_id': '50',
            'comment': 'new comment',
            'parent_comment_id': '100',
          });
          return _json({'comment': _commentJson(102)});
        case '/v1/illust/comment/delete':
          expect(request.method, 'POST');
          expect(request.bodyFields, {'comment_id': '102'});
          return _json({'is_success': true});
        default:
          return http.Response('unexpected path', 404);
      }
    });
    addTearDown(container.dispose);
    final repository = container.read(commentRepositoryProvider);

    final rootPage = await repository.fetchComments(50);
    final replyPage = await repository.fetchReplies(100, illustId: 50);
    final added = await repository.addComment(
      const CommentAddRequest(
        illustId: 50,
        parentCommentId: 100,
        rootCommentId: 100,
        text: 'new comment',
      ),
    );
    await repository.deleteComment(102);

    expect(rootPage.comments.single.rootCommentId, 100);
    expect(replyPage.comments.single.parentCommentId, 100);
    expect(replyPage.comments.single.rootCommentId, 100);
    expect(added.id, 102);
    expect(paths, [
      '/v3/illust/comments',
      '/v2/illust/comment/replies',
      '/v1/illust/comment/add',
      '/v1/illust/comment/delete',
    ]);
  });

  test('comment cursors are pinned to their endpoint and thread', () async {
    final container = await _apiContainer(
      (_) async => _json({'comments': [], 'next_url': null}),
    );
    addTearDown(container.dispose);
    final repository = container.read(commentRepositoryProvider);
    const root = CommentFeedQuery.root(illustId: 50);
    const replies = CommentFeedQuery.replies(illustId: 50, rootCommentId: 100);
    expect(
      repository.validateCursor(
        root,
        cursor:
            'https://app-api.pixiv.net/v3/illust/comments?illust_id=50&offset=30',
      ),
      isTrue,
    );
    expect(
      repository.validateCursor(
        replies,
        cursor:
            'https://app-api.pixiv.net/v2/illust/comment/replies?comment_id=100&offset=30',
      ),
      isTrue,
    );
    expect(
      repository.validateCursor(
        root,
        cursor:
            'https://app-api.pixiv.net/v3/illust/comments?illust_id=999&offset=30',
      ),
      isFalse,
    );
    // A reply cursor is not a root-thread cursor, whatever its parameters say.
    expect(
      repository.validateCursor(
        root,
        cursor:
            'https://app-api.pixiv.net/v2/illust/comment/replies?illust_id=50',
      ),
      isFalse,
    );
  });

  test(
    'store deduplicates shared comments and updates the correct thread',
    () async {
      final container = ProviderContainer(
        overrides: [accountStoreProvider.overrideWith(_StubAccountStore.new)],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final store = container.read(commentStoreProvider.notifier);
      final rootQuery = const CommentFeedQuery.root(illustId: 1);
      final replyQuery = const CommentFeedQuery.replies(
        illustId: 1,
        rootCommentId: 10,
      );
      final root = _comment(10, replyCount: 0);
      final reply = _comment(11, parentCommentId: 10, rootCommentId: 10);
      store.mergePage(rootQuery, [root, root]);
      store.mergePage(replyQuery, [reply, reply]);

      expect(store.idsFor(rootQuery), [10]);
      expect(store.idsFor(replyQuery), [11]);
      expect(store.get(10)!.id, root.id);
      expect(store.get(11)!.rootCommentId, 10);

      final op = store.beginSend(
        illustId: 1,
        parentCommentId: 10,
        rootCommentId: 10,
      )!;
      expect(
        store.beginSend(illustId: 1, parentCommentId: 10, rootCommentId: 10),
        isNull,
      );
      final newReply = _comment(12, parentCommentId: 10, rootCommentId: 10);
      store.commitSend(op, newReply);
      expect(store.idsFor(replyQuery), [12, 11]);
      expect(store.get(10)!.replyCount, 1);

      final delete = store.beginDelete(12)!;
      store.commitDelete(delete);
      expect(store.idsFor(replyQuery), [11]);
      expect(store.get(10)!.replyCount, 0);
    },
  );

  test(
    'comment feed keeps root and reply page IDs in the shared store',
    () async {
      final repository = _FakeCommentRepository();
      final container = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);

      const root = CommentFeedQuery.root(illustId: 1);
      const replies = CommentFeedQuery.replies(illustId: 1, rootCommentId: 11);
      final rootState = await container.read(commentFeedProvider(root).future);
      final replyState = await container.read(
        commentFeedProvider(replies).future,
      );

      expect(rootState.ids, [11]);
      expect(replyState.ids, [12]);
      expect(container.read(commentStoreProvider.notifier).idsFor(root), [11]);
      expect(container.read(commentStoreProvider.notifier).idsFor(replies), [
        12,
      ]);
    },
  );

  test(
    'late send completion is dropped and root delete clears descendants',
    () async {
      final container = ProviderContainer(
        overrides: [accountStoreProvider.overrideWith(_StubAccountStore.new)],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final store = container.read(commentStoreProvider.notifier);
      final rootQuery = const CommentFeedQuery.root(illustId: 1);
      final repliesQuery = const CommentFeedQuery.replies(
        illustId: 1,
        rootCommentId: 20,
      );
      store.mergePage(rootQuery, [_comment(20, replyCount: 1)]);
      store.mergePage(repliesQuery, [
        _comment(21, parentCommentId: 20, rootCommentId: 20),
      ]);
      final first = store.beginSend(illustId: 1)!;
      store.failSend(first, StateError('network'));
      final second = store.beginSend(illustId: 1)!;
      store.commitSend(first, _comment(22));
      expect(store.idsFor(rootQuery), [20]);
      store.failSend(second, StateError('still unavailable'));

      final delete = store.beginDelete(20)!;
      store.commitDelete(delete);
      expect(store.idsFor(rootQuery), isEmpty);
      expect(store.idsFor(repliesQuery), isEmpty);
      expect(store.get(21), isNull);
    },
  );

  test(
    'actions do not publish before API success and enforce owner delete',
    () async {
      final repository = _FakeCommentRepository();
      final container = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final action = container.read(commentActionsProvider);
      final result = _comment(20);
      repository.addCompleter = Completer<CommentEntity>();
      final pending = action.send(
        const CommentAddRequest(illustId: 1, text: 'pending'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(commentStoreProvider.notifier).get(20), isNull);
      repository.addCompleter!.complete(result);
      await pending;
      expect(
        container.read(commentStoreProvider.notifier).get(20)!.id,
        result.id,
      );

      final other = _comment(31, userId: 11);
      await expectLater(
        action.delete(other),
        throwsA(isA<CommentPermissionException>()),
      );
      expect(repository.deleteCalls, 0);
      expect(await action.delete(result), isTrue);
      expect(repository.deleteCalls, 1);
    },
  );

  test('translation service parses the explicit overlay response', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'translate.googleapis.com');
      expect(request.url.queryParameters['q'], 'hello');
      expect(request.url.queryParameters['tl'], 'zh');
      return _jsonValue(
        [
              [
                ['你好', 'hello', null, null, 1],
              ],
            ]
            as dynamic,
      );
    });
    final service = GoogleCommentTranslationService(client);
    expect(await service.translate('hello', targetLanguage: 'zh'), '你好');
  });

  testWidgets('composer exposes the fixed 10 and 5 column grids', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: CommentComposer(
            onSend: (_) async {},
            onStampSend: (_) async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    final emojiGrid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (emojiGrid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      10,
    );
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();
    final stampGrid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (stampGrid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      5,
    );
    expect(commentEmojiNames, hasLength(38));
    expect(commentStampIds, hasLength(40));
  });

  testWidgets(
    'comment item uses explicit reply actions and owner-only delete',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [accountStoreProvider.overrideWith(_StubAccountStore.new)],
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: CommentItem(
                comment: _comment(40, replyCount: 2),
                onReply: () {},
                onOpenReplies: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.reply_outlined), findsOneWidget);
      expect(find.byIcon(Icons.translate_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
    },
  );

  testWidgets('comments page renders the root feed and opens its thread', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(_FakeCommentRepository()),
        ],
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const IllustCommentsPage(illustId: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('comment 11'), findsOneWidget);
    expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(CommentRepliesPage), findsOneWidget);
  });
}
