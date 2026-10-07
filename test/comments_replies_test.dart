import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/comments/comment_actions.dart';
import 'package:parfait/core/comments/comment_assets.dart';
import 'package:parfait/core/comments/comment_feed_controller.dart';
import 'package:parfait/core/comments/comment_models.dart';
import 'package:parfait/core/comments/comment_repository.dart';
import 'package:parfait/core/comments/comment_store.dart';
import 'package:parfait/core/comments/comment_translation.dart';
import 'package:parfait/core/entity/comment_entity.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/features/comments/comment_input.dart';
import 'package:parfait/features/comments/comment_item.dart';
import 'package:parfait/features/comments/comments_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/context.dart';
import 'package:parfait/app/motion/removal.dart';

import 'helpers/image_network.dart';
import 'helpers/comment_world.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

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

/// The reply text button of every comment row (zh).
Finder _replyButton() => find.widgetWithText(TextButton, '回复');

void main() {
  // Stamp cells are PixivImages, which read settings; shards run single
  // tests, so no test may rely on another having installed preferences.
  setUp(installMemoryPreferences);

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
        overrides: [accountStoreProvider.overrideWith(commentsAccountStore)],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final store = container.read(commentStoreProvider.notifier);
      final rootQuery = const CommentFeedQuery.root(workId: 1);
      final replyQuery = const CommentFeedQuery.replies(
        workId: 1,
        rootCommentId: 10,
      );
      final root = sampleComment(10, replyCount: 0);
      final reply = sampleComment(11, parentCommentId: 10, rootCommentId: 10);
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
      final newReply = sampleComment(
        12,
        parentCommentId: 10,
        rootCommentId: 10,
      );
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
      final repository = FakeCommentRepository();
      final container = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWith(commentsAccountStore),
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
        overrides: [accountStoreProvider.overrideWith(commentsAccountStore)],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final store = container.read(commentStoreProvider.notifier);
      final rootQuery = const CommentFeedQuery.root(workId: 1);
      final repliesQuery = const CommentFeedQuery.replies(
        workId: 1,
        rootCommentId: 20,
      );
      store.mergePage(rootQuery, [sampleComment(20, replyCount: 1)]);
      store.mergePage(repliesQuery, [
        sampleComment(21, parentCommentId: 20, rootCommentId: 20),
      ]);
      final first = store.beginSend(workId: 1)!;
      store.failSend(first, StateError('network'));
      final second = store.beginSend(workId: 1)!;
      store.commitSend(first, sampleComment(22));
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
      final repository = FakeCommentRepository();
      final container = ProviderContainer(
        overrides: [
          accountStoreProvider.overrideWith(commentsAccountStore),
          commentRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final action = container.read(commentActionsProvider);
      final result = sampleComment(20);
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

      final other = sampleComment(31, userId: 11);
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
        withStalledImages(
          MaterialApp(
            builder: promptHostBuilder,
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

  test('stamp URLs follow the pixiv generated-stamps template', () {
    expect(
      commentStampUrl(101),
      'https://s.pximg.net/common/images/stamp/generated-stamps/101_s.jpg',
    );
  });

  testWidgets('stamp picker loads pixiv stamps and sends the tapped id', (
    tester,
  ) async {
    final sent = <int>[];
    await tester.pumpWidget(
      withStalledImages(
        MaterialApp(
          builder: promptHostBuilder,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: CommentComposer(
              onSend: (_) async {},
              onStampSend: (id) async => sent.add(id),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();

    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.childrenDelegate as SliverChildBuilderDelegate).childCount,
      commentStampIds.length,
    );
    final first = tester.widget<PixivImage>(
      find
          .descendant(
            of: find.byType(GridView),
            matching: find.byType(PixivImage),
          )
          .first,
    );
    expect(first.url, commentStampUrl(101));
    expect(first.fit, BoxFit.contain);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is AssetImage,
      ),
      findsNothing,
    );

    await tester.tap(
      find
          .descendant(
            of: find.byType(GridView),
            matching: find.byType(InkResponse),
          )
          .first,
    );
    await tester.pump();
    expect(sent, [101]);
  });

  group('stamp comment body', () {
    Future<void> pumpStampComment(WidgetTester tester, String? url) {
      final base = sampleComment(41, content: '');
      return tester.pumpWidget(
        ProviderScope(
          overrides: [accountStoreProvider.overrideWith(commentsAccountStore)],
          child: MaterialApp(
            builder: promptHostBuilder,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: appLocalizationsDelegates,
            home: Scaffold(
              body: CommentItem(
                comment: CommentEntity(
                  id: base.id,
                  workId: base.workId,
                  kind: base.kind,
                  parentCommentId: null,
                  rootCommentId: base.rootCommentId,
                  user: base.user,
                  content: '',
                  createdAt: base.createdAt,
                  stampId: 101,
                  stampUrl: url,
                ),
                onReply: () {},
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows the stamp from its pixiv URL, left-aligned', (
      tester,
    ) async {
      final url = commentStampUrl(101);
      await pumpStampComment(tester, url);
      await tester.pump();

      final image = tester.widget<PixivImage>(
        find.byWidgetPredicate(
          (widget) => widget is PixivImage && widget.url == url,
        ),
      );
      expect(image.alignment, Alignment.centerLeft);
      expect(image.fit, BoxFit.contain);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is AssetImage,
        ),
        findsNothing,
      );
    });

    testWidgets('shows a placeholder icon without a stamp URL', (tester) async {
      await pumpStampComment(tester, null);
      await tester.pump();

      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    });
  });

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
          accountStoreProvider.overrideWith(commentsAccountStore),
          commentRepositoryProvider.overrideWithValue(FakeCommentRepository()),
        ],
        child: MaterialApp.router(
          builder: promptHostBuilder,
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
    expect(find.widgetWithText(TextButton, '查看 1 条回复'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '查看 1 条回复'));
    await tester.pumpAndSettle();
    expect(find.byType(CommentRepliesPage), findsOneWidget);
  });

  testWidgets(
    'keyboard open pads only the composer — page chrome holds still',
    (tester) async {
      // §5.6/§4.10 form geometry: the shell opts out of Scaffold insets, so
      // a focused field + IME must never translate the page's main
      // controls — the composer reserves the keyboard extent itself.
      installMemoryPreferences();
      tester.view.physicalSize = const Size(600, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final router = createPixivRouter(
        initialLocation: '/recommended/illust/1/comments',
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            accountStoreProvider.overrideWith(commentsAccountStore),
            commentRepositoryProvider.overrideWithValue(
              FakeCommentRepository(),
            ),
          ],
          child: MaterialApp.router(
            builder: promptHostBuilder,
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

      // The pushed page's own Scaffold is the one that must stay out of
      // insets — assert the contract, not just the geometry.
      final pageScaffold = find.ancestor(
        of: find.byType(CommentComposer),
        matching: find.byType(Scaffold),
      );
      expect(
        tester.widget<Scaffold>(pageScaffold.first).resizeToAvoidBottomInset,
        isFalse,
      );

      final titleTop = tester.getTopLeft(find.text('评论')).dy;
      final commentTop = tester.getTopLeft(find.text('comment 11')).dy;
      final sendTop = tester.getTopLeft(find.byIcon(Icons.send_outlined)).dy;

      // Focus the composer field, then the IME reports its height — the
      // composer reserves the keyboard extent in its own bottom slot.
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      // The feed's easy_refresh ballistic defers one notifyListeners via a
      // zero-delay Future when its axis first resolves — settle it out.
      await tester.pumpAndSettle();

      // Page chrome and feed did not translate — only the feed's Expanded
      // slot shrank while the composer grew upward into it.
      expect(tester.getTopLeft(find.text('评论')).dy, titleTop);
      expect(tester.getTopLeft(find.text('comment 11')).dy, commentTop);

      // The input row (and its send affordance) rides up by exactly the
      // keyboard height and lands fully above the IME.
      expect(
        tester.getTopLeft(find.byIcon(Icons.send_outlined)).dy,
        sendTop - 300,
      );
      expect(
        tester.getBottomLeft(find.byIcon(Icons.send_outlined)).dy,
        lessThanOrEqualTo(844 - 300),
      );
    },
  );

  Widget composerApp(Widget home) => withStalledImages(
    MaterialApp(
      builder: promptHostBuilder,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: appLocalizationsDelegates,
      home: home,
    ),
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
          accountStoreProvider.overrideWith(commentsAccountStore),
          commentRepositoryProvider.overrideWithValue(FakeCommentRepository()),
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
          accountStoreProvider.overrideWith(commentsAccountStore),
          commentRepositoryProvider.overrideWithValue(FakeCommentRepository()),
        ],
        child: composerApp(
          CommentRepliesPage(
            workId: 1,
            rootCommentId: 11,
            rootComment: sampleComment(11, replyCount: 1),
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
    FakeCommentRepository repo,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(commentsAccountStore),
          commentRepositoryProvider.overrideWithValue(repo),
        ],
        child: composerApp(const CommentsPage(workId: 1)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpRepliesPage(
    WidgetTester tester,
    FakeCommentRepository repo, {
    CommentEntity? root,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(commentsAccountStore),
          commentRepositoryProvider.overrideWithValue(repo),
        ],
        child: composerApp(
          CommentRepliesPage(
            workId: 1,
            rootCommentId: 11,
            rootComment: root ?? sampleComment(11, replyCount: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('replies page scrolls the root comment with the reply list', (
    tester,
  ) async {
    final repo = FakeCommentRepository()
      ..replies = [
        for (var i = 0; i < 15; i++)
          sampleComment(
            100 + i,
            parentCommentId: 11,
            rootCommentId: 11,
            userId: 20,
          ),
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
      FakeCommentRepository(),
      root: sampleComment(
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
    // Reply rows delete through the exit-first removal.
    expect(tester.widget(find.byKey(const ValueKey(12))), isA<Removable>());
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
          accountStoreProvider.overrideWith(commentsAccountStore),
          commentRepositoryProvider.overrideWithValue(FakeCommentRepository()),
        ],
        child: composerApp(const CommentsPage(workId: 1)),
      ),
    );
    await tester.pumpAndSettle();

    EditableText field() =>
        tester.widget<EditableText>(find.byType(EditableText));
    expect(field().focusNode.hasFocus, isFalse);

    await tester.tap(_replyButton().first);
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
    await pumpRepliesPage(tester, FakeCommentRepository());

    // No explicit target yet — the composer still names the root author.
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.textContaining('user 10'),
      ),
      findsOneWidget,
    );

    // Tapping the root's own reply pill focuses the composer too.
    await tester.tap(_replyButton().first);
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
  });

  testWidgets('send success clears the reply target and the draft', (
    tester,
  ) async {
    await pumpCommentsPage(tester, FakeCommentRepository());

    await tester.tap(_replyButton().first);
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

  testWidgets(
    'replies send success returns the reference row to the root author',
    (tester) async {
      final repo = FakeCommentRepository()
        ..replies = [
          sampleComment(12, parentCommentId: 11, rootCommentId: 11, userId: 20),
        ];
      await pumpRepliesPage(tester, repo);

      // Pin a non-root target: the reply row's pill trails the header
      // root's pill in tree order.
      await tester.tap(_replyButton().last);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(CommentComposer),
          matching: find.textContaining('user 20'),
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_outlined));
      await tester.pumpAndSettle();

      // Success drops the explicit target — the reference row falls back
      // to the root author (`_replyTarget ?? root`), and the draft clears.
      expect(
        find.descendant(
          of: find.byType(CommentComposer),
          matching: find.textContaining('user 20'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(CommentComposer),
          matching: find.textContaining('user 10'),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
    },
  );

  testWidgets('a mid-flight retarget is not cleared by the old send', (
    tester,
  ) async {
    final repo = FakeCommentRepository()
      ..rootComments = [
        sampleComment(11, replyCount: 1),
        sampleComment(12, userId: 21),
      ]
      ..addCompleter = Completer<CommentEntity>();
    await pumpCommentsPage(tester, repo);

    await tester.tap(_replyButton().first);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi there');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();

    // While the first send is in flight the user re-targets comment 12.
    await tester.tap(_replyButton().last);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.textContaining('user 21'),
      ),
      findsOneWidget,
    );

    repo.addCompleter!.complete(sampleComment(20));
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
      final repo = FakeCommentRepository()
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
    final repo = FakeCommentRepository()
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

    repo.addCompleter!.complete(sampleComment(20));
    await tester.pumpAndSettle();
    expect(spinner(), findsNothing);
  });

  testWidgets('busy spinner survives the early-false mutation key window', (
    tester,
  ) async {
    final repo = FakeCommentRepository()
      ..rootComments = [
        sampleComment(11, replyCount: 1),
        sampleComment(12, userId: 21),
      ]
      ..addCompleter = Completer<CommentEntity>();
    await pumpCommentsPage(tester, repo);

    await tester.tap(_replyButton().first);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();

    // Re-target mid-flight: the mutation key now maps to comment 12, which
    // has no pending send — `sending` reports false while `_busy` still
    // covers the await. The spinner must persist through the window.
    await tester.tap(_replyButton().last);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    repo.addCompleter!.complete(sampleComment(20));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(CommentComposer),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
  });

  Future<void> typeAndSend(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle();
  }

  testWidgets('send success fires one success haptic', (tester) async {
    final haptics = recordHaptics();
    await pumpCommentsPage(tester, FakeCommentRepository());

    await typeAndSend(tester);
    expect(haptics.roles, [HapticRole.success]);
  });

  testWidgets('stamp send success fires the same success level', (
    tester,
  ) async {
    final haptics = recordHaptics();
    await pumpCommentsPage(tester, FakeCommentRepository());

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
    expect(haptics.roles, [HapticRole.success]);
  });

  testWidgets('replies send success fires the same success level', (
    tester,
  ) async {
    final haptics = recordHaptics();
    await pumpRepliesPage(tester, FakeCommentRepository());

    await typeAndSend(tester);
    expect(haptics.roles, [HapticRole.success]);
  });

  testWidgets('send failure fires no haptic', (tester) async {
    final haptics = recordHaptics();
    await pumpCommentsPage(
      tester,
      FakeCommentRepository()..addError = StateError('offline'),
    );

    await typeAndSend(tester);
    expect(haptics.played, isEmpty);
  });
}
