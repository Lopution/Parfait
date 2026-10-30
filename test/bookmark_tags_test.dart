import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_repository.dart';
import 'package:parfait/core/bookmark/bookmark_tags_controller.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/features/bookmark/bookmark_tags_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/bookmark_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/profile_world.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/profile/profile_feed_controller.dart';
import 'package:parfait/core/profile/profile_models.dart';
import 'package:parfait/features/profile/bookmark_tag_feed_page.dart';
import 'package:parfait/features/profile/profile_illust_feed.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/localized_app.dart';

/// Two bookmarked works with tags, for the bookmark tag feed.
UserApi _users() => UserApi(
  bookmarks: [
    _illust(1, 'Blue Sky', [
      {'name': '空', 'translated_name': 'blue'},
    ]),
    _illust(2, 'Sakura', [
      {'name': '花'},
    ]),
  ],
);

Map<String, dynamic> _illust(
  int id,
  String title,
  List<Map<String, dynamic>> tags,
) => {...illustJson(id, bookmarked: true), 'title': title, 'tags': tags};

Future<ProviderContainer> _makeContainer(UserApi users) => signedInApiContainer(
  PixivApi({...backgroundRoutes, ...users.routes}).client,
  overrides: [
    feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
    illustStoreProvider.overrideWithValue(IllustStore()),
  ],
);

Widget _testApp(ProviderContainer container, Widget home) =>
    localizedApp(container: container, home: home);

