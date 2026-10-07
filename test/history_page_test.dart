import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/motion/press_scale.dart';
import 'package:parfait/app/motion/removal.dart';
import 'package:parfait/app/motion/state_icon_switcher.dart';
import 'package:parfait/app/widgets/entity_row.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/history/history_models.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/novel/novel_store.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/recording_haptics.dart';
import 'helpers/history_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: const [Locale('zh')],
    locale: const Locale('zh'),
    home: const HistoryPage(),
  ),
);

Future<ProviderContainer> _seedPage(
  WidgetTester tester,
  List<HistoryRecord> records, {
  IllustStore? illustStore,
}) async {
  // Phone-sized surface: the confirm sheet's 0.35-height fraction box
  // overflows on the 800x600 default viewport and pushes the buttons out.
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late ProviderContainer container;
  await tester.runAsync(() async {
    final repository = await openHistoryRepository(records);
    container = await makeHistoryWorld(repository, illustStore: illustStore);
    await tester.pumpWidget(_app(container));
    // Let the first page load land on the real event loop.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  });
  return container;
}

/// The selection bar's title: the bare count, read out as [label].
Finder _selectionTitle(String label) => find.byWidgetPredicate(
  (widget) => widget is Text && widget.semanticsLabel == label,
);

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('long-press enters selection mode and toggles membership', (
    tester,
  ) async {
    await _seedPage(tester, [historyRecord(1), historyRecord(2)]);

    expect(find.text('work 1'), findsOneWidget);

    // Long-press enters management mode with the row selected — the
    // AppBar swaps to the selection surface (primaryContainer + count).
    await tester.longPress(find.text('work 1'));
    await tester.pump();
    expect(_selectionTitle('已选 1 项'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byIcon(Icons.check_circle),
        matching: find.byType(StateIconSwitcher),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.select_all), findsOneWidget);

    // In selection mode a plain tap toggles instead of navigating — the
    // row's own ink is absorbed by the selection wrapper, so warnIfMissed
    // stays off for these deliberate parent hits.
    await tester.tap(find.text('work 2'), warnIfMissed: false);
    await tester.pump();
    expect(_selectionTitle('已选 2 项'), findsOneWidget);
    await tester.tap(find.text('work 1'), warnIfMissed: false);
    await tester.pump();
    expect(_selectionTitle('已选 1 项'), findsOneWidget);

    // The close button exits the mode and restores the normal AppBar.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(_selectionTitle('已选 1 项'), findsNothing);
    expect(find.text('历史记录'), findsOneWidget);
  });

  testWidgets('manage action enters mode; select-all then delete clears', (
    tester,
  ) async {
    await _seedPage(tester, [
      historyRecord(1),
      historyRecord(2),
      historyRecord(3, type: HistoryContentType.novel),
    ]);

    await tester.tap(find.widgetWithText(TextButton, '管理'));
    await tester.pump();
    expect(_selectionTitle('已选 0 项'), findsOneWidget);

    await tester.tap(find.byTooltip('全选'));
    await tester.pump();
    expect(_selectionTitle('已选 3 项'), findsOneWidget);

    // Delete goes through the shared confirm bottom sheet, then the rows
    // disappear and the mode exits.
    // The sheet + confirm interactions stay in fake-async so pump() can
    // drive the entry/exit animations to completion; only the ffi-backed
    // deletes need the real event loop afterwards.
    await tester.tap(find.byTooltip('删除历史记录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('删除后将不可恢复'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pump();
    // The tiles leave first; the delete commits once their exit lands.
    expect(find.text('work 1'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('work 1'), matching: find.byType(Removable)),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 300));
    // The ffi-backed deletes run on the real event loop while the
    // resulting rebuild rides fake-async pump — poll instead of trusting
    // a fixed delay (300ms was enough locally but not on CI).
    for (var i = 0; i < 120 && find.text('暂无浏览历史').evaluate().isEmpty; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      });
    }
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('work 1'), findsNothing);
    expect(find.text('暂无浏览历史'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);
    // An empty history has nothing to manage, and nothing to retry (L1).
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, '管理')).enabled,
      isFalse,
    );
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('entries use shared object contracts', (tester) async {
    // A seeded entity builds the real IllustCard, whose image path creates
    // the network factory — connectivity EventChannel plus the cache
    // manager's path_provider calls. Under runAsync the missing-plugin
    // replies actually land, so answer those channels (an external
    // boundary) instead of letting them surface as test exceptions.
    final messenger = tester.binding.defaultBinaryMessenger;
    final supportDir = Directory.systemTemp.createTempSync('hist-img-');
    addTearDown(() => supportDir.delete(recursive: true));
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => switch (call.method) {
        'getTemporaryDirectory' ||
        'getApplicationSupportDirectory' => supportDir.path,
        _ => null,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(pathChannel, null));
    answerConnectivityChannels();

    await mockNetworkImagesFor(() async {
      // IllustStore is a plain provider — its map does not notify — so the
      // entity must be merged before the page builds.
      final illustStore = IllustStore()..mergeAll([parseIllust(illustJson(1))]);
      final container = await _seedPage(tester, [
        historyRecord(1),
        historyRecord(2, type: HistoryContentType.novel),
      ], illustStore: illustStore);

      // The novel store is a NotifierProvider — a post-build merge rebuilds
      // the entry so the entity-backed branch is exercised too.
      await tester.runAsync(() async {
        container.read(novelStoreProvider.notifier).mergeAll([
          const NovelEntity(
            id: 2,
            title: 'novel 2',
            caption: '',
            user: UserEntity(id: 8, name: 'author 2', account: 'a'),
            tags: [],
            textLength: 100,
            contentVersion: 'v1',
            paragraphs: [],
          ),
        ]);
        await tester.pump();
      });

      // The known-illust cell is the shared IllustCard living under the
      // grid's FeedItemExtent; consuming the published width means the
      // card's own LayoutBuilder fallback is not built (the only other
      // LayoutBuilder under the card lives inside PixivImage — a
      // descendant, never an ancestor of PressScale).
      expect(find.byType(IllustCard), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(FeedItemExtent),
          matching: find.byType(IllustCard),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(IllustCard),
          matching: find.ancestor(
            of: find.byType(PressScale),
            matching: find.byType(LayoutBuilder),
          ),
        ),
        findsNothing,
      );

      // The visit date rides the shared meta presentation on the card and
      // inside the framed cells.
      expect(
        find.descendant(
          of: find.byType(IllustCard),
          matching: find.byType(EntityMetaText),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<EntityMetaText>(
              find
                  .descendant(
                    of: find.byType(IllustCard),
                    matching: find.byType(EntityMetaText),
                  )
                  .first,
            )
            .text,
        contains('2026年9月20日'),
      );

      // The novel cell carries the type badge so it stays distinguishable
      // next to illust entries.
      expect(
        find.descendant(
          of: find.byType(EntityBadge),
          matching: find.byIcon(Icons.menu_book_outlined),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('management interactions fire graded haptics', (tester) async {
    final haptics = recordHaptics();
    await _seedPage(tester, [historyRecord(1), historyRecord(2)]);

    // Long-press entering selection mode = explicit vibration.
    await tester.longPress(find.text('work 1'));
    await tester.pump();
    expect(haptics.roles, [HapticRole.confirm]);

    // In-mode toggling = light selection tick (separate lane, not
    // throttled by the heavy window).
    await tester.tap(find.text('work 2'), warnIfMissed: false);
    await tester.pump();
    expect(haptics.roles, [HapticRole.confirm, HapticRole.select]);

    // Opening the destructive confirm surface = explicit vibration. The
    // throttle window is real-clock, so a second confirm inside 120ms
    // would be swallowed — reset the timestamps to isolate the call site.
    final confirmHaptics = recordHaptics();
    await tester.tap(find.byTooltip('删除历史记录'));
    await tester.pump();
    expect(confirmHaptics.roles, [HapticRole.confirm]);
    // Let the confirm sheet finish dismissing before teardown.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('system back exits selection mode instead of popping', (
    tester,
  ) async {
    await _seedPage(tester, [historyRecord(1)]);

    await tester.longPress(find.text('work 1'));
    await tester.pump();
    expect(_selectionTitle('已选 1 项'), findsOneWidget);

    final popped = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(popped, isTrue);
    expect(_selectionTitle('已选 1 项'), findsNothing);
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('work 1'), findsOneWidget);
  });

  testWidgets('overflow menu toggles record switches and shows checks', (
    tester,
  ) async {
    final container = await _seedPage(tester, [historyRecord(1)]);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    // Defaults record into both stores — the check mark is the trailing
    // icon of a checkable menu row.
    for (final label in ['记录本地浏览历史', '记录到 Pixiv 浏览历史']) {
      final item = find.widgetWithText(MenuItemButton, label);
      expect(item, findsOneWidget);
      expect(
        find.descendant(of: item, matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
    }
    // Delete-all is an action row — enabled while signed in.
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, '删除全部历史记录'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.widgetWithText(MenuItemButton, '记录本地浏览历史'));
    await tester.pumpAndSettle();
    // The controller's write tail is created in the seed's runAsync zone —
    // let the real loop turn so the persisted value lands, same as the
    // ffi-backed delete above.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    expect(container.read(settingsProvider).value!.enableHistory, isFalse);

    // Reopened: the local switch reads unchecked, the Pixiv one still on.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    final local = find.widgetWithText(MenuItemButton, '记录本地浏览历史');
    expect(
      find.descendant(of: local, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    final pixiv = find.widgetWithText(MenuItemButton, '记录到 Pixiv 浏览历史');
    expect(
      find.descendant(of: pixiv, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  testWidgets('signed out the menu keeps switches, disables delete-all', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final repository = await openHistoryRepository(const []);
      final container = await makeHistoryWorld(repository, signedOut: true);
      await tester.pumpWidget(_app(container));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    // The overflow still opens — the record switches are global settings.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, '记录本地浏览历史'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, '记录到 Pixiv 浏览历史'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, '删除全部历史记录'),
          )
          .onPressed,
      isNull,
    );
  });
}
