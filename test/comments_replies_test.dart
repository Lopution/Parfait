import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/comments/comment_actions.dart';
import 'package:parfait/core/comments/comment_assets.dart';
import 'package:parfait/core/comments/comment_feed_controller.dart';
import 'package:parfait/core/comments/comment_models.dart';
import 'package:parfait/core/comments/comment_repository.dart';
import 'package:parfait/core/comments/comment_store.dart';
import 'package:parfait/core/settings/keyboard_heights.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/entity/comment_entity.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/app/widgets/comment_composer.dart';
import 'package:parfait/features/comments/comment_item.dart';
import 'package:parfait/features/comments/comments_page.dart';
import 'package:parfait/features/illust/detail/detail_page_activity.dart';
import 'package:parfait/features/illust/detail/widgets/detail_comment_layer.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/context.dart';
import 'package:parfait/app/motion/removal.dart';

import 'helpers/image_network.dart';
import 'helpers/comment_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

Future<ProviderContainer> _apiContainer(
  Future<http.Response> Function(http.Request) handler,
) async {
  final container = await signedInApiContainer(
    MockClient(handler),
    account: const Account(id: 'account', userId: 10, name: 'tester'),
  );
  return container;
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

/// The reply text button of every comment row (zh).
Finder _replyButton() => find.widgetWithText(TextButton, '回复');

/// Lets a composer panel rise or fold away: the keyboard hold runs out,
/// then the sheet spring plays from the frame after. Not pumpAndSettle:
/// stalled stamps keep their placeholders running.
Future<void> _settlePanel(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// The signed-in comment world, over [repository] when given.
List<Override> _signedIn([CommentRepository? repository]) => [
  accountStoreProvider.overrideWith(commentsAccountStore),
  if (repository != null)
    commentRepositoryProvider.overrideWithValue(repository),
];

/// The real comments route of work 1, signed in over a fake repository.
Future<void> _pumpCommentsRoute(WidgetTester tester) async {
  await tester.pumpWidget(
    localizedRouterApp(
      pixivRouter('/recommended/illust/1/comments'),
      overrides: _signedIn(FakeCommentRepository()),
      builder: promptHostBuilder,
    ),
  );
  await tester.pump();
  await tester.pump();
}

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

  // Closed, the response holds one notice from pixiv (id 15, user 11).
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
      final container = ProviderContainer.test(overrides: _signedIn());
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
      final container = ProviderContainer.test(
        overrides: _signedIn(repository),
      );
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
      final container = ProviderContainer.test(overrides: _signedIn());
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
      final container = ProviderContainer.test(
        overrides: _signedIn(repository),
      );
      await container.read(accountStoreProvider.future);
      // Only the detail has counted the work's comments so far.
      container.read(illustStoreProvider).mergeAll([
        parseIllust(illustJson(1)..['total_comments'] = 4),
      ]);
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
      expect(
        container.read(commentTotalsProvider)[CommentFeedQuery.root(
          workId: 1,
        ).workKey],
        5,
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
    final service = GoogleTranslationTransport(client);
    expect(await service.translate('hello', targetLanguage: 'zh'), '你好');
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
        localizedApp(
          builder: promptHostBuilder,
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
    await _settlePanel(tester);

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

  group('stamp comment body', () {});

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
    await tester.pumpWidget(
      localizedRouterApp(
        pixivRouter('/recommended/illust/1/comments'),
        overrides: _signedIn(FakeCommentRepository()..commentsClosed = true),
        builder: promptHostBuilder,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('作者已关闭评论'), findsOneWidget);
    expect(find.text('comment 11'), findsNothing);
    expect(find.byType(CommentComposer), findsNothing);
  });

  testWidgets(
    'keyboard open pads only the composer — page chrome holds still',
    (tester) async {
      // §5.6/§4.10 form geometry: the shell opts out of Scaffold insets, so
      // a focused field + IME must never translate the page's main
      // controls — the composer reserves the keyboard extent itself.
      installMemoryPreferences();
      setViewSize(tester, const Size(600, 844));

      await _pumpCommentsRoute(tester);
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

  Widget composerApp(Widget home) =>
      withStalledImages(localizedApp(builder: promptHostBuilder, home: home));

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

  testWidgets('a send ending after the detail composer left still lands', (
    tester,
  ) async {
    final workKey = CommentFeedQuery.root(workId: 42).workKey;
    // A success still clears the draft, a failure is still reported.
    for (final fails in [false, true]) {
      final gate = Completer<void>();
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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
      await tester.tap(find.byIcon(Icons.send_outlined));
      await tester.pump();
      await tester.pumpWidget(app(const SizedBox()));
      gate.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('发送评论失败'), fails ? findsOneWidget : findsNothing);
      final draft = container.read(commentDraftsProvider)[workKey];
      expect(draft, fails ? 'hi' : isNull);
      if (!fails) {
        // A clear from before A → B → A leaves A's newer draft alone.
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

  testWidgets('composer keeps the keyboard and the panels mutually exclusive', (
    tester,
  ) async {
    await tester.pumpWidget(composerApp(bareComposer()));
    EditableText field() =>
        tester.widget<EditableText>(find.byType(EditableText));

    // none → emoji: opening the panel releases the field.
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    await _settlePanel(tester);
    expect(find.byType(GridView), findsOneWidget);
    expect(field().focusNode.hasFocus, isFalse);

    // Tapping the field while a panel is open converges to the keyboard leg:
    // the panel closes instead of coexisting underneath the raised IME.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(field().focusNode.hasFocus, isTrue);
    await _settlePanel(tester);
    expect(find.byType(GridView), findsNothing);

    // Same convergence from the stamp leg.
    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();
    await _settlePanel(tester);
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(field().focusNode.hasFocus, isTrue);
    await _settlePanel(tester);
    expect(find.byType(GridView), findsNothing);
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
    await _settlePanel(tester);
    expect(find.byType(GridView), findsOneWidget);

    // Back collapses the transient panel; the route stays.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await _settlePanel(tester);
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

    // A panel replacing the keyboard takes its height at once and keeps it
    // as the IME leaves: keyboard → panel does not jump.
    double slot() =>
        tester.getSize(find.byType(CommentComposer)).height - idleHeight;
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    expect(tester.getSize(find.byType(GridView)).height, 300);
    await tester.pumpWidget(withInsets(0));
    expect(slot(), 300);

    // Back to the keyboard: once it has risen over the panel, the panel is
    // gone, without waiting out the hold.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pumpWidget(withInsets(300));
    await tester.pumpWidget(withInsets(0));
    expect(slot(), 0);
  });

  // One bottom budget: the navigation bar under a resting row, the
  // keyboard over it, and a panel at the keyboard's height, so the row
  // holds still as they swap — in a later composer too.
  testWidgets('panels stand exactly where the keyboard stood', (tester) async {
    final memory = _MapKeyboardHeights();
    Widget withInsets(double keyboard, {Key? key}) => composerApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            viewPadding: const EdgeInsets.only(bottom: 48),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Column(
              children: [
                const Expanded(child: SizedBox()),
                CommentComposer(
                  key: key,
                  onSend: (_) async {},
                  onStampSend: (_) async {},
                  keyboardHeights: memory,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    double row() => tester.getBottomLeft(find.byType(TextField)).dy;

    await tester.pumpWidget(withInsets(0));
    final resting = row();
    // Before any docked keyboard (a floating one's low inset is dropped):
    // the default panel, above the navigation bar.
    await tester.tap(find.byType(TextField));
    await tester.pumpWidget(withInsets(90));
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pumpWidget(withInsets(0));
    await _settlePanel(tester);
    expect(row(), resting - 280);
    await tester.tap(find.byTooltip('Emoji'));
    await _settlePanel(tester);
    expect(row(), resting);

    await tester.tap(find.byType(TextField));
    await tester.pumpWidget(withInsets(330));
    final typing = row();
    expect(typing, resting - 330 + 48);
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pumpWidget(withInsets(0));
    await _settlePanel(tester);
    expect(row(), typing);

    // A new composer opens its panel at the remembered height.
    await tester.pumpWidget(withInsets(0, key: UniqueKey()));
    await tester.tap(find.byTooltip('Stamp'));
    await _settlePanel(tester);
    expect(row(), typing);
  });

  // Some IMEs leave the navigation bar in viewInsets with nothing focused:
  // a keyboard down to the bar is down.
  testWidgets(
    'a composer on its surface goes with a keyboard down to the bar',
    (tester) async {
      var gone = 0;
      Widget withKeyboard(double inset) => composerApp(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewPadding: const EdgeInsets.only(bottom: 24),
              viewInsets: EdgeInsets.only(bottom: inset),
            ),
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              body: Align(
                alignment: Alignment.bottomCenter,
                child: CommentComposer(
                  onSend: (_) async {},
                  onStampSend: (_) async {},
                  onGone: () => gone++,
                ),
              ),
            ),
          ),
        ),
      );
      double shown() => tester
          .widget<Opacity>(
            find
                .descendant(
                  of: find.byType(CommentComposer),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;

      await tester.pumpWidget(withKeyboard(24));
      tester
          .state<CommentComposerState>(find.byType(CommentComposer))
          .open(CommentComposerInputState.keyboard);
      await tester.pump();
      await tester.pumpWidget(withKeyboard(300));
      expect(shown(), 1);
      await tester.pumpWidget(withKeyboard(24));
      expect(shown(), 0);
      // Down, out of focus, then gone: a frame each.
      await tester.pump();
      await tester.pump();
      expect(gone, 1);
    },
  );

  test('keyboard heights persist per screen shape', () async {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    first.read(keyboardHeightsProvider.notifier)
      ..record(const Size(400, 800), 300)
      // A floating keyboard's inset: no docked keyboard is this low.
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

  testWidgets('the panel rises on a spring and waits for the keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(composerApp(bareComposer()));
    final idleHeight = tester.getSize(find.byType(CommentComposer)).height;
    double slot() =>
        tester.getSize(find.byType(CommentComposer)).height - idleHeight;

    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(slot(), inExclusiveRange(0, 280));
    await _settlePanel(tester);
    expect(slot(), 280);

    // The field takes over: the input row stays up for the keyboard (none
    // comes here), then the panel folds away.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(slot(), 280);
    await _settlePanel(tester);
    expect(slot(), 0);

    // Reduced motion: the panel is there at once.
    await tester.pumpWidget(
      MotionScope(reduce: true, child: composerApp(bareComposer())),
    );
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pump();
    expect(slot(), 280);
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
    await _settlePanel(tester);
    expect(find.byType(GridView), findsOneWidget);

    // Toggling the active button rests the surface.
    await tester.tap(find.byTooltip('Stamp'));
    await tester.pump();
    expect(state().debugInputState, CommentComposerInputState.none);
    await _settlePanel(tester);
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
        overrides: _signedIn(repo),
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
        overrides: _signedIn(repo),
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
        overrides: _signedIn(FakeCommentRepository()),
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

  testWidgets('send success clears the reply target and the draft, with one '
      'success haptic', (tester) async {
    final haptics = recordHaptics();
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
    expect(haptics.roles, [HapticRole.success]);
  });

  testWidgets('a mid-flight retarget keeps the spinner and outlives the old '
      'send', (tester) async {
    final repo = FakeCommentRepository()
      ..rootComments = [
        sampleComment(11, replyCount: 1),
        sampleComment(12, userId: 21),
      ]
      ..addCompleter = Completer<CommentEntity>();
    await pumpCommentsPage(tester, repo);
    Finder inComposer(Finder finder) =>
        find.descendant(of: find.byType(CommentComposer), matching: finder);

    await tester.tap(_replyButton().first);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hi there');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();

    // While the first send is in flight the user re-targets comment 12.
    // The mutation key now maps to comment 12, which has no pending send:
    // `sending` reports false while `_busy` still covers the await, and
    // the spinner must persist through that window.
    await tester.tap(_replyButton().last);
    await tester.pump();
    expect(inComposer(find.textContaining('user 21')), findsOneWidget);
    expect(inComposer(find.byType(CircularProgressIndicator)), findsOneWidget);

    repo.addCompleter!.complete(sampleComment(20));
    await tester.pumpAndSettle();

    // The completed send must not clear the newer target.
    expect(inComposer(find.textContaining('user 21')), findsOneWidget);
    expect(inComposer(find.byType(CircularProgressIndicator)), findsNothing);
  });

  testWidgets(
    'replies send failure keeps the draft and target, flags permission, '
    'plays no haptic',
    (tester) async {
      final haptics = recordHaptics();
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
      await tester.pumpAndSettle();
      expect(haptics.played, isEmpty);
    },
  );

  testWidgets('send failure fires no haptic', (tester) async {
    final haptics = recordHaptics();
    await pumpCommentsPage(
      tester,
      FakeCommentRepository()..addError = StateError('offline'),
    );

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pumpAndSettle();
    expect(haptics.played, isEmpty);
  });
}

/// The composer's keyboard memory, held in a map.
class _MapKeyboardHeights implements KeyboardHeightMemory {
  final _heights = <Size, double>{};

  @override
  double? heightFor(Size size) => _heights[size];

  /// Drops what no docked keyboard has, as [KeyboardHeights] does.
  @override
  void record(Size size, double height) {
    if (height >= KeyboardHeights.minHeight) _heights[size] = height;
  }
}