class _RecordedRequest {
  _RecordedRequest(this.method, this.uri, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> body;
}

typedef World = (ProviderContainer, List<_RecordedRequest>);

Future<World> _makeWorld(Map<String, Object> responses) async {
  final requests = <_RecordedRequest>[];
  final mock = MockClient((request) async {
    requests.add(
      _RecordedRequest(
        request.method,
        request.url,
        request.method == 'POST'
            ? Uri.splitQueryString(request.body)
            : const {},
      ),
    );
    final key = '${request.method} ${request.url.path}';
    final response = responses[key];
    if (response is int) {
      return http.Response('', response);
    }
    if (response is Map<String, dynamic>) {
      return jsonResponse(response);
    }
    return jsonResponse({'message': '', 'is_success': true});
  });
  final container = await signedInApiContainer(mock);
  return (container, requests);
}

void main() {
  test('add with tags space-joins into a single tags[] field', () async {
    final (container, requests) = await _makeWorld({});
    final repository = container.read(bookmarkRepositoryProvider);

    await repository.addIllust(
      42,
      BookmarkRestrict.private,
      tags: const ['illustration', 'オリジナル'],
    );

    expect(requests.single.uri.path, '/v2/illust/bookmark/add');
    expect(requests.single.body['illust_id'], '42');
    expect(requests.single.body['restrict'], 'private');
    expect(requests.single.body['tags[]'], 'illustration オリジナル');
  });

  test('fetchDetail parses illust bookmark_detail payload', () async {
    final (container, requests) = await _makeWorld({
      'GET /v2/illust/bookmark/detail': {
        'bookmark_detail': {
          'is_bookmarked': true,
          'restrict': 'private',
          'tags': [
            {'name': 'procreate', 'is_registered': true},
            {'name': 'らくがき', 'is_registered': false},
          ],
        },
      },
    });
    final repository = container.read(bookmarkRepositoryProvider);

    final detail = await repository.fetchDetail(
      const BookmarkKey(BookmarkEntityType.illust, 42),
    );

    expect(requests.single.uri.queryParameters['illust_id'], '42');
    expect(detail.isBookmarked, isTrue);
    expect(detail.restrict, BookmarkRestrict.private);
    expect(detail.tagNames, ['procreate', 'らくがき']);
    expect(detail.tags.first.isRegistered, isTrue);
    expect(detail.tags.last.isRegistered, isFalse);
  });

  test('fetchDetail dispatches the novel endpoint', () async {
    final (container, requests) = await _makeWorld({
      'GET /v2/novel/bookmark/detail': {
        'bookmark_detail': {
          'is_bookmarked': false,
          'restrict': 'public',
          'tags': <dynamic>[],
        },
      },
    });
    final repository = container.read(bookmarkRepositoryProvider);

    final detail = await repository.fetchDetail(
      const BookmarkKey(BookmarkEntityType.novel, 77),
    );

    expect(requests.single.uri.path, '/v2/novel/bookmark/detail');
    expect(requests.single.uri.queryParameters['novel_id'], '77');
    expect(detail.isBookmarked, isFalse);
    expect(detail.restrict, BookmarkRestrict.public);
    expect(detail.tags, isEmpty);
  });

  test('fetchUserTags pages with pinned identity parameters', () async {
    final (container, requests) = await _makeWorld({
      'GET /v1/user/bookmark-tags/illust': {
        'bookmark_tags': [
          {'name': 'procreate', 'count': 3},
          {'name': 'らくがき', 'count': 1},
        ],
        'next_url':
            'https://app-api.pixiv.net/v1/user/bookmark-tags/illust'
            '?user_id=100&restrict=private&offset=30',
      },
    });
    final repository = container.read(bookmarkRepositoryProvider);

    final page = await repository.fetchUserTags(
      100,
      entityType: BookmarkEntityType.illust,
      restrict: BookmarkRestrict.private,
    );

    expect(requests.single.uri.path, '/v1/user/bookmark-tags/illust');
    expect(requests.single.uri.queryParameters['user_id'], '100');
    expect(requests.single.uri.queryParameters['restrict'], 'private');
    expect(page.tags, [
      const UserBookmarkTag(name: 'procreate', count: 3),
      const UserBookmarkTag(name: 'らくがき', count: 1),
    ]);
    expect(page.nextUrl, isNotNull);
    expect(
      repository.validateUserTagsCursor(
        100,
        entityType: BookmarkEntityType.illust,
        restrict: BookmarkRestrict.private,
        cursor: page.nextUrl!,
      ),
      isTrue,
    );
  });

  test('validateUserTagsCursor rejects a mismatched restrict', () async {
    final (container, _) = await _makeWorld({});
    final repository = container.read(bookmarkRepositoryProvider);

    expect(
      repository.validateUserTagsCursor(
        100,
        entityType: BookmarkEntityType.illust,
        restrict: BookmarkRestrict.public,
        cursor:
            'https://app-api.pixiv.net/v1/user/bookmark-tags/illust'
            '?user_id=100&restrict=private&offset=30',
      ),
      isFalse,
    );
  });

  test('fetchUserTags rejects a malformed payload', () async {
    final (container, _) = await _makeWorld({
      'GET /v1/user/bookmark-tags/novel': {'bookmark_tags': 'nope'},
    });
    final repository = container.read(bookmarkRepositoryProvider);

    await expectLater(
      repository.fetchUserTags(
        100,
        entityType: BookmarkEntityType.novel,
        restrict: BookmarkRestrict.public,
      ),
      throwsA(isA<ApiError>()),
    );
  });

  test('fetchBookmarks carries the tag parameter onto the wire', () async {
    final (container, requests) = await _makeWorld({
      'GET /v1/user/bookmarks/illust': {
        'illusts': <dynamic>[],
        'next_url': null,
      },
    });
    final repository = container.read(userRepositoryProvider);

    await repository.fetchBookmarks(
      100,
      restrict: UserRestrict.private,
      tag: 'procreate',
    );

    final query = requests.single.uri.queryParameters;
    expect(requests.single.uri.path, '/v1/user/bookmarks/illust');
    expect(query['tag'], 'procreate');
    expect(query['restrict'], 'private');
  });

  test('validateBookmarksCursor pins the tag alongside restrict', () async {
    final (container, _) = await _makeWorld({});
    final repository = container.read(userRepositoryProvider);

    expect(
      repository.validateBookmarksCursor(
        100,
        restrict: UserRestrict.private,
        tag: 'procreate',
        cursor:
            'https://app-api.pixiv.net/v1/user/bookmarks/illust'
            '?user_id=100&restrict=private&tag=procreate&offset=30',
      ),
      isTrue,
    );
    expect(
      repository.validateBookmarksCursor(
        100,
        restrict: UserRestrict.private,
        tag: 'procreate',
        cursor:
            'https://app-api.pixiv.net/v1/user/bookmarks/illust'
            '?user_id=100&restrict=private&tag=other&offset=30',
      ),
      isFalse,
      reason: 'a cursor from a different tag must not resume this feed',
    );
    expect(
      repository.validateBookmarksCursor(
        100,
        restrict: UserRestrict.private,
        cursor:
            'https://app-api.pixiv.net/v1/user/bookmarks/illust'
            '?user_id=100&restrict=private&offset=30',
      ),
      isTrue,
      reason: 'untagged feeds keep accepting untagged cursors',
    );
  });

  test('userBookmarkTagsProvider pages via next_url', () async {
    final page = <String, dynamic>{
      'bookmark_tags': [
        {'name': 'a', 'count': 1},
      ],
      'next_url':
          'https://app-api.pixiv.net/v1/user/bookmark-tags/illust'
          '?user_id=100&restrict=public&offset=30',
    };
    final (container, requests) = await _makeWorld({
      'GET /v1/user/bookmark-tags/illust': page,
    });
    const query = (BookmarkEntityType.illust, BookmarkRestrict.public);

    final first = await container.read(userBookmarkTagsProvider(query).future);
    expect(first.tags.single.name, 'a');
    expect(first.hasMore, isTrue);

    // Second call serves the cursor URL — the mock keys on method+path, so a
    // paged response arrives through the same route.
    await container.read(userBookmarkTagsProvider(query).notifier).loadMore();
    final state = container.read(userBookmarkTagsProvider(query)).value!;
    expect(state.tags, hasLength(2));
    expect(requests, hasLength(2));
    expect(requests.last.uri.queryParameters['offset'], '30');

    // That page was the last: no further page is asked for.
    page['next_url'] = null;
    await container.read(userBookmarkTagsProvider(query).notifier).loadMore();
    await container.read(userBookmarkTagsProvider(query).notifier).loadMore();
    expect(
      container.read(userBookmarkTagsProvider(query)).value!.hasMore,
      isFalse,
    );
    expect(requests, hasLength(3));
  });

  testWidgets('BookmarkTagsPage lists each visibility in its own tab', (
    tester,
  ) async {
    final repository = BookmarkApi()..tagPage = _procreate;
    final container = await bookmarkWorld(repository);
    await tester.pumpWidget(
      localizedApp(container: container, home: BookmarkTagsPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('收藏标签'), findsOneWidget);
    expect(find.text('procreate'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(repository.tagRequests, ['tags:100:public']);

    repository.tagPage = const UserBookmarkTagPage(
      tags: [UserBookmarkTag(name: 'hidden', count: 2)],
      nextUrl: null,
    );
    expect(find.widgetWithText(Tab, '公开'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '私密'));
    await tester.pumpAndSettle();

    expect(find.text('hidden'), findsOneWidget);
    expect(find.text('procreate'), findsNothing);
    expect(repository.tagRequests.last, 'tags:100:private');
    expect(find.text('已显示全部标签'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // A swipe back returns to the public list without refetching it.
    await tester.fling(find.text('hidden'), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('procreate'), findsOneWidget);
    expect(repository.tagRequests, ['tags:100:public', 'tags:100:private']);
  });

  testWidgets('BookmarkTagsPage retries a failed load-more request', (
    tester,
  ) async {
    final repository = BookmarkApi()
      ..tagPage = UserBookmarkTagPage(
        tags: _procreate.tags,
        nextUrl:
            'https://app-api.pixiv.net/v1/user/bookmark-tags/illust'
            '?user_id=100&restrict=public&offset=30',
      )
      ..tagsNextFailure = failing(500);
    final container = await bookmarkWorld(repository);
    const query = (BookmarkEntityType.illust, BookmarkRestrict.public);

    await container.read(userBookmarkTagsProvider(query).future);

    // One tag leaves the list short: the page asks for the next at once.
    await tester.pumpWidget(
      localizedApp(container: container, home: BookmarkTagsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载更多失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(repository.tagRequests, ['tags:100:public', 'tags:100:public:next']);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(repository.tagRequests, [
      'tags:100:public',
      'tags:100:public:next',
      'tags:100:public:next',
    ]);
  });

  group('bookmark tag feed page', () {
    testWidgets('bookmark tag feed labels range and isolates hero scope', (
      tester,
    ) async {
      final repository = _users();
      final container = await _makeContainer(repository);

      await tester.pumpWidget(
        _testApp(
          container,
          const BookmarkTagFeedPage(
            tag: 'draw',
            restrict: BookmarkRestrict.private,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('draw'), findsOneWidget);
      expect(find.text('私密'), findsOneWidget);
      expect(repository.requests, ['bookmarks:100:private:draw']);
      final taggedScope = tester
          .widget<IllustCard>(find.byType(IllustCard).first)
          .heroScope;
      expect(taggedScope, endsWith(':draw'));

      await tester.pumpWidget(
        _testApp(
          container,
          const ProfileIllustFeed(
            feedKey: ProfileFeedKey(
              userId: 100,
              kind: ProfileFeedKind.bookmarks,
              restrict: UserRestrict.private,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final untaggedScope = tester
          .widget<IllustCard>(find.byType(IllustCard).first)
          .heroScope;
      expect(untaggedScope, endsWith(':'));
      expect(untaggedScope, isNot(taggedScope));
    });

    testWidgets('bookmark tag filter only changes loaded works locally', (
      tester,
    ) async {
      final repository = _users();
      final container = await _makeContainer(repository);

      await tester.pumpWidget(
        _testApp(
          container,
          const BookmarkTagFeedPage(
            tag: 'draw',
            restrict: BookmarkRestrict.private,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final filter = find.byType(TextField);
      await tester.enterText(filter, 'BLUE');
      await tester.pump();
      expect(find.text('Blue Sky'), findsOneWidget);
      expect(find.text('Sakura'), findsNothing);
      expect(repository.requests, hasLength(1));

      await tester.enterText(filter, 'no matching work');
      await tester.pump();
      expect(find.text('已加载内容中无匹配'), findsOneWidget);
      expect(repository.requests, hasLength(1));

      await tester.enterText(filter, '');
      await tester.pump();
      expect(find.text('Blue Sky'), findsOneWidget);
      expect(find.text('Sakura'), findsOneWidget);
      expect(repository.requests, hasLength(1));
    });

    test(
      'the untagged list and a tag spelled null keep apart snapshots',
      () async {
        final container = await _makeContainer(_users());
        String snapshotKey(String? tag) => container
            .read(
              profileIllustFeedProvider(
                ProfileFeedKey(
                  userId: 100,
                  kind: ProfileFeedKind.bookmarks,
                  bookmarkTag: tag,
                ),
              ).notifier,
            )
            .feedKey;

        expect(snapshotKey(null), isNot(snapshotKey('null')));
      },
    );
  });
}

const _procreate = UserBookmarkTagPage(
  tags: [UserBookmarkTag(name: 'procreate', count: 5)],
  nextUrl: null,
);
