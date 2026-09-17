import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/profile/profile_models.dart';
import 'package:pixiv_func/features/illust/detail/widgets/illust_series_section.dart';
import 'package:pixiv_func/features/profile/profile_header_delegate.dart';
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

  testWidgets('work selector offers the series section chip', (tester) async {
    ProfileWorkSection? selected;
    final controller = TabController(length: 4, vsync: tester);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (_, _) => [
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileTabsDelegate(
                  controller: controller,
                  isMe: false,
                  expanded: true,
                  section: ProfileWorkSection.illust,
                  onTabTap: (_) {},
                  onSectionChanged: (section) => selected = section,
                ),
              ),
            ],
            body: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('插画'), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('系列'), findsOneWidget);

    await tester.tap(find.text('系列'));
    expect(selected, ProfileWorkSection.series);
  });
}
