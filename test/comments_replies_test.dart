import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/haptics/app_haptics.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/app/widgets/feed/feed_states.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
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
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/context.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _StubAccountStore extends AccountStore {
  _StubAccountStore();

  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [Account(id: 'account', userId: 10, name: 'tester')],
    currentId: 'account',
  );
}

Future<ProviderContainer> _apiContainer(
  Future<http.Response> Function(http.Request) handler,
) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final credentials = FakeCredentialStore(
    values: const {
      'account': Credential(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
      ),
    },
  );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: 'account', userId: 10, name: 'tester')],
          currentId: 'account',
        ),
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
  int workId = 1,
  CommentWorkKind kind = CommentWorkKind.illust,
  int userId = 10,
  int? parentCommentId,
  int? rootCommentId,
  int replyCount = 0,
  String? content,
}) => CommentEntity(
  id: id,
  workId: workId,
  kind: kind,
  parentCommentId: parentCommentId,
  rootCommentId: rootCommentId ?? id,
  user: UserEntity(id: userId, name: 'user $userId', account: 'user_$userId'),
  content: content ?? 'comment $id',
  createdAt: DateTime.utc(2026, 8, 27),
  hasReplies: replyCount > 0,
  replyCount: replyCount,
);

class _FakeCommentRepository implements CommentRepository {
  final requests = <CommentFeedQuery>[];
  int deleteCalls = 0;
  Completer<CommentEntity>? addCompleter;
  List<CommentEntity>? rootComments;
  List<CommentEntity>? replies;
  Object? addError;

