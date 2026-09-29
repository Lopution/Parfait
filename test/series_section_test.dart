import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/profile/profile_models.dart';
import 'package:pixiv_func/features/illust/detail/widgets/illust_series_section.dart';
import 'package:pixiv_func/features/profile/profile_header_delegate.dart';
import 'package:pixiv_func/features/profile/profile_work_type_switch.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/series_world.dart';
import 'helpers/test_preferences.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('detail series section renders card and navigates', (
    tester,
  ) async {
    final (container, _) = await makeSeriesWorld();
    addTearDown(container.dispose);

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

    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('series 55'), findsOneWidget);
      expect(find.text('第 3 话'), findsOneWidget);
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
  });

  testWidgets('non-series work renders no section card', (tester) async {
    final (container, _) = await makeSeriesWorld();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [IllustSeriesSection(illustId: 42)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsNothing);
    expect(find.byTooltip('下一话'), findsNothing);
  });

  testWidgets('work selector offers the series section option', (tester) async {
    // The selector moved out of the pinned tab bar into each work feed
    // (D3): `ProfileWorkTypeSwitch` is the value object feeds render as a
    // floating sliver — this mounts that sliver directly.
    ProfileWorkSection? selected;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: Builder(
            builder: (context) => CustomScrollView(
              slivers: [
                ProfileWorkTypeSwitch(
                  selected: ProfileWorkSection.illust,
                  onSelected: (section) => selected = section,
                ).sliver(context),
                const SliverFillRemaining(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in ['插画', '漫画', '小说', '系列']) {
      expect(
        find.widgetWithText(SegmentedButton<ProfileWorkSection>, label),
        findsOneWidget,
      );
    }

    await tester.tap(find.text('系列'));
    expect(selected, ProfileWorkSection.series);

    // The tab bar itself is now a constant toolbar height on every tab —
    // no 64dp selector strip under it anymore.
    for (final isMe in [false, true]) {
      final controller = TabController(length: isMe ? 5 : 4, vsync: tester);
      addTearDown(controller.dispose);
      for (var index = 0; index < controller.length; index++) {
        controller.index = index;
        final delegate = ReplicaProfileTabsDelegate(
          controller: controller,
          isMe: isMe,
          onTabTap: (_) {},
        );
        expect(delegate.minExtent, kToolbarHeight);
        expect(delegate.maxExtent, kToolbarHeight);
      }
    }
  });
}
