import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';

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
  final container = ProviderContainer.test(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository.signedIn(
          const Account(id: '100', userId: 100, name: 'tester'),
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
      localizedApp(
        container: container,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        theme: theme,
        body: SingleChildScrollView(
          child: SizedBox(width: width, child: card),
        ),
      ),
    );
    await tester.pump();
  });
}

void main() {
  testWidgets('a parent rebuild with the same inputs skips the card body', (
    tester,
  ) async {
    // Feed grids rebuild every built card on each feed state change; an
    // unchanged card must not re-run its whole subtree for that.
    final container = await _makeWorld();
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

  testWidgets('the pager image flies back only to a card on screen', (
    tester,
  ) async {
    final container = await _makeWorld();
    final source = IllustPagerSource();
    // 400dp slots on a 600dp screen: card 3 is built in the cache extent
    // but off screen.
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        localizedApp(
          container: container,
          body: IllustPagerScope(
            source: source,
            child: ListView(
              children: [
                for (final id in [1, 2, 3])
                  SizedBox(
                    height: 400,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 150,
                        child: IllustCard(entity: parseIllust(illustJson(id))),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    });
    bool flies(int id) => tester
        .widget<HeroMode>(
          find
              .ancestor(
                of: find.byWidgetPredicate(
                  (w) => w is Hero && w.tag == illustHeroTag('feed', id),
                  skipOffstage: false,
                ),
                matching: find.byType(HeroMode, skipOffstage: false),
              )
              .first,
        )
        .enabled;

    for (final (id, onScreen) in [(1, true), (3, false), (2, true)]) {
      source.aimHomeFlight(id);
      await tester.pump();
      expect(flies(id), onScreen, reason: 'card $id');
    }
    // Closing the pager lets every card fly again.
    source
      ..aimHomeFlight(3)
      ..clearHomeFlight();
    await tester.pump();
    expect(flies(3), isTrue);
  });
}
