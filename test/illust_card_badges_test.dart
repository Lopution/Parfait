import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/entity_row.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/func_tokens.dart';
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

  group('corner badges', () {
    final entity = parseIllust(
      illustJson(1, type: 'ugoira', xRestrict: 1, aiType: 2, pageCount: 3),
    );

    Finder badgeWith(Finder content) =>
        find.ancestor(of: content, matching: find.byType(EntityBadge));

    BoxDecoration fillOf(WidgetTester tester, Finder badge) =>
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: badge,
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;

    for (final brightness in Brightness.values) {
      testWidgets('one scrim, shape and size in the ${brightness.name} theme', (
        tester,
      ) async {
        final container = await _makeWorld();
        addTearDown(container.dispose);
        await _pumpCard(
          tester,
          container,
          IllustCard(entity: entity),
          theme: replicaTheme(brightness),
        );

        final badges = find.descendant(
          of: find.byType(IllustCard),
          matching: find.byType(EntityBadge),
        );
        expect(badges, findsNWidgets(4));
        for (var i = 0; i < 4; i++) {
          final fill = fillOf(tester, badges.at(i));
          // The scrim ignores the theme and never takes a semantic color:
          // AI is no longer painted as an error.
          expect(fill.color, FuncTokens.imageControl);
          expect(fill.borderRadius, FuncShape.badge);
          expect(tester.getSize(badges.at(i)).height, EntityBadge.height);
        }

        // Each marker keeps its corner, 7dp inside the image.
        final image = tester.getRect(find.byType(PixivImage));
        final r18 = tester.getRect(badgeWith(find.text('R-18')));
        final pages = tester.getRect(badgeWith(find.text('3')));
        final ugoira = tester.getRect(
          badgeWith(find.byIcon(Icons.gif_box_outlined)),
        );
        final ai = tester.getRect(badgeWith(find.text('AI')));
        expect(r18.topLeft - image.topLeft, const Offset(7, 7));
        expect(image.topRight - pages.topRight, const Offset(7, -7));
        expect(ugoira.bottomLeft - image.bottomLeft, const Offset(7, -7));
        expect(image.bottomRight - ai.bottomRight, const Offset(7, 7));
      });
    }

    testWidgets('icons and spoken labels', (tester) async {
      final container = await _makeWorld();
      addTearDown(container.dispose);
      await _pumpCard(tester, container, IllustCard(entity: entity));

      // The page count leads with an icon.
      expect(
        find.descendant(
          of: badgeWith(find.text('3')),
          matching: find.byIcon(Icons.photo_library_outlined),
        ),
        findsOneWidget,
      );
      // Each badge speaks a full word inside the card's merged label; the
      // icon-only ugoira badge would otherwise be silent.
      final label = tester
          .getSemantics(find.byType(PixivImage))
          .getSemanticsData()
          .label;
      expect(label.split('\n'), [
        'illust 1, author',
        'R-18',
        '动图',
        '共 3 页',
        'AI 生成',
      ]);
    });
  });

  testWidgets('the rank leads the title line, not the image', (tester) async {
    final container = await _makeWorld();
    addTearDown(container.dispose);
    await _pumpCard(
      tester,
      container,
      IllustCard(entity: parseIllust(illustJson(2, xRestrict: 1)), rank: 7),
    );

    expect(find.byType(EntityRankLabel), findsOneWidget);
    expect(
      find.ancestor(of: find.text('7'), matching: find.byType(EntityBadge)),
      findsNothing,
    );
    // Below the image, on the title's baseline, ahead of the title.
    final image = tester.getRect(find.byType(PixivImage));
    final rank = tester.getRect(find.text('7'));
    final title = tester.getRect(find.text('illust 2'));
    expect(rank.top, greaterThanOrEqualTo(image.bottom));
    expect(rank.right, lessThan(title.left));
    expect(rank.bottom, moreOrLessEquals(title.bottom, epsilon: 2));
    expect(find.bySemanticsLabel('第 7 名, illust 2'), findsOneWidget);
  });

  testWidgets('the loading placeholder reads the container surface tier', (
    tester,
  ) async {
    final container = await _makeWorld();
    addTearDown(container.dispose);
    // Both brightnesses: the placeholder is theme-driven, so it must track
    // the ambient surfaceContainer instead of a hardcoded grey. Distinct
    // entity ids keep tier-history underlays out of the second pump.
    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      await _pumpCard(
        tester,
        container,
        IllustCard(entity: parseIllust(illustJson(90 + brightness.index))),
        theme: theme,
      );
      await tester.pumpAndSettle();
      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage).first,
      );
      final placeholder =
          image.placeholder!(
                tester.element(find.byType(CachedNetworkImage).first),
                'unused',
              )
              as ColoredBox;
      expect(placeholder.color, theme.colorScheme.surfaceContainer);
    }
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
    expect(
      tester
          .widget<IllustHeroCardFrame>(find.byType(IllustHeroCardFrame))
          .cropAspect,
      isNull,
    );
  });

  group('tall works', () {
    // Decode widths follow the platform view's 3x ratio: a 100 px card is
    // 300 physical px, so the crop holds while large is at least 240 px
    // wide.
    const cardWidth = 100.0;

    Finder heroFor(int id) => find.byWidgetPredicate(
      (w) => w is Hero && w.tag == 'IllustHero:feed:$id',
    );

    testWidgets('a 1:3 work shows the top of large in a 1:2 card', (
      tester,
    ) async {
      final container = await _makeWorld();
      addTearDown(container.dispose);
      final entity = parseIllust(illustJson(5, width: 2000, height: 6000));
      await _pumpCard(
        tester,
        container,
        IllustCard(entity: entity),
        width: cardWidth,
      );

      final image = tester.widget<PixivImage>(find.byType(PixivImage).first);
      expect(image.url, entity.imageUrls.large);
      expect(image.fit, BoxFit.cover);
      expect(image.alignment, Alignment.topCenter);
      expect(
        tester.getSize(find.byType(PixivImage).first),
        const Size(cardWidth, cardWidth * 2),
      );
      expect(heroFor(5), findsOneWidget);
      // The shuttle grows this top crop into the whole 1:3 image.
      expect(
        tester
            .widget<IllustHeroCardFrame>(find.byType(IllustHeroCardFrame))
            .cropAspect,
        closeTo(1 / 3, 1e-9),
      );
    });

    testWidgets('a narrow 1:5 work shows the square thumbnail, no Hero', (
      tester,
    ) async {
      final container = await _makeWorld();
      addTearDown(container.dispose);
      final entity = parseIllust(illustJson(6, width: 200, height: 1000));
      await _pumpCard(
        tester,
        container,
        IllustCard(entity: entity),
        width: cardWidth,
      );

      final image = tester.widget<PixivImage>(find.byType(PixivImage).first);
      expect(image.url, entity.imageUrls.squareMedium);
      expect(image.fit, BoxFit.cover);
      expect(
        tester.getSize(find.byType(PixivImage).first),
        const Size(cardWidth, cardWidth),
      );
      expect(heroFor(6), findsNothing);
    });

    testWidgets('the feed prefetch fetches what the card will paint', (
      tester,
    ) async {
      final container = await _makeWorld();
      addTearDown(container.dispose);
      // Odd ids are ordinary works on the user's tier; even ids are too
      // tall and narrow and switch to the square thumbnail. The prefetch
      // used to warm the tier preview for both.
      final entities = [
        for (var id = 7101; id <= 7124; id++)
          parseIllust(
            id.isOdd
                ? illustJson(id, width: 800, height: 600)
                : illustJson(id, width: 100, height: 600),
          ),
      ];
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: const [Locale('zh')],
              locale: const Locale('zh'),
              home: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    IllustFeedGrid(
                      itemCount: entities.length,
                      itemIds: [for (final e in entities) e.id],
                      prefetchEntities: entities,
                      itemBuilder: (context, index) =>
                          IllustCard(entity: entities[index]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      });

      final decodeWidth = PixivImage.decodeWidthFor(
        tester.getSize(find.byType(PixivImage).first).width,
      );
      // Prefetch batches land asynchronously; every key issued so far must
      // be the exact (url, decode width) the card paints.
      var squares = 0;
      for (final e in entities) {
        final issued = debugFeedPrefetchedKeys.where(
          (k) => k.startsWith('https://i.pximg.net/${e.id}/'),
        );
        final painted = e.id.isOdd
            ? e.imageUrls.medium
            : e.imageUrls.squareMedium;
        for (final key in issued) {
          expect(key, '$painted|$decodeWidth', reason: '${e.id}');
          if (e.id.isEven) squares++;
        }
      }
      expect(squares, greaterThanOrEqualTo(4));
    });
  });

  testWidgets('the feed registers its prefetch window as image demand and '
      'gives it up when the grid goes away', (tester) async {
    final container = await _makeWorld();
    addTearDown(container.dispose);
    final entities = [
      for (var id = 7201; id <= 7260; id++)
        parseIllust(illustJson(id, width: 800, height: 600)),
    ];
    Widget host({required bool grid}) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: const [Locale('zh')],
        locale: const Locale('zh'),
        home: Scaffold(
          body: grid
              ? CustomScrollView(
                  slivers: [
                    IllustFeedGrid(
                      itemCount: entities.length,
                      itemIds: [for (final e in entities) e.id],
                      prefetchEntities: entities,
                      itemBuilder: (context, index) =>
                          IllustCard(entity: entities[index]),
                    ),
                  ],
                )
              : const SizedBox(),
        ),
      ),
    );
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(host(grid: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });

    final demand = container.read(pixivNetworkFactoryProvider).imageDemand;
    // Works past the built edge: wanted although no card shows them.
    final windowed = [
      for (final e in entities)
        if (demand.wants(e.imageUrls.medium) &&
            demand.debugHolds(e.imageUrls.medium) == 0)
          e.imageUrls.medium,
    ];
    // Three rows of the grid's four columns past the built edge.
    expect(illustColumnsFor(800 - 16), 4);
    expect(windowed, hasLength(4 * 3));

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(host(grid: false));
      await tester.pump();
    });
    expect(windowed.where(demand.wants), isEmpty);
  });

  testWidgets('title and author rows fit the column at 1.3x text', (
    tester,
  ) async {
    final container = await _makeWorld();
    addTearDown(container.dispose);
    // The waterfall column is ~180 wide on a phone; with a long CJK title
    // and author at 1.3x the rows must ellipsize, not overflow.
    await _pumpCard(
      tester,
      container,
      IllustCard(entity: parseIllust(illustJson(5))),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('illust 5'), findsOneWidget);
    expect(find.text('author'), findsOneWidget);
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
