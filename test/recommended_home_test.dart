import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/features/home/recommended/recommended_home_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/illust_fixtures.dart';

class _FakeCredentialStore implements CredentialStore {
  final _secrets = <String, Credential>{};

  void seed(String accountId, Credential credential) =>
      _secrets[accountId] = credential;

  @override
  Future<Credential?> read(String accountId) async => _secrets[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async =>
      _secrets[accountId] = credential;

  @override
  Future<void> delete(String accountId) async => _secrets.remove(accountId);
}

class _FakeMetadataRepository implements AccountMetadataRepository {
  @override
  Future<AccountMetadataSnapshot> load() async => const AccountMetadataSnapshot(
    accounts: [Account(id: '100', userId: 100, name: 'tester')],
    currentId: '100',
  );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

String _novelJson(int id) => jsonEncode({
  'id': id,
  'title': 'novel $id',
  'caption': '',
  'user': {
    'id': 99,
    'name': 'author',
    'account': 'author',
    'profile_image_urls': {'medium': 'https://i.pximg.net/u.png'},
  },
  'tags': [],
  'text_length': 100,
  'create_date': '2026-08-01T10:00:00+09:00',
  'image_urls': {'medium': 'https://i.pximg.net/n$id.png'},
});

class _ApiFixture {
  _ApiFixture();

  final requests = <String>[];

  http.Client build() {
    return MockClient((request) async {
      if (request.url.host != 'app-api.pixiv.net') {
        return http.Response('unknown host', 500);
      }
      final path = request.url.path;
      requests.add('$path?${request.url.query}');
      if (path == '/v1/illust/recommended') {
        return http.Response(
          jsonEncode({
            'illusts': [
              for (var i = 1; i <= 5; i++) illustJson(i),
            ],
            'next_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/v1/novel/recommended') {
        return http.Response(
          jsonEncode({
            'novels': [
              for (var i = 1; i <= 3; i++)
                jsonDecode(_novelJson(i)) as Map<String, dynamic>,
            ],
            'next_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path == '/v1/user/recommended') {
        return http.Response(
          jsonEncode({
            'user_previews': [
              for (var i = 1; i <= 3; i++)
                {
                  'user': {
                    'id': i,
                    'name': 'user $i',
                    'account': 'user$i',
                    'profile_image_urls': {
                      'medium': 'https://i.pximg.net/u$i.png'
                    },
                  },
                  'illusts': [],
                  'novels': [],
                },
            ],
            'next_url': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });
  }
}

Future<(ProviderContainer, _ApiFixture)> _makeWorld() async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final fixture = _ApiFixture();
  final credentials = _FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        _FakeMetadataRepository(),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen');
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
  final client = PixivHttpClient(
    client: fixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return (container, fixture);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('home shows four type chips and defaults to illust',
      (tester) async {
    final (container, _) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: RecommendedHomePage()),
        ),
      );
      await tester.pump();
      await tester.pump();
    });
    // Locale-independent: four tabs regardless of language.
    expect(find.byType(Tab), findsNWidgets(4));
    // Unified chrome: the TabBar lives inside an AppBar (same as
    // Ranking/New/Search) — a bare TabBar pinned under the status bar was
    // the old divergent style.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(TabBar),
      ),
      findsOneWidget,
    );
    // Illust cards render (titles from the store).
    expect(find.textContaining('illust '), findsWidgets);
  });

  testWidgets('switching to manga requests content_type=manga',
      (tester) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: RecommendedHomePage()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byType(Tab).at(1));
      await tester.pump();
      await tester.pump();
    });
    expect(
      fixture.requests,
      contains('/v1/illust/recommended?content_type=manga&include_ranking_illusts=true&filter=for_ios'),
    );
  });

  testWidgets('novel chip loads novel recommended and renders titles',
      (tester) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: RecommendedHomePage()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byType(Tab).at(2));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
    });
    expect(
      fixture.requests,
      contains('/v1/novel/recommended?filter=for_android'),
    );
    expect(find.textContaining('novel '), findsWidgets);
  });

  testWidgets('user chip loads user recommended and renders accounts',
      (tester) async {
    final (container, fixture) = await _makeWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: RecommendedHomePage()),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byType(Tab).at(3));
      await tester.pump();
      await tester.pump();
    });
    expect(
      fixture.requests,
      contains('/v1/user/recommended?filter=for_ios'),
    );
    expect(find.text('user 1'), findsOneWidget);
  });
}
