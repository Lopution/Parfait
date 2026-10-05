import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/selectable_tile.dart';
import 'package:parfait/core/watchlater/watch_later_repository.dart';
import 'package:parfait/features/watchlater/watchlater_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/card_world.dart';
import 'helpers/illust_fixtures.dart';

Widget _app(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      home: const WatchLaterPage(),
    ),
  );
}

/// Works 1–3, added in that order: the list shows 3, 2, 1.
Future<void> _seed(MemoryWatchLaterRepository repository) {
  return repository.restoreAll('100', [
    for (var id = 1; id <= 3; id++)
      WatchLaterEntry(addedAt: id * 1000, entity: parseIllust(illustJson(id))),
  ]);
}

Future<List<int>> _ids(MemoryWatchLaterRepository repository) async => [
  for (final entry in await repository.list('100')) entry.entity.id,
];

/// While managing, the tile takes the gestures; the card underneath is
/// absorbed.
Finder _tile(int id) => find.ancestor(
  of: find.text('illust $id'),
  matching: find.byType(SelectableTile),
);

Future<void> _settle(WidgetTester tester) =>
    mockNetworkImagesFor(() => tester.pumpAndSettle());

void main() {
  late ProviderContainer container;
  late MemoryWatchLaterRepository repository;

  Future<void> pumpPage(WidgetTester tester) async {
    final (world, _, memory) = await makeCardWorld();
    container = world;
    repository = memory;
    await _seed(repository);
    await mockNetworkImagesFor(() => tester.pumpWidget(_app(container)));
    await _settle(tester);
  }

  Future<void> enterManaging(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, '管理'));
    await tester.pump();
  }

  testWidgets('several works are removed at once and undone in place', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(await _ids(repository), [3, 2, 1]);

    await enterManaging(tester);
    await tester.tap(_tile(3).first);
    await tester.tap(_tile(1).first);
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    expect(
      tester.getSemantics(_tile(3).first),
      isSemantics(isSelected: true, hasSelectedState: true),
    );

    await tester.tap(find.byTooltip('从稍后再看移除'));
    await _settle(tester);
    expect(await _ids(repository), [2]);
    expect(find.byType(IllustCard), findsOneWidget);
    // Removing leaves selection mode; no confirmation came first.
    expect(find.widgetWithText(TextButton, '管理'), findsOneWidget);
    expect(find.text('已从稍后再看移除'), findsOneWidget);

    await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
    await _settle(tester);
    expect(await _ids(repository), [3, 2, 1]);
    expect(find.byType(IllustCard), findsNWidgets(3));
  });

  testWidgets('select all, and the remove action needs a selection', (
    tester,
  ) async {
    await pumpPage(tester);
    await enterManaging(tester);

    final remove = find.ancestor(
      of: find.byIcon(Icons.remove_circle_outline),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(remove).onPressed, isNull);
    await tester.tap(find.byTooltip('全选'));
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    expect(tester.widget<IconButton>(remove).onPressed, isNotNull);
  });

  testWidgets('back leaves selection mode before the page', (tester) async {
    await pumpPage(tester);
    await enterManaging(tester);
    await tester.tap(_tile(2).first);
    await tester.pump();
    expect(find.text('1'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.widgetWithText(TextButton, '管理'), findsOneWidget);
    expect(find.byType(WatchLaterPage), findsOneWidget);
    expect(await _ids(repository), [3, 2, 1]);
  });

  testWidgets('long press opens the sheet, or selects while managing', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.longPress(_tile(2).first);
    await _settle(tester);
    expect(find.widgetWithText(ListTile, '从稍后再看移除'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await _settle(tester);
    await enterManaging(tester);
    await tester.longPress(_tile(2).first);
    await _settle(tester);
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('no manage entry on an empty list', (tester) async {
    final (world, _, _) = await makeCardWorld();
    await mockNetworkImagesFor(() => tester.pumpWidget(_app(world)));
    await _settle(tester);
    expect(find.text('暂存的作品会显示在这里'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '管理'), findsNothing);
  });
}
