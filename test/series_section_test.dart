import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/motion/press_scale.dart';
import 'package:parfait/features/illust/detail/widgets/illust_series_section.dart';
import 'package:parfait/features/profile/profile_header_delegate.dart';
import 'package:parfait/features/profile/user_series_feed.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
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
      expect(
        find.ancestor(
          of: find.text('series 55'),
          matching: find.byType(PressScale),
        ),
        findsOneWidget,
      );
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

  testWidgets('user series cards carry the press scale', (tester) async {
    final (container, _) = await makeSeriesWorld();
    addTearDown(container.dispose);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: Scaffold(body: UserSeriesFeed(userId: 7)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.ancestor(
          of: find.text('series 55'),
          matching: find.byType(PressScale),
        ),
        findsOneWidget,
      );
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

  testWidgets('the profile tab bar is a constant toolbar height', (
    tester,
  ) async {
    final controller = TabController(length: 4, vsync: tester);
    addTearDown(controller.dispose);
    for (var index = 0; index < controller.length; index++) {
      controller.index = index;
      final delegate = ReplicaProfileTabsDelegate(
        controller: controller,
        labels: const ['插画', '系列', '收藏', '关注'],
        onTabTap: (_) {},
      );
      expect(delegate.minExtent, kToolbarHeight);
      expect(delegate.maxExtent, kToolbarHeight);
    }
  });
}
