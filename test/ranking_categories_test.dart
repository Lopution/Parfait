import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/icons/ui_icons.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/ranking_category_sheet.dart';
import 'package:parfait/features/ranking/ranking_date.dart';
import 'package:parfait/core/illust/ranking_repository.dart';
import 'package:parfait/core/novel/novel_repository.dart';
import 'package:parfait/core/ranking/ranking_catalog.dart';
import 'package:parfait/core/ranking/ranking_category.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/arrangement.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/lookup.dart';

import 'helpers/fake_settings.dart';
import 'helpers/layout_fonts.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/view_size.dart';

enum _Item { a, b, c, d }

const _defaults = Arrangement<_Item>(
  shown: [_Item.a, _Item.b],
  hidden: [_Item.c],
);

_Item? _lookup(String id) => _Item.values.asNameMap()[id];

Arrangement<_Item> _resolve(List<ArrangedEntry>? saved) =>
    Arrangement.resolve(_defaults, saved, _lookup);

void main() {
  group('arrangement', () {
    test('null is the default; the saved order and visibility win', () {
      expect(_resolve(null), same(_defaults));
      expect(
        _resolve([
          (id: 'c', visible: true),
          (id: 'a', visible: false),
          (id: 'b', visible: true),
        ]),
        const Arrangement(shown: [_Item.c, _Item.b], hidden: [_Item.a]),
      );
    });

    test(
      'unknown and repeated ids are skipped, unmentioned items appended',
      () {
        // Written by a newer version ("z"), then by this one before `b` and
        // `c` existed: they arrive with their default visibility.
        final resolved = _resolve([
          (id: 'z', visible: true),
          (id: 'a', visible: true),
          (id: 'a', visible: false),
        ]);
        expect(
          resolved,
          const Arrangement(shown: [_Item.a, _Item.b], hidden: [_Item.c]),
        );
      },
    );

    test('a payload hiding every known item still shows one', () {
      expect(
        _resolve([
          (id: 'z', visible: true),
          (id: 'a', visible: false),
          (id: 'b', visible: false),
          (id: 'c', visible: false),
        ]).shown,
        [_Item.a],
      );
    });

    test('decoding skips malformed entries; a non-list is the default', () {
      expect(Arrangement.decodeEntries('broken'), isNull);
      expect(
        Arrangement.decodeEntries([
          {'id': 'a', 'visible': true},
          {'id': 'b'},
          {'id': 3, 'visible': true},
          'c',
          {'id': 'd', 'visible': false},
        ]),
        [(id: 'a', visible: true), (id: 'd', visible: false)],
      );
      final entries = _defaults.toEntries((item) => item.name);
      expect(
        Arrangement.decodeEntries(Arrangement.encodeEntries(entries)),
        entries,
      );
    });

    test('edits keep shown items first and one always shown', () {
      const four = Arrangement(
        shown: [_Item.a, _Item.b, _Item.c],
        hidden: [_Item.d],
      );
      expect(four.reorder(0, 2).shown, [_Item.b, _Item.c, _Item.a]);
      expect(four.moveToFront(_Item.c).shown, [_Item.c, _Item.a, _Item.b]);
      expect(
        four.moveToFront(_Item.d),
        const Arrangement(
          shown: [_Item.d, _Item.a, _Item.b, _Item.c],
          hidden: [],
        ),
      );
      final hidden = four.hide(_Item.b);
      expect(hidden.hidden, [_Item.b, _Item.d], reason: 'newest first');
      expect(hidden.show(_Item.d).shown, [_Item.a, _Item.c, _Item.d]);

      const last = Arrangement(shown: [_Item.a], hidden: [_Item.b]);
      expect(last.canHide, isFalse);
      expect(() => last.hide(_Item.a), throwsStateError);
    });
  });

  group('ranking modes', () {
    test('the default arrangements list every mode once', () {
      void expectComplete<T>(Arrangement<T> defaults, List<T> values) {
        final all = [...defaults.shown, ...defaults.hidden];
        expect(all.toSet(), values.toSet());
        expect(all, hasLength(values.length));
      }

      expectComplete(RankingMode.defaultArrangement, RankingMode.values);
      expectComplete(
        NovelRankingMode.defaultArrangement,
        NovelRankingMode.values,
      );
      expect(RankingMode.defaultArrangement.shown, hasLength(13));
      expect(NovelRankingMode.defaultArrangement.shown, hasLength(11));
    });

    test('every label resolves in every locale', () async {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = await AppLocalizations.delegate.load(locale);
        for (final RankingCategory mode in [
          ...RankingMode.values,
          ...NovelRankingMode.values,
        ]) {
          expect(
            l10nLookup(l10n, mode.labelKey),
            isNot(mode.labelKey),
            reason: '$locale ${mode.labelKey}',
          );
        }
      }
    });
  });

  group('visible categories', () {
    const shown = [
      RankingMode.day,
      RankingMode.dayAi,
      RankingMode.dayR18,
      RankingMode.weekR18G,
    ];

    List<RankingMode> visible({
      bool blockR18 = false,
      bool blockAI = false,
      List<RankingMode> shown = shown,
      RankingMode? routeMode,
    }) => visibleRankingCategories(
      shown,
      blockR18: blockR18,
      blockAI: blockAI,
      fallback: RankingMode.day,
      routeMode: routeMode,
    );

    test('the local block hides R-18 with R-18G, and AI', () {
      expect(visible(blockR18: true), [RankingMode.day, RankingMode.dayAi]);
      expect(visible(blockAI: true), [
        RankingMode.day,
        RankingMode.dayR18,
        RankingMode.weekR18G,
      ]);
      expect(visible(blockR18: true, shown: const [RankingMode.dayR18]), [
        RankingMode.day,
      ], reason: 'the fallback stands in for an emptied list');
    });

    test('a hidden route category goes first; a blocked one does not', () {
      expect(visible(routeMode: RankingMode.month).first, RankingMode.month);
      expect(visible(routeMode: RankingMode.dayR18), shown);
      expect(visible(blockR18: true, routeMode: RankingMode.weekR18Manga), [
        RankingMode.day,
        RankingMode.dayAi,
      ]);
    });

    test(
      'the page opens on the route, then the last viewed, then the first',
      () {
        expect(
          initialRankingCategory(
            shown,
            routeMode: RankingMode.dayR18,
            lastViewed: RankingMode.dayAi,
          ),
          RankingMode.dayR18,
        );
        expect(
          initialRankingCategory(shown, lastViewed: RankingMode.dayAi),
          RankingMode.dayAi,
        );
        expect(
          initialRankingCategory(shown, lastViewed: RankingMode.month),
          RankingMode.day,
          reason: 'a last category since hidden or blocked',
        );
      },
    );
  });

  testWidgets(
    'showRankingCategorySheet keeps 3 columns and stays above the footer divider across locales at 1280x800',
    (tester) async {
      await loadLayoutFonts();
      setViewSize(tester, const Size(1280, 800));
      await seedSettings(AppSettings.defaults());

      for (final locale in AppLocalizations.supportedLocales) {
        await tester.pumpWidget(
          localizedApp(
            overrides: const [],
            locale: locale,
            theme: replicaTheme(
              Brightness.light,
              fontFamilyFallback: layoutFontFallback,
            ),
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => unawaited(
                  showRankingCategorySheet(
                    context,
                    catalog: illustRankingCatalog,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final sheet = find.byWidgetPredicate(
          (w) => '${w.runtimeType}'.startsWith('_RankingCategorySheet'),
        );
        expect(sheet, findsOneWidget, reason: '$locale');
        final sheetSurface = find
            .ancestor(of: sheet, matching: find.byType(Material))
            .first;
        final wraps = find.descendant(of: sheet, matching: find.byType(Wrap));
        expect(wraps, findsWidgets, reason: '$locale');
        for (final wrapElement in wraps.evaluate()) {
          final tiles = find.descendant(
            of: find.byElementPredicate((e) => identical(e, wrapElement)),
            matching: find.byWidgetPredicate((w) => w.key is ValueKey<Object?>),
          );
          final rects = [
            for (final element in tiles.evaluate())
              tester.getRect(
                find.byElementPredicate((e) => identical(e, element)),
              ),
          ];
          if (rects.length < 4) continue;
          final firstRow = rects
              .where((r) => (r.top - rects.first.top).abs() < 1.0)
              .toList();
          expect(firstRow, hasLength(3), reason: '$locale 3-column grid');
          expect(
            rects[3].top,
            greaterThan(firstRow.first.bottom),
            reason: '$locale row wrap after 3 tiles',
          );
        }

        final scrollView = find.descendant(
          of: sheet,
          matching: find.byType(SingleChildScrollView),
        );
        final divider = find.descendant(
          of: sheet,
          matching: find.byType(Divider),
        );
        final scrollRect = tester.getRect(scrollView);
        final dividerRect = tester.getRect(divider);
        expect(
          scrollRect.bottom,
          lessThanOrEqualTo(dividerRect.top + 0.01),
          reason: '$locale scroll area stops above action bar divider',
        );
        expect(
          tester.getRect(sheetSurface).bottom,
          lessThanOrEqualTo(800),
          reason: '$locale dialog stays inside 800dp viewport',
        );
        // Also ensure after scrolling to the bottom the content stays clipped above the divider.
        await tester.drag(scrollView, const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(scrollView).bottom,
          lessThanOrEqualTo(tester.getRect(divider).top + 0.01),
          reason: '$locale scrolled body stays above divider',
        );
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'ranking editor requires explicit handle drag or × button and RankingDateBar exposes pick-date',
    (tester) async {
      await seedSettings(AppSettings.defaults());
      await tester.pumpWidget(
        localizedApp(
          overrides: const [],
          builder: promptHostBuilder,
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => unawaited(
                showRankingCategorySheet(
                  context,
                  catalog: illustRankingCatalog,
                  editing: true,
                ),
              ),
              child: const Text('edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();

      final firstTile = find.byKey(const ValueKey(RankingMode.day));
      final secondTile = find.byKey(const ValueKey(RankingMode.week));
      expect(firstTile, findsOneWidget);

      // Tapping the tile label itself never hides the category.
      await tester.tap(
        find.descendant(of: firstTile, matching: find.byType(Text)),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: firstTile, matching: find.byIcon(UiIcons.close)),
        findsOneWidget,
      );

      // Dragging the explicit handle reorders immediately without 500ms hold.
      final handle = find.descendant(
        of: firstTile,
        matching: find.byIcon(UiIcons.dragHandle),
      );
      final delta = tester.getCenter(secondTile) - tester.getCenter(handle);
      await tester.drag(handle, delta);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(secondTile).dx,
        lessThan(tester.getTopLeft(firstTile).dx),
      );

      // Clicking the explicit × button hides the category cleanly.
      await tester.tap(
        find.descendant(of: firstTile, matching: find.byIcon(UiIcons.close)),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: firstTile, matching: find.byIcon(UiIcons.add)),
        findsOneWidget,
      );

      // RankingDateBar exposes direct date picking alongside back-to-latest.
      var picked = 0;
      await tester.pumpWidget(
        localizedApp(
          body: RankingDateBar(
            date: DateTime(2026, 1, 10),
            onPickDate: () => picked += 1,
            onBackToLatest: () {},
          ),
        ),
      );
      await tester.tap(find.text('选择日期'));
      expect(picked, 1);
    },
  );
}
