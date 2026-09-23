import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/app/widgets/novel_entry.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/novel/novel_entity.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

NovelEntity _novel(int id, {String? coverUrl}) => NovelEntity(
  id: id,
  title: 'novel $id',
  caption: '',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: 4321,
  contentVersion: 'v$id',
  paragraphs: const [],
  coverImageUrl: coverUrl,
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

  testWidgets('compact and regular render the shared identity line', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            NovelEntry.compact(entity: _novel(1)),
            NovelEntry.regular(entity: _novel(2)),
          ],
        ),
      ),
    );
    expect(find.text('novel 1'), findsOneWidget);
    expect(find.text('novel 2'), findsOneWidget);
    // Both densities carry the author subtitle and the word-count meta.
    expect(find.text('author'), findsNWidgets(2));
    expect(find.textContaining('4321'), findsNWidgets(2));
  });

  testWidgets('work id lands in the default key', (tester) async {
    await tester.pumpWidget(_host(NovelEntry.compact(entity: _novel(42))));
    expect(find.byKey(const ValueKey('novel-42')), findsOneWidget);
  });

  testWidgets('ranking variant shows the rank badge on the cover', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(NovelEntry.ranking(entity: _novel(3), rank: 3)),
    );
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('missing cover keeps the clipped placeholder', (tester) async {
    await tester.pumpWidget(_host(NovelEntry.regular(entity: _novel(5))));
    // The placeholder sits inside the same ClipRRect as a real cover —
    // the old NovelRow painted it with square corners.
    final clip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byType(NovelEntry),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clip.borderRadius, BorderRadius.circular(6));
    expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);
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
