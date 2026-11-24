import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:parfait/app/motion/press_scale.dart';
import 'package:parfait/core/series/series_recent_open_store.dart';
import 'package:parfait/features/illust/detail/detail_page_activity.dart';
import 'package:parfait/features/illust/detail/widgets/illust_series_section.dart';

import 'helpers/series_world.dart';
import 'helpers/localized_app.dart';

void main() {
  testWidgets('detail series section renders card and navigates', (
    tester,
  ) async {
    final (container, _) = await makeSeriesWorld();

    final router = GoRouter(
      initialLocation: '/recommended',
      routes: [
        GoRoute(
          path: '/recommended',
          builder: (_, _) => const Scaffold(
            body: CustomScrollView(
              slivers: [IllustSeriesSection(illustId: 910)],
            ),
          ),
        ),
        GoRoute(
          path: '/recommended/series/:seriesId',
          builder: (_, state) => Scaffold(
            body: Text('series ${state.pathParameters['seriesId']}'),
          ),
        ),
        GoRoute(
          path: '/recommended/illust/:illustId',
          builder: (_, state) => Scaffold(
            body: Text('illust ${state.pathParameters['illustId']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(localizedRouterApp(router, container: container));
    await tester.pumpAndSettle();

    expect(find.text('series 55'), findsOneWidget);
    // Card holds inner prev/next buttons, so MOTION-06 keeps surface ink only.
    expect(
      find.ancestor(
        of: find.text('series 55'),
        matching: find.byType(PressScale),
      ),
      findsNothing,
    );
    expect(find.text('第 3 话 / 共 12 话'), findsOneWidget);
    expect(find.byTooltip('上一话'), findsOneWidget);
    expect(find.byTooltip('下一话'), findsOneWidget);

    await tester.tap(find.byTooltip('下一话'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/recommended/illust/911');

    router.pop();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/recommended');

    await tester.tap(find.text('series 55'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/recommended/series/55');
  });

  testWidgets(
    'inactive DetailPageActivity skips recording recent series open until active',
    (tester) async {
      final (container, _) = await makeSeriesWorld();
      final active = ValueNotifier<bool>(false);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        localizedApp(
          container: container,
          home: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, isActive, _) => DetailPageActivity(
              active: isActive,
              child: const Scaffold(
                body: CustomScrollView(
                  slivers: [IllustSeriesSection(illustId: 910)],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        container
            .read(seriesRecentOpenStoreProvider.notifier)
            .read(accountId: '100', seriesId: 55),
        isNull,
      );

      active.value = true;
      await tester.pumpAndSettle();
      expect(
        container
            .read(seriesRecentOpenStoreProvider.notifier)
            .read(accountId: '100', seriesId: 55)
            ?.illustId,
        910,
      );
    },
  );
}
