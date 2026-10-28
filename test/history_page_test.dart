import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/motion/removal.dart';
import 'package:parfait/app/motion/state_icon_switcher.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/history/history_database.dart';
import 'package:parfait/core/history/history_feed_controller.dart';
import 'package:parfait/core/history/history_models.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/features/history/history_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/history_world.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';

Widget _app(ProviderContainer container) =>
    localizedApp(container: container, home: const HistoryPage());

Future<ProviderContainer> _seedPage(
  WidgetTester tester,
  List<HistoryRecord> records, {
  IllustStore? illustStore,
}) async {
  // Phone-sized surface: the confirm sheet's 0.35-height fraction box
  // overflows on the 800x600 default viewport and pushes the buttons out.
  setViewSize(tester, const Size(390, 844));
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

  testWidgets('each open reads afresh; open, the order holds; hidden, it '
      'catches up', (tester) async {
    setViewSize(tester, const Size(390, 844));
    HistoryRecord seen(int id, int minute) => historyRecord(
      id,
    ).copyWith(lastViewedAt: DateTime.utc(2026, 9, 20, 10, minute));
    late HistoryRepository history;
    late ProviderContainer container;
    await tester.runAsync(() async {
      history = await openHistoryRepository([seen(1, 1), seen(2, 2)]);
      container = await makeHistoryWorld(history);
    });
    final open = ValueNotifier(true);
    final shown = ValueNotifier(true);
    await tester.pumpWidget(
      localizedApp(
        container: container,
        home: ListenableBuilder(
          listenable: Listenable.merge([open, shown]),
          builder: (_, _) => open.value
              ? TickerMode(enabled: shown.value, child: const HistoryPage())
              : const SizedBox(),
        ),
      ),
    );
    Future<void> view(int id, int minute) =>
        settleHistory(tester, history, () => history.upsert(seen(id, minute)));
    // Reading order: rows first, then along the row.
    bool firstIs(int id, int other) {
      final a = tester.getTopLeft(find.text('work $id'));
      final b = tester.getTopLeft(find.text('work $other'));
      return a.dy < b.dy || (a.dy == b.dy && a.dx < b.dx);
    }

    await settleHistory(tester, history);
    expect(firstIs(2, 1), isTrue);
    await view(1, 3);
    expect(firstIs(2, 1), isTrue, reason: 'on screen the order holds');

    // Another tab: the page is hidden, nothing over it.
    shown.value = false;
    await tester.pump();
    await view(1, 4);
    shown.value = true;
    await settleHistory(tester, history);
    expect(firstIs(1, 2), isTrue, reason: 'it caught up out of sight');

    open.value = false;
    await settleHistory(tester, history);
    await view(2, 5);
    open.value = true;
    await settleHistory(tester, history);
    expect(firstIs(2, 1), isTrue, reason: 'opened again, it reads afresh');
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

  testWidgets('a failed first read offers a retry, not "no history" (B10)', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      // A store closed before it ever opened fails every read.
      final database = HistoryDatabase(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      await database.close();
      container = await makeHistoryWorld(HistoryRepository(database: database));
    });
    await tester.pumpWidget(_app(container));
    await tester.runAsync(() => Future<void>.delayed(Durations.short2));
    await tester.pump();
    expect(find.text('历史记录加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  test(
    'deleting a loaded record never skips one on the next page (B11)',
    () async {
      // 31 records a minute apart: the first page holds 31 down to 2.
      final history = await openHistoryRepository([
        for (var id = 1; id <= 31; id++)
          historyRecord(
            id,
          ).copyWith(lastViewedAt: DateTime.utc(2026, 9, 20, 10, id)),
      ]);
      final container = await makeHistoryWorld(history);
      final provider = historyFeedControllerProvider('100');
      container.listen(provider, (_, _) {});
      final first = await container.read(provider.future);
      final feed = container.read(provider.notifier);

      await feed.removeRecord(feed.recordFor(first.ids.first)!);
      await feed.loadMore();
      final ids = container.read(provider).requireValue.ids;
      expect(
        [for (final id in ids) feed.recordFor(id)!.contentId],
        [for (var id = 30; id >= 1; id--) id],
      );
    },
  );

  testWidgets('an empty history with recording off offers to turn it on', (
    tester,
  ) async {
    final container = await _seedPage(tester, const []);
    Future<void> settle() => tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });
    await tester.runAsync(
      () => container.read(settingsProvider.notifier).setHistoryEnabled(false),
    );
    await settle();
    expect(find.text('「记录本地浏览历史」已关闭'), findsOneWidget);

    await tester.tap(find.text('开启记录'));
    await settle();
    expect(container.read(settingsProvider).value!.enableHistory, isTrue);
    expect(find.text('「记录本地浏览历史」已关闭'), findsNothing);
    expect(find.text('暂无浏览历史'), findsOneWidget);
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
}
