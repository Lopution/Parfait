import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/widgets/comment_composer.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/comments/comment_actions.dart';
import 'package:parfait/core/comments/comment_assets.dart';
import 'package:parfait/core/comments/comment_feed_controller.dart';
import 'package:parfait/core/comments/comment_models.dart';
import 'package:parfait/core/comments/comment_repository.dart';
import 'package:parfait/core/comments/comment_store.dart';
import 'package:parfait/core/entity/comment_entity.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/settings/keyboard_heights.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/features/comments/comments_page.dart';
import 'package:parfait/features/illust/detail/detail_page_activity.dart';
import 'package:parfait/features/illust/detail/widgets/detail_comment_layer.dart';
import 'package:parfait/l10n/context.dart';

import 'helpers/api_responses.dart';
import 'helpers/comment_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/image_network.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/test_preferences.dart';
import 'helpers/view_size.dart';

Future<ProviderContainer> _apiContainer(
  Future<http.Response> Function(http.Request) handler,
) async {
  return signedInApiContainer(
    MockClient(handler),
    account: const Account(id: 'account', userId: 10, name: 'tester'),
  );
}

http.Response _jsonValue(Object value) => jsonResponse(value);

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

Finder _replyButton() => find.widgetWithText(TextButton, '回复');

Future<void> _settlePanel(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

List<Override> _signedIn() => [
  accountStoreProvider.overrideWith(commentsAccountStore),
];

Future<void> _pumpCommentsRoute(
  WidgetTester tester, [
  CommentApi? comments,
]) async {
  await tester.pumpWidget(
    localizedRouterApp(
      pixivRouter('/recommended/illust/1/comments'),
      container: await commentWorld(
        comments ?? CommentApi(),
        routes: {
          ...shellRoutes,
          '/v1/illust/detail': answer({'illust': illustJson(1)}),
        },
      ),
      builder: promptHostBuilder,
    ),
  );
  await tester.pump();
  await tester.pump();
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

  test('comment repository maps each kind to its endpoint family', () async {
    for (final (kind, word, id) in [
      (CommentWorkKind.illust, 'illust', 50),
      (CommentWorkKind.novel, 'novel', 60),
    ]) {
      final paths = <String>[];
      final container = await _apiContainer((request) async {
        paths.add(request.url.path);
        switch (request.url.path.replaceFirst(word, '*')) {
          case '/v3/*/comments':
            expect(request.url.queryParameters, {'${word}_id': '$id'});
            return _json({
              'comments': [_commentJson(100, replyCount: 1)],
              'next_url': null,
            });
          case '/v2/*/comment/replies':
            expect(request.url.queryParameters, {'comment_id': '100'});
            return _json({
              'comments': [_commentJson(101, userId: 11)],
              'next_url': null,
            });
          case '/v1/*/comment/add':
            expect(request.method, 'POST');
            expect(request.bodyFields, {
              '${word}_id': '$id',
              'comment': 'new comment',
              'parent_comment_id': '100',
            });
            return _json({'comment': _commentJson(102)});
          case '/v1/*/comment/delete':
            expect(request.method, 'POST');
            expect(request.bodyFields, {'comment_id': '102'});
            return _json({'is_success': true});
          default:
            return http.Response('unexpected path', 404);
        }
      });
      final repository = container.read(commentRepositoryProvider);

      final rootPage = await repository.fetchComments(id, kind: kind);
      final replyPage = await repository.fetchReplies(
        100,
        workId: id,
        kind: kind,
      );
      final added = await repository.addComment(
        CommentAddRequest(
          workId: id,
          kind: kind,
          parentCommentId: 100,
          rootCommentId: 100,
          text: 'new comment',
        ),
      );
      await repository.deleteComment(102, kind: kind);

      expect(rootPage.comments.single.rootCommentId, 100);
      expect(rootPage.comments.single.kind, kind);
      expect(rootPage.comments.single.workId, id);
      expect(replyPage.comments.single.parentCommentId, 100);
      expect(replyPage.comments.single.rootCommentId, 100);
      expect((added.id, added.kind), (102, kind));
      expect(paths, [
        '/v3/$word/comments',
        '/v2/$word/comment/replies',
        '/v1/$word/comment/add',
        '/v1/$word/comment/delete',
      ]);
    }
  });

  test(
    'deleted authors stay visible and one malformed comment is skipped',
    () async {
      final deleted = _commentJson(103, userId: 0);
      (deleted['user'] as Map<String, dynamic>)['name'] = '';
      final unnamed = _commentJson(106, userId: 0);
      (unnamed['user'] as Map<String, dynamic>).remove('name');
      final malformed = _commentJson(104);
      (malformed['user'] as Map<String, dynamic>)['name'] = 42;
      final container = await _apiContainer(
        (request) async => _json({
          'comments': [deleted, unnamed, malformed, _commentJson(105)],
          'next_url': null,
        }),
      );

      final page = await container
          .read(commentRepositoryProvider)
          .fetchComments(50);

      expect(page.comments.map((comment) => comment.id).toList(), [
        103,
        106,
        105,
      ]);
      expect(page.comments.first.user.id, 0);
      expect(page.comments.first.user.name, isEmpty);
    },
  );

  test('a closed work keeps pixiv\'s notice out of its feed', () async {
    final container = await _apiContainer(
      (request) async => _json({
        'comments': [_commentJson(15, userId: 11)],
        'next_url': null,
        'comment_access_control': 1,
      }),
    );
    const query = CommentFeedQuery.root(workId: 50);
    final feed = await container.read(commentFeedProvider(query).future);
    expect(feed.ids, isEmpty);
    expect(container.read(commentStoreProvider).get(15), isNull);
    expect(container.read(commentsClosedProvider), {query.workKey: true});
  });

  test('comment cursors are pinned to their endpoint and thread', () async {
    final container = await _apiContainer(
      (_) async => _json({'comments': <Object?>[], 'next_url': null}),
    );
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
      final container = ProviderContainer.test(overrides: _signedIn());
      await container.read(accountStoreProvider.future);
      final store = container.read(commentStoreProvider.notifier);
      const rootQuery = CommentFeedQuery.root(workId: 1);
      const replyQuery = CommentFeedQuery.replies(workId: 1, rootCommentId: 10);
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
      final container = await commentWorld(CommentApi());

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
      final container = ProviderContainer.test(overrides: _signedIn());
      await container.read(accountStoreProvider.future);
      final store = container.read(commentStoreProvider.notifier);
      const rootQuery = CommentFeedQuery.root(workId: 1);
      const repliesQuery = CommentFeedQuery.replies(
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
      final comments = CommentApi()..addGate = Completer<void>();
      final container = await commentWorld(comments);
      container.read(illustStoreProvider).mergeAll([
        parseIllust(illustJson(1)..['total_comments'] = 4),
      ]);
      final action = container.read(commentActionsProvider);
      final result = comments.added;
      final pending = action.send(
        const CommentAddRequest(workId: 1, text: 'pending'),
      );
      await pumpEventQueue();
      expect(container.read(commentStoreProvider.notifier).get(20), isNull);
      comments.addGate!.complete();
      await pending;
      expect(
        container.read(commentStoreProvider.notifier).get(20)!.id,
        result.id,
      );
      expect(
        container.read(commentTotalsProvider)[const CommentFeedQuery.root(
          workId: 1,
        ).workKey],
        5,
      );

      final other = sampleComment(31, userId: 11);
      await expectLater(
        action.delete(other),
        throwsA(isA<CommentPermissionException>()),
      );
      expect(comments.deletes, isEmpty);
      expect(await action.delete(result), isTrue);
      expect(comments.deletes, [20]);
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
    final service = GoogleTranslationTransport(client);
    expect(await service.translate('hello', targetLanguage: 'zh'), '你好');
  });

  test('stamp URLs follow the pixiv generated-stamps template', () {
    expect(
      commentStampUrl(101),
      'https://s.pximg.net/common/images/stamp/generated-stamps/101_s.jpg',
    );
  });

  test('keyboard heights persist per screen shape', () async {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    first.read(keyboardHeightsProvider.notifier)
      ..record(const Size(400, 800), 300)
      ..record(const Size(400, 800), 90)
      ..record(const Size(800, 400), 200);
    await pumpEventQueue();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    second.read(keyboardHeightsProvider);
    await pumpEventQueue();
    final heights = second.read(keyboardHeightsProvider.notifier);
    expect(heights.heightFor(const Size(400, 760)), 300);
    expect(heights.heightFor(const Size(800, 400)), 200);
    expect(heights.heightFor(const Size(600, 900)), isNull);
  });

  testWidgets('comments page renders the root feed and opens its thread', (
    tester,
  ) async {
    await _pumpCommentsRoute(tester);

    expect(find.text('comment 11'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '查看 1 条回复'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '查看 1 条回复'));
    await tester.pumpAndSettle();
    expect(find.byType(CommentRepliesPage), findsOneWidget);
  });

  testWidgets('a work with comments off shows the notice, no composer', (
    tester,
  ) async {
    await _pumpCommentsRoute(tester, CommentApi()..commentsClosed = true);
    expect(find.text('作者已关闭评论'), findsOneWidget);
    expect(find.text('comment 11'), findsNothing);
    expect(find.byType(CommentComposer), findsNothing);
  });

  Widget composerApp(Widget home) =>
      withStalledImages(localizedApp(builder: promptHostBuilder, home: home));

  Widget bareComposer() => Scaffold(
    resizeToAvoidBottomInset: false,
    body: Column(
      children: [
        const Expanded(child: SizedBox()),
        CommentComposer(onSend: (_) async {}, onStampSend: (_) async {}),
      ],
    ),
  );

  testWidgets('a send ending after the detail composer left still lands', (
    tester,
  ) async {
    final workKey = const CommentFeedQuery.root(workId: 42).workKey;
    for (final fails in [false, true]) {
      final gate = Completer<void>();
      installPreferencesForTest(memoryPreferences());
      final container = await signedInApiContainer(
        MockClient((request) async {
          await gate.future;
          return fails
              ? http.Response('{}', 500)
              : _json({'comment': _commentJson(5)});
        }),
        others: const [Account(id: '200', userId: 200, name: 'b')],
      );
      final drafts = container.read(commentDraftsProvider.notifier);
      container.read(commentDraftsProvider);
      final owner = drafts.owner;
      drafts.keep(workKey, 'hi', owner: owner);
      Widget app(Widget home) => localizedApp(
        container: container,
        builder: promptHostBuilder,
        body: home,
      );
      await tester.pumpWidget(
        app(
          DetailPageActivity(
            active: true,
            child: DetailCommentLayer(
              illustId: 42,
              composerKey: GlobalKey<CommentComposerState>(),
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(AppIcons.send));
      await tester.pump();
      await tester.pumpWidget(app(const SizedBox()));
      gate.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('发送评论失败'), fails ? findsOneWidget : findsNothing);
      final draft = container.read(commentDraftsProvider)[workKey];
      expect(draft, fails ? 'hi' : isNull);
      if (!fails) {
        final accounts = container.read(accountStoreProvider.notifier);
        await accounts.switchAccount('200');
        await accounts.switchAccount('100');
        container.read(commentDraftsProvider);
        drafts.keep(workKey, 'new', owner: drafts.owner);
        drafts.keep(workKey, '', owner: owner);
        expect(container.read(commentDraftsProvider)[workKey], 'new');
      }
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    }
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

    await tester.tap(find.byTooltip('表情'));
    await tester.pump();
    await _settlePanel(tester);
    expect(find.byType(GridView), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await _settlePanel(tester);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(CommentComposer), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(CommentComposer), findsNothing);
  });

  Future<void> pumpCommentsPage(
    WidgetTester tester,
    CommentApi comments,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: await commentWorld(comments),
        child: composerApp(const CommentsPage(workId: 1)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpRepliesPage(
    WidgetTester tester,
    CommentApi comments, {
    CommentEntity? root,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: await commentWorld(comments),
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

  testWidgets('a mid-flight retarget keeps the spinner and outlives the old '
      'send', (tester) async {
    final comments = CommentApi()
      ..rootComments = [
        sampleComment(11, replyCount: 1),
        sampleComment(12, userId: 21),
      ]
      ..addGate = Completer<void>();
    await pumpCommentsPage(tester, comments);
    Finder inComposer(Finder finder) =>
        find.descendant(of: find.byType(CommentComposer), matching: finder);

    await tester.tap(_replyButton().first);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi there');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump();

    await tester.tap(_replyButton().last);
    await tester.pump();
    expect(inComposer(find.textContaining('user 21')), findsOneWidget);
    expect(inComposer(find.byType(CircularProgressIndicator)), findsOneWidget);

    comments.addGate!.complete();
    await tester.pumpAndSettle();

    expect(inComposer(find.textContaining('user 21')), findsOneWidget);
    expect(inComposer(find.byType(CircularProgressIndicator)), findsNothing);
  });

  testWidgets(
    'a refused reply send keeps the draft and target, says it failed, '
    'plays no haptic',
    (tester) async {
      final haptics = recordHaptics();
      await pumpRepliesPage(tester, CommentApi()..addFailure = failing(400));

      await tester.enterText(find.byType(TextField), 'keep me');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await tester.pump();
      await tester.pump();

      final context = tester.element(find.byType(CommentRepliesPage));
      expect(find.text(context.l10n.commentSendFailed), findsOneWidget);
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
      await tester.pumpAndSettle();
      expect(haptics.played, isEmpty);
    },
  );

  testWidgets(
    'CommentRepliesPage hides cancel-reply on root target and surfaces send errors after pop',
    (tester) async {
      final gate = Completer<void>();
      final comments = CommentApi()
        ..replies = [
          sampleComment(20, userId: 22, parentCommentId: 10, rootCommentId: 10),
        ]
        ..addGate = gate
        ..addFailure = failing(500);
      final nav = GlobalKey<NavigatorState>();
      final container = await signedInApiContainer(
        PixivApi({...backgroundRoutes, ...comments.routes}).client,
      );
      await tester.pumpWidget(
        localizedApp(
          container: container,
          navigatorKey: nav,
          builder: promptHostBuilder,
          home: const Scaffold(body: Text('home')),
        ),
      );
      unawaited(
        nav.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => CommentRepliesPage(
              workId: 50,
              rootCommentId: 10,
              rootComment: sampleComment(10, userId: 10),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('取消回复'), findsNothing);
      await tester.tap(_replyButton().last);
      await tester.pump();
      expect(find.byTooltip('取消回复'), findsOneWidget);
      await tester.tap(find.byTooltip('取消回复'));
      await tester.pump();
      expect(find.byTooltip('取消回复'), findsNothing);

      await tester.enterText(find.byType(TextField), 'bye');
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.send));
      await tester.pump();
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(CommentRepliesPage), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('发送评论失败'), findsOneWidget);
    },
  );

  testWidgets(
    'keyboard open pads only the composer — page chrome holds still',
    (tester) async {
      setViewSize(tester, const Size(600, 844));
      await _pumpCommentsRoute(tester);
      expect(find.text('comment 11'), findsOneWidget);

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
      final sendTop = tester.getTopLeft(find.byIcon(AppIcons.send)).dy;

      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('评论')).dy, titleTop);
      expect(tester.getTopLeft(find.text('comment 11')).dy, commentTop);
      expect(tester.getTopLeft(find.byIcon(AppIcons.send)).dy, sendTop - 300);
      expect(
        tester.getBottomLeft(find.byIcon(AppIcons.send)).dy,
        lessThanOrEqualTo(844 - 300),
      );
    },
  );
}
