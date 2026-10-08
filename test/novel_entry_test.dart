import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/widgets/entity_row.dart';
import 'package:parfait/app/widgets/novel_entry.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

NovelEntity _novel(
  int id, {
  String? coverUrl,
  List<NovelTag> tags = const [],
  String? seriesTitle,
  int totalBookmarks = 0,
}) => NovelEntity(
  id: id,
  title: 'novel $id',
  caption: '',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: tags,
  textLength: 4321,
  contentVersion: 'v$id',
  paragraphs: const [],
  coverImageUrl: coverUrl,
  seriesTitle: seriesTitle,
  totalBookmarks: totalBookmarks,
);

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: appLocalizationsDelegates,
  supportedLocales: const [Locale('zh')],
  locale: const Locale('zh'),
  home: Scaffold(body: child),
);

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('series, tags and the bookmark count join the identity', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        NovelEntry.regular(
          entity: _novel(
            6,
            seriesTitle: 'saga',
            totalBookmarks: 1234,
            tags: [for (var i = 1; i <= 6; i++) NovelTag(name: 't$i')],
          ),
        ),
      ),
    );
    expect(find.textContaining('saga · '), findsOneWidget);
    // Four tags at most on the footnote line.
    expect(find.text('#t1 #t2 #t3 #t4'), findsOneWidget);
    // The count sits on the cover, in the scrim badge.
    final badge = find.byType(EntityBadge);
    expect(
      find.descendant(of: find.byType(ClipRRect), matching: badge),
      findsOneWidget,
    );
    expect(
      tester.getBottomLeft(badge).dy,
      lessThanOrEqualTo(tester.getBottomLeft(find.byType(ClipRRect)).dy),
    );
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^novel 6, author, .+ 次收藏$')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('tap opens the novel route through the facade', (tester) async {
    // Same bootstrap as home_page_test: account overrides only, so the
    // real router and route facades drive navigation. Network-backed
    // providers fail fast inside the test host — this test only asserts
    // the facade wiring, not the destination page's content.
    final router = createPixivRouter(initialLocation: '/recommended');
    addTearDown(router.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: accountProviderOverrides(
            credentialStore: FakeCredentialStore(
              values: const {
                '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
              },
            ),
            metadataRepository: FakeAccountMetadataRepository(
              accounts: const [Account(id: '100', userId: 100, name: 't')],
              currentId: '100',
            ),
          ),
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: const [Locale('zh')],
            locale: const Locale('zh'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();

      // Host the entry on a plain pushed route — driving the shell's
      // recommended feed needs the full feed world; the contract under
      // test is "tap calls openNovel", not the feed.
      router.routerDelegate.navigatorKey.currentState!.push(
        PageRouteBuilder<void>(
          pageBuilder: (context, _, _) =>
              Scaffold(body: NovelEntry.compact(entity: _novel(77))),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NovelEntry), findsOneWidget);

      await tester.tap(find.byType(NovelEntry));
      await tester.pump();
      expect(router.state.uri.path, '/recommended/novel/77');
    });
  });
}
