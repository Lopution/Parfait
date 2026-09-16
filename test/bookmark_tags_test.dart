import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_repository.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _RecordedRequest {
  _RecordedRequest(this.method, this.uri, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> body;
}

typedef World = (ProviderContainer, List<_RecordedRequest>);

Future<World> _makeWorld(Map<String, Object> responses) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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
      return http.Response(
        jsonEncode(response),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode({'message': '', 'is_success': true}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in this test');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
    ],
  );
  clientRef[0] = PixivHttpClient(
    client: mock,
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return (container, requests);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

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

  test('add without tags omits tags[]', () async {
    final (container, requests) = await _makeWorld({});
    final repository = container.read(bookmarkRepositoryProvider);

    await repository.addNovel(7, BookmarkRestrict.public, tags: const []);

    expect(requests.single.uri.path, '/v2/novel/bookmark/add');
    expect(requests.single.body.containsKey('tags[]'), isFalse);
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
}
