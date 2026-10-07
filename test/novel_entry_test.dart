import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/motion/press_scale.dart';
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

  testWidgets('variants pin their contracted cover size and radius', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            NovelEntry.compact(entity: _novel(1)),
            NovelEntry.regular(entity: _novel(2)),
            NovelEntry.ranking(entity: _novel(3), rank: 3),
          ],
        ),
      ),
    );

    ({Size size, BorderRadius radius}) coverOf(String key) {
      final clip = tester.widget<ClipRRect>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(ClipRRect),
        ),
      );
      // The cover box is the ClipRRect's direct child — deeper SizedBoxes
      // (e.g. the placeholder Icon's own) must not leak into the lookup.
      final box = clip.child! as SizedBox;
      return (
        size: Size(box.width!, box.height!),
        radius: clip.borderRadius as BorderRadius,
      );
    }

    // compact & ranking share the 56×72 r4 cover; regular is 68×88 r6 —
    // the density contract is the only difference between variants.
    expect(coverOf('novel-1').size, const Size(56, 72));
    expect(coverOf('novel-1').radius, BorderRadius.circular(4));
    expect(coverOf('novel-2').size, const Size(68, 88));
    expect(coverOf('novel-2').radius, BorderRadius.circular(6));
    expect(coverOf('novel-3').size, const Size(56, 72));
    expect(coverOf('novel-3').radius, BorderRadius.circular(4));
  });

  testWidgets('a full-bleed row: no card, ink only, no press scale', (
    tester,
  ) async {
    await tester.pumpWidget(_host(NovelEntry.regular(entity: _novel(1))));
    final entry = find.byType(NovelEntry);
    expect(
      find.descendant(of: entry, matching: find.byType(Card)),
      findsNothing,
    );
    expect(
      find.descendant(of: entry, matching: find.byType(PressScale)),
      findsNothing,
    );
    expect(
      find.descendant(of: entry, matching: find.byType(InkWell)),
      findsOneWidget,
    );
    // Edge to edge: the row spans the whole list width.
    expect(tester.getSize(find.byType(EntityRow)).width, 800);
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

  testWidgets('no bookmarks, tags or series leaves those lines out', (
    tester,
  ) async {
    await tester.pumpWidget(_host(NovelEntry.regular(entity: _novel(7))));
    expect(find.byType(EntityBadge), findsNothing);
    expect(find.textContaining('#'), findsNothing);
    expect(find.textContaining(' · '), findsNothing);
  });

  testWidgets('work id lands in the default key', (tester) async {
    await tester.pumpWidget(_host(NovelEntry.compact(entity: _novel(42))));
    expect(find.byKey(const ValueKey('novel-42')), findsOneWidget);
  });

  testWidgets('ranking variant leads the title line with the rank', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(NovelEntry.ranking(entity: _novel(3), rank: 3)),
    );
    final rank = find.byType(EntityRankLabel);
    expect(rank, findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // Beside the title on one baseline, not pinned over the cover.
    expect(find.byType(EntityBadge), findsNothing);
    expect(
      tester.getBottomLeft(find.text('3')).dy,
      moreOrLessEquals(
        tester.getBottomLeft(find.text('novel 3')).dy,
        epsilon: 2,
      ),
    );
    expect(
      tester.getTopRight(find.text('3')).dx,
      lessThan(tester.getTopLeft(find.text('novel 3')).dx),
    );
    expect(
      tester.getTopLeft(find.text('3')).dx,
      greaterThan(tester.getTopRight(find.byType(ClipRRect)).dx),
    );
    // The row reads the position first.
    expect(find.bySemanticsLabel('第 3 名, novel 3, author'), findsOneWidget);
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
