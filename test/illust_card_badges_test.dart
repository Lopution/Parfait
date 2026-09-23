import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/app/pixiv_image.dart';
import 'package:pixiv_func/app/widgets/entity_row.dart';
import 'package:pixiv_func/app/widgets/feed/illust_card.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
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
  IllustCard card,
) async {
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: const [Locale('zh')],
          locale: const Locale('zh'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 300, child: card),
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

  testWidgets('every corner badge uses the shared EntityBadge container', (
    tester,
  ) async {
    final container = await _makeWorld();
    addTearDown(container.dispose);
    await _pumpCard(
      tester,
      container,
      IllustCard(
        entity: parseIllust(
          illustJson(1, xRestrict: 1, aiType: 2, pageCount: 3),
        ),
      ),
    );

    // R-18 + pageCount + AI = three badges; each is the shared container —
    // the same radius and padding, only the semantic fill differs.
    final badges = find
        .descendant(
          of: find.byType(IllustCard),
          matching: find.byType(EntityBadge),
        )
        .evaluate()
        .toList();
    expect(badges, hasLength(3));
    for (final badge in badges) {
      final containerWidget = tester.widget<Container>(
        find.descendant(
          of: find.byWidget(badge.widget),
          matching: find.byType(Container),
        ),
      );
      expect(
        (containerWidget.decoration as BoxDecoration).borderRadius,
        BorderRadius.circular(5),
      );
      expect(
        containerWidget.padding,
        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      );
    }
    expect(find.text('R-18'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // page count
    expect(find.text('AI'), findsOneWidget);
  });

  testWidgets('rank badge stacks above R-18 in the top-left cluster', (
    tester,
  ) async {
    final container = await _makeWorld();
    addTearDown(container.dispose);
    await _pumpCard(
      tester,
      container,
      IllustCard(entity: parseIllust(illustJson(2, xRestrict: 1)), rank: 7),
    );
    expect(find.text('7'), findsOneWidget);
    expect(find.text('R-18'), findsOneWidget);
    // Both pills share the primary semantic fill, staggered vertically:
    // the rank sits directly above R-18 on the same left edge (PRD R2).
    final rankBadge = find.ancestor(
      of: find.text('7'),
      matching: find.byType(EntityBadge),
    );
    final r18Badge = find.ancestor(
      of: find.text('R-18'),
      matching: find.byType(EntityBadge),
    );
    expect(
      tester.widget<EntityBadge>(rankBadge).color,
      Theme.of(tester.element(find.byType(IllustCard))).colorScheme.primary,
    );
    final rankTopLeft = tester.getTopLeft(rankBadge);
    final r18TopLeft = tester.getTopLeft(r18Badge);
    expect(rankTopLeft.dx, r18TopLeft.dx);
    expect(rankTopLeft.dy, lessThan(r18TopLeft.dy));
  });

  testWidgets('meta slot renders a line under the author', (tester) async {
    final container = await _makeWorld();
    addTearDown(container.dispose);
    await _pumpCard(
      tester,
      container,
      IllustCard(
        entity: parseIllust(illustJson(3)),
        meta: const EntityMetaText('2026-09-01'),
      ),
    );
    expect(find.text('2026-09-01'), findsOneWidget);
  });

  testWidgets('fitWidth contract holds: preview follows the aspect ratio', (
    tester,
  ) async {
    final container = await _makeWorld();
    addTearDown(container.dispose);
    await _pumpCard(
      tester,
      container,
      IllustCard(entity: parseIllust(illustJson(4, width: 800, height: 1200))),
    );
    final image = tester.widget<PixivImage>(find.byType(PixivImage).first);
    expect(image.fit, BoxFit.fitWidth);
    // 300-wide column, 800×1200 work → 450-tall preview, never cropped.
    final size = tester.getSize(find.byType(PixivImage).first);
    expect(size.height, 450);
  });
}
