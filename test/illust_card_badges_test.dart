import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
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
  await seedAccounts(const [testerAccount], currentId: testerAccount.id);
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer.test(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
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

void main() {
  testWidgets('the pager image flies back only to a card on screen', (
    tester,
  ) async {
    final container = await _makeWorld();
    final source = IllustPagerSource();
    // 400dp slots on a 600dp screen: card 3 is built in the cache extent
    // but off screen.
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