  @override
  Future<CommentPage> fetchComments(
    int workId, {
    CommentWorkKind kind = CommentWorkKind.illust,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final query = CommentFeedQuery.root(workId: workId, kind: kind);
    requests.add(query);
    return CommentPage(
      comments: rootComments ?? [_comment(11, workId: workId, replyCount: 1)],
      nextUrl: null,
    );
  }

  @override
  Future<CommentPage> fetchReplies(
    int rootCommentId, {
    required int workId,
    CommentWorkKind kind = CommentWorkKind.illust,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final query = CommentFeedQuery.replies(
      workId: workId,
      kind: kind,
      rootCommentId: rootCommentId,
    );
    requests.add(query);
    return CommentPage(
      comments:
          replies ??
          [
            _comment(
              12,
              workId: workId,
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
  }) {
    final completer = addCompleter;
    if (completer != null) return completer.future;
    final error = addError;
    if (error != null) return Future.error(error);
    return Future.value(_comment(20));
  }

  @override
  Future<void> deleteComment(
    int commentId, {
    CommentWorkKind kind = CommentWorkKind.illust,
    CancelToken? cancelToken,
  }) async {
    deleteCalls++;
  }
}

void main() {
  test('comment parsing keeps root, parent and stamp fields distinct', () {
    final root = CommentEntity.fromJson(
      _commentJson(100, replyCount: 2),
      workId: 50,
    );
    final reply = CommentEntity.fromJson(
      _commentJson(101, userId: 11),
      workId: 50,
      rootCommentId: root.id,
    );
    final stamped = CommentEntity.fromJson(
      _commentJson(
        102,
        stamp: {'stamp_id': 101, 'stamp_url': 'https://example.test/101.jpg'},
      ),
      workId: 50,
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
    final replyPage = await repository.fetchReplies(100, workId: 50);
    final added = await repository.addComment(
      const CommentAddRequest(
        workId: 50,
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

  test('novel comments use the novel endpoint family and novel_id', () async {
    final paths = <String>[];
    final container = await _apiContainer((request) async {
      paths.add(request.url.path);
      switch (request.url.path) {
        case '/v3/novel/comments':
          expect(request.url.queryParameters, {'novel_id': '60'});
          return _json({
            'comments': [_commentJson(200)],
            'next_url': null,
          });
        case '/v2/novel/comment/replies':
          expect(request.url.queryParameters, {'comment_id': '200'});
          return _json({
            'comments': [_commentJson(201, userId: 11)],
            'next_url': null,
          });
        case '/v1/novel/comment/add':
          expect(request.method, 'POST');
          expect(request.bodyFields, {
            'novel_id': '60',
            'comment': 'hello novel',
          });
          return _json({'comment': _commentJson(202)});
        case '/v1/novel/comment/delete':
          expect(request.bodyFields, {'comment_id': '202'});
          return _json({'is_success': true});
        default:
          return http.Response('unexpected path', 404);
      }
    });
    addTearDown(container.dispose);
    final repository = container.read(commentRepositoryProvider);

    final page = await repository.fetchComments(
      60,
      kind: CommentWorkKind.novel,
    );
    await repository.fetchReplies(200, workId: 60, kind: CommentWorkKind.novel);
    final added = await repository.addComment(
      const CommentAddRequest(
        workId: 60,
        kind: CommentWorkKind.novel,
        text: 'hello novel',
      ),
    );
    await repository.deleteComment(202, kind: CommentWorkKind.novel);

    expect(page.comments.single.kind, CommentWorkKind.novel);
    expect(page.comments.single.workId, 60);
    expect(added.kind, CommentWorkKind.novel);
    expect(paths, [
      '/v3/novel/comments',
      '/v2/novel/comment/replies',
      '/v1/novel/comment/add',
      '/v1/novel/comment/delete',
    ]);
  });

  test('comment cursors are pinned to their endpoint and thread', () async {
    final container = await _apiContainer(
      (_) async => _json({'comments': <Object?>[], 'next_url': null}),
    );
    addTearDown(container.dispose);
    final repository = container.read(commentRepositoryProvider);
    const root = CommentFeedQuery.root(workId: 50);
    const replies = CommentFeedQuery.replies(workId: 50, rootCommentId: 100);
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
      final rootQuery = const CommentFeedQuery.root(workId: 1);
      final replyQuery = const CommentFeedQuery.replies(
        workId: 1,
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
        workId: 1,
        parentCommentId: 10,
        rootCommentId: 10,
      )!;
      expect(
        store.beginSend(workId: 1, parentCommentId: 10, rootCommentId: 10),
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

      const root = CommentFeedQuery.root(workId: 1);
      const replies = CommentFeedQuery.replies(workId: 1, rootCommentId: 11);
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
      final rootQuery = const CommentFeedQuery.root(workId: 1);
      final repliesQuery = const CommentFeedQuery.replies(
        workId: 1,
        rootCommentId: 20,
      );
      store.mergePage(rootQuery, [_comment(20, replyCount: 1)]);
      store.mergePage(repliesQuery, [
        _comment(21, parentCommentId: 20, rootCommentId: 20),
      ]);
      final first = store.beginSend(workId: 1)!;
      store.failSend(first, StateError('network'));
      final second = store.beginSend(workId: 1)!;
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
        const CommentAddRequest(workId: 1, text: 'pending'),
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
      return _jsonValue([
        [
          ['你好', 'hello', null, null, 1],
        ],
      ]);
    });
    final service = GoogleCommentTranslationService(client);
    expect(await service.translate('hello', targetLanguage: 'zh'), '你好');
  });

  testWidgets('composer grids size columns to the available width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int crossAxisCount() =>
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount;

    Future<void> openPanelAt(double width, String tooltip) async {
      tester.view.physicalSize = Size(width, 600);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(
            // A fresh subtree per width — otherwise the composer's State
            // survives pumpWidget and the tap toggles the still-open panel
            // back to none.
            key: ValueKey(width),
            resizeToAvoidBottomInset: false,
            body: CommentComposer(
              onSend: (_) async {},
              onStampSend: (_) async {},
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
    }

    // 320dp: floor(320/48)=6 emoji columns — a fixed 10 would shrink cells
    // below the ~48dp touch target.
    await openPanelAt(320, 'Emoji');
    expect(crossAxisCount(), 6);

    // 390dp: floor(390/48)=8.
    await openPanelAt(390, 'Emoji');
    expect(crossAxisCount(), 8);

    // 840dp: floor(840/48)=17 — capped at the densest useful 10.
    await openPanelAt(840, 'Emoji');
    expect(crossAxisCount(), 10);

    // Stamps use ~96dp cells: floor(320/96)=3; floor(840/96)=8 → cap 5.
    await openPanelAt(320, 'Stamp');
    expect(crossAxisCount(), 3);
    await openPanelAt(840, 'Stamp');
    expect(crossAxisCount(), 5);

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
            localizationsDelegates: appLocalizationsDelegates,
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
    final router = createPixivRouter(
      initialLocation: '/recommended/illust/1/comments',
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(_FakeCommentRepository()),
        ],
        child: MaterialApp.router(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: appLocalizationsDelegates,
          routerConfig: router,
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

  Widget composerApp(Widget home) => MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: appLocalizationsDelegates,
    home: home,
  );

  Widget bareComposer() => Scaffold(
    // Same contract as the real pages: the Scaffold stays out of insets so
    // the composer's bottom extent can observe MediaQuery.viewInsets.
    resizeToAvoidBottomInset: false,
    body: Column(
      children: [
        const Expanded(child: SizedBox()),
        CommentComposer(onSend: (_) async {}, onStampSend: (_) async {}),
      ],
    ),
  );

  testWidgets('composer keeps the keyboard and the panels mutually exclusive', (
    tester,
  ) async {
    await tester.pumpWidget(composerApp(bareComposer()));
    EditableText field() =>
        tester.widget<EditableText>(find.byType(EditableText));

    // none → emoji: opening the panel releases the field.
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    expect(find.byType(GridView), findsOneWidget);
    expect(field().focusNode.hasFocus, isFalse);

    // Tapping the field while a panel is open converges to the keyboard leg:
    // the panel closes instead of coexisting underneath the raised IME.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(field().focusNode.hasFocus, isTrue);
    expect(find.byType(GridView), findsNothing);

    // Same convergence from the stamp leg.
    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(field().focusNode.hasFocus, isTrue);
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('inserting an emoji closes the panel and refocuses the field', (
    tester,
  ) async {
    await tester.pumpWidget(composerApp(bareComposer()));
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();

    await tester.tap(find.byType(InkResponse).first);
    await tester.pump();

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, '(${commentEmojiNames.first})');
    expect(find.byType(GridView), findsNothing);
    expect(field.focusNode.hasFocus, isTrue);
  });

  testWidgets('system back closes an open panel before leaving the page', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerApp(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => bareComposer())),
                child: const Text('push'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    expect(find.byType(GridView), findsOneWidget);

    // Back collapses the transient panel; the route stays.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(CommentComposer), findsOneWidget);

    // With the surface at rest the next back leaves normally.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(CommentComposer), findsNothing);
  });

  testWidgets('the keyboard leg does not intercept system back', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerApp(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => bareComposer())),
                child: const Text('push'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    // The IME/system owns this back; the composer never vetoes it.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(CommentComposer), findsNothing);
  });

  testWidgets('composer reserves the sampled keyboard height for panels', (
    tester,
  ) async {
    Widget withInsets(double bottom) => composerApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: EdgeInsets.only(bottom: bottom)),
          child: bareComposer(),
        ),
      ),
    );

    // Focused while the IME reports 300: the composer reserves that extent
    // below the input row (manual insets, no Scaffold resize).
    await tester.pumpWidget(withInsets(0));
    final idleHeight = tester.getSize(find.byType(CommentComposer)).height;
    await tester.pumpWidget(withInsets(300));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      tester.getSize(find.byType(CommentComposer)).height - idleHeight,
      300,
    );

    // Once the IME is gone the panel keeps the sampled height — switching
    // keyboard → panel does not jump.
    await tester.pumpWidget(withInsets(0));
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    expect(tester.getSize(find.byType(GridView)).height, 300);
  });

  testWidgets('composer panel falls back without a keyboard sample', (
    tester,
  ) async {
    // Never focused, no insets: the panel uses the ~280dp fallback.
    await tester.pumpWidget(composerApp(bareComposer()));
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    expect(tester.getSize(find.byType(GridView)).height, 280);
  });

  testWidgets('comments page opts out of Scaffold resizeToAvoidBottomInset', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(_FakeCommentRepository()),
        ],
        child: composerApp(const CommentsPage(workId: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Scaffold>(
            find.descendant(
              of: find.byType(CommentsPage),
              matching: find.byType(Scaffold),
            ),
          )
          .resizeToAvoidBottomInset,
      isFalse,
    );
  });

  testWidgets('replies page opts out of Scaffold resizeToAvoidBottomInset', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(_FakeCommentRepository()),
        ],
        child: composerApp(
          CommentRepliesPage(
            workId: 1,
            rootCommentId: 11,
            rootComment: _comment(11, replyCount: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Scaffold>(
            find.descendant(
              of: find.byType(CommentRepliesPage),
              matching: find.byType(Scaffold),
            ),
          )
          .resizeToAvoidBottomInset,
      isFalse,
    );
  });

  testWidgets('composer input state covers the four-state matrix', (
    tester,
  ) async {
    await tester.pumpWidget(composerApp(bareComposer()));
    CommentComposerState state() =>
        tester.state<CommentComposerState>(find.byType(CommentComposer));
    EditableText field() =>
        tester.widget<EditableText>(find.byType(EditableText));

    expect(state().debugInputState, CommentComposerInputState.none);

    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    expect(state().debugInputState, CommentComposerInputState.emoji);

    // Same-region swap: stamp replaces emoji directly, no intermediate none.
    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();
    expect(state().debugInputState, CommentComposerInputState.stamp);
    expect(find.byType(GridView), findsOneWidget);

    // Toggling the active button rests the surface.
    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();
    expect(state().debugInputState, CommentComposerInputState.none);
    expect(find.byType(GridView), findsNothing);

    // The reply-pill entry point lands on the keyboard leg with real focus.
    state().focusForReply();
    await tester.pump();
    expect(state().debugInputState, CommentComposerInputState.keyboard);
    expect(field().focusNode.hasFocus, isTrue);

    // Focus loss converges keyboard back to the resting surface.
    state().focusForReply();
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(state().debugInputState, CommentComposerInputState.none);
  });

  Future<void> pumpCommentsPage(
    WidgetTester tester,
    _FakeCommentRepository repo,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(repo),
        ],
        child: composerApp(const CommentsPage(workId: 1)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpRepliesPage(
    WidgetTester tester,
    _FakeCommentRepository repo, {
    CommentEntity? root,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(repo),
        ],
        child: composerApp(
          CommentRepliesPage(
            workId: 1,
            rootCommentId: 11,
            rootComment: root ?? _comment(11, replyCount: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('replies page scrolls the root comment with the reply list', (
    tester,
  ) async {
    final repo = _FakeCommentRepository()
      ..replies = [
        for (var i = 0; i < 15; i++)
          _comment(100 + i, parentCommentId: 11, rootCommentId: 11, userId: 20),
      ];
    await pumpRepliesPage(tester, repo);

    expect(find.text('comment 11'), findsOneWidget);
    final before = tester.getTopLeft(find.text('comment 11')).dy;
    // SmoothWheelScroll boots in wheel mode on the desktop test host — the
    // list sits on NeverScrollableScrollPhysics until the first pointer
    // down drops it, so this priming drag only unlocks touch scrolling.
    await tester.drag(find.byType(ListView), const Offset(0, -60));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -60));
    await tester.pump();
    // The root is part of the scrollable feed now — it must move with it.
    expect(tester.getTopLeft(find.text('comment 11')).dy, lessThan(before));
  });

  testWidgets('replies page keeps a reply visible under a long root', (
    tester,
  ) async {
    await pumpRepliesPage(
      tester,
      _FakeCommentRepository(),
      root: _comment(
        11,
        replyCount: 1,
        content: 'long root comment line\n' * 12,
      ),
    );

    // First frame: the feed's leading slot holds the root, and the first
    // reply's row already peeks into the viewport — the old fixed header
    // squeezed the list into an overflowing sliver instead.
    final feedBottom = tester.getRect(find.byType(ListView)).bottom;
    expect(find.byKey(const ValueKey(12)), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey(12))).top,
      lessThan(feedBottom),
    );
    // The header CommentItem (tree order first) is the root, leading the
    // reply rows.
    expect(
      tester.getRect(find.byType(CommentItem).first).top,
      lessThan(tester.getRect(find.byKey(const ValueKey(12))).top),
    );

    // The FeedTail slot still terminates the list after the replies —
    // scroll the long root out of the way to reach it. The first drag
    // only unlocks SmoothWheelScroll's desktop wheel mode.
    await tester.drag(find.byType(ListView), const Offset(0, -60));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pump();
    expect(find.byType(FeedTail), findsOneWidget);
  });

  testWidgets('reply pill pins the target and focuses the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(_StubAccountStore.new),
          commentRepositoryProvider.overrideWithValue(_FakeCommentRepository()),
        ],
        child: composerApp(const CommentsPage(workId: 1)),
      ),
    );
    await tester.pumpAndSettle();

    EditableText field() =>
        tester.widget<EditableText>(find.byType(EditableText));
    expect(field().focusNode.hasFocus, isFalse);

    await tester.tap(find.byIcon(Icons.reply_outlined).first);
    await tester.pump();

    // The composer owns the keyboard leg and shows the pinned target.
    expect(field().focusNode.hasFocus, isTrue);
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.textContaining('user 10'),
      ),
      findsOneWidget,
    );
    // The reference row is one semantics container for screen readers —
    // its nearest Semantics ancestor is a container.
    final replyText = find.descendant(
      of: find.byType(CommentComposer),
      matching: find.textContaining('user 10'),
    );
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(of: replyText, matching: find.byType(Semantics))
                .first,
          )
          .container,
      isTrue,
    );
  });

  testWidgets('replies page primes the reference row with the root author', (
    tester,
  ) async {
    await pumpRepliesPage(tester, _FakeCommentRepository());

    // No explicit target yet — the composer still names the root author.
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.textContaining('user 10'),
      ),
      findsOneWidget,
    );

    // Tapping the root's own reply pill focuses the composer too.
    await tester.tap(find.byIcon(Icons.reply_outlined).first);
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
  });

  testWidgets('send success clears the reply target and the draft', (
    tester,
  ) async {
    await pumpCommentsPage(tester, _FakeCommentRepository());

    await tester.tap(find.byIcon(Icons.reply_outlined).first);
    await tester.pump();
    Finder replyRef() => find.descendant(
      of: find.byType(CommentComposer),
      matching: find.textContaining('user 10'),
    );
    expect(replyRef(), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hi there');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle();

    // Success clears both the draft and the pinned reply target.
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      isEmpty,
    );
    expect(replyRef(), findsNothing);
  });

  testWidgets('a mid-flight retarget is not cleared by the old send', (
    tester,
  ) async {
    final repo = _FakeCommentRepository()
      ..rootComments = [_comment(11, replyCount: 1), _comment(12, userId: 21)]
      ..addCompleter = Completer<CommentEntity>();
    await pumpCommentsPage(tester, repo);

    await tester.tap(find.byIcon(Icons.reply_outlined).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi there');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();

    // While the first send is in flight the user re-targets comment 12.
    await tester.tap(find.byIcon(Icons.reply_outlined).last);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.textContaining('user 21'),
      ),
      findsOneWidget,
    );

    repo.addCompleter!.complete(_comment(20));
    await tester.pumpAndSettle();

    // The completed send must not clear the newer target.
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.textContaining('user 21'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'replies send failure keeps the draft and target, flags permission',
    (tester) async {
      final repo = _FakeCommentRepository()
        ..addError = const CommentPermissionException();
      await pumpRepliesPage(tester, repo);

      // The default target is the root author; a failed send keeps it.
      await tester.enterText(find.byType(TextField), 'keep me');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_outlined));
      await tester.pump();
      await tester.pump();

      final context = tester.element(find.byType(CommentRepliesPage));
      expect(find.text(context.l10n.commentPermissionDenied), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'keep me',
      );
      expect(
        find.descendant(
          of: find.byType(CommentComposer),
          matching: find.textContaining('user 10'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('grid cells expose button semantics with labels', (tester) async {
    await tester.pumpWidget(composerApp(bareComposer()));
    final context = tester.element(find.byType(CommentComposer));

    bool isCellButton(Widget widget, String label) =>
        widget is Semantics &&
        widget.properties.button == true &&
        widget.properties.label == label;

    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();

    // Emoji cells announce as buttons named after the emoji token; the
    // images stay decorative-only.
    expect(
      find.byWidgetPredicate(
        (widget) => isCellButton(widget, commentEmojiNames.first),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(GridView),
        matching: find.byType(ExcludeSemantics),
      ),
      findsWidgets,
    );
    // The panel grid itself is one semantics container.
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(
                  of: find.byType(GridView),
                  matching: find.byType(Semantics),
                )
                .first,
          )
          .container,
      isTrue,
    );

    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) => isCellButton(
          widget,
          context.l10n.commentStampLabel(commentStampIds.first),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('send shows an in-button progress indicator while busy', (
    tester,
  ) async {
    final repo = _FakeCommentRepository()
      ..addCompleter = Completer<CommentEntity>();
    await pumpCommentsPage(tester, repo);
    final context = tester.element(find.byType(CommentComposer));

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();

    Finder spinner() => find.descendant(
      of: find.byType(CommentComposer),
      matching: find.byType(CircularProgressIndicator),
    );
    // The send affordance becomes a labelled spinner — the visible
    // non-optimistic wait.
    expect(spinner(), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == context.l10n.commentSending,
        ),
      ),
      findsOneWidget,
    );
    // And the button stays disabled while the request is in flight.
    expect(
      tester
          .widget<IconButton>(
            find
                .ancestor(
                  of: find.byType(CircularProgressIndicator),
                  matching: find.byType(IconButton),
                )
                .first,
          )
          .onPressed,
      isNull,
    );

    repo.addCompleter!.complete(_comment(20));
    await tester.pumpAndSettle();
    expect(spinner(), findsNothing);
  });

  testWidgets('busy spinner survives the early-false mutation key window', (
    tester,
  ) async {
    final repo = _FakeCommentRepository()
      ..rootComments = [_comment(11, replyCount: 1), _comment(12, userId: 21)]
      ..addCompleter = Completer<CommentEntity>();
    await pumpCommentsPage(tester, repo);

    await tester.tap(find.byIcon(Icons.reply_outlined).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();

    // Re-target mid-flight: the mutation key now maps to comment 12, which
    // has no pending send — `sending` reports false while `_busy` still
    // covers the await. The spinner must persist through the window.
    await tester.tap(find.byIcon(Icons.reply_outlined).last);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    repo.addCompleter!.complete(_comment(20));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
  });

  /// Captures `HapticFeedback.vibrate` calls landing on the platform channel
  /// — the observable seam of the static [AppHaptics] owner.
  List<String> mockHaptics() {
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add(call.arguments as String);
      }
      return null;
    });
    AppHaptics.debugReset();
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      AppHaptics.debugReset();
    });
    return calls;
  }

  Future<void> typeAndSend(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle();
  }

  testWidgets('send success fires one mediumImpact via AppHaptics', (
    tester,
  ) async {
    final haptics = mockHaptics();
    await pumpCommentsPage(tester, _FakeCommentRepository());

    await typeAndSend(tester);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('stamp send success fires the same success level', (
    tester,
  ) async {
    final haptics = mockHaptics();
    await pumpCommentsPage(tester, _FakeCommentRepository());

    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();
    await tester.tap(
      find
          .descendant(
            of: find.byType(GridView),
            matching: find.byType(InkResponse),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('replies send success fires the same success level', (
    tester,
  ) async {
    final haptics = mockHaptics();
    await pumpRepliesPage(tester, _FakeCommentRepository());

    await typeAndSend(tester);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('send failure fires no haptic', (tester) async {
    final haptics = mockHaptics();
    await pumpCommentsPage(
      tester,
      _FakeCommentRepository()..addError = StateError('offline'),
    );

    await typeAndSend(tester);
    expect(haptics, isEmpty);
  });
}
