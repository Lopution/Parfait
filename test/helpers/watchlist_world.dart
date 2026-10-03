import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/actionqueue/action_bootstrap.dart';
import 'package:parfait/core/actionqueue/action_store.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fake_account.dart';
import 'test_preferences.dart';

/// The watchlist endpoints over a MockClient: GETs serve [mangaSeries] or
/// [novelSeries], writes answer [mutationStatus].
class WatchlistFixture {
  final requests = <http.Request>[];
  List<Map<String, Object?>> mangaSeries = const [];
  List<Map<String, Object?>> novelSeries = const [];
  int mutationStatus = 200;

  http.Client build() => MockClient((request) async {
    requests.add(request);
    if (request.method == 'GET') {
      final isNovel = request.url.path.contains('/novel');
      return http.Response(
        jsonEncode({
          'series': isNovel ? novelSeries : mangaSeries,
          'next_url': null,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (mutationStatus != 200) {
      return http.Response(
        jsonEncode({
          'error': {'message': 'rejected'},
        }),
        mutationStatus,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode({'is_success': true}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

Future<(ProviderContainer, WatchlistFixture)> makeWatchlistWorld({
  WatchlistFixture? fixture,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final resolvedFixture = fixture ?? WatchlistFixture();
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
            fail('refresh should not happen in watchlist page tests');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
      actionStoreProvider.overrideWithValue(InMemoryActionStore()),
    ],
  );
  final client = PixivHttpClient(
    client: resolvedFixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return (container, resolvedFixture);
}
