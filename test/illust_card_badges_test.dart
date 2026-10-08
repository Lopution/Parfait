import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

/// Minimal provider world for a bare [IllustCard]: the account + network
/// boundary overrides every network-backed provider needs, with a MockClient
/// that answers an empty envelope — no feed is being driven here.
Future<ProviderContainer> _makeWorld() async {
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
          client: MockClient((request) async => http.Response('{}', 200)),
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
    client: MockClient((request) async => http.Response('{}', 200)),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  return container;
}

Future<void> _pumpCard(
  WidgetTester tester,
  ProviderContainer container,
  IllustCard card, {
  ThemeData? theme,
  double textScale = 1,
  double width = 300,
}) async {
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: const [Locale('zh')],
          locale: const Locale('zh'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: width, child: card),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  });
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('a parent rebuild with the same inputs skips the card body', (
    tester,
  ) async {
    // Feed grids rebuild every built card on each feed state change; an
    // unchanged card must not re-run its whole subtree for that.
    final container = await _makeWorld();
    addTearDown(container.dispose);
    final entity = parseIllust(illustJson(6));
    Widget body() => tester.widget(
      find
          .descendant(
            of: find.byType(IllustCard),
            matching: find.byType(Column),
          )
          .first,
    );

    await _pumpCard(tester, container, IllustCard(entity: entity, rank: 1));
    final first = body();
    await _pumpCard(tester, container, IllustCard(entity: entity, rank: 1));
    expect(identical(body(), first), isTrue);

    // Any changed input builds the card again.
    await _pumpCard(tester, container, IllustCard(entity: entity, rank: 2));
    expect(identical(body(), first), isFalse);
    final ranked = body();
    await _pumpCard(
      tester,
      container,
      IllustCard(entity: parseIllust(illustJson(6)), rank: 2),
    );
    expect(identical(body(), ranked), isFalse);
  });
}
