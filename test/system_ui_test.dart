import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:pixiv_func/app/system_ui.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/features/illust/viewer/image_viewer_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

/// Mounts the root system-bar default exactly like app.dart's builder: the
/// outermost widget inside the theme, reading the resolved brightness.
Widget _app({
  required ThemeData theme,
  GlobalKey<NavigatorState>? navigatorKey,
  Widget? home,
}) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    theme: theme,
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'CN'),
    builder: (context, routeChild) => FuncSystemBars(
      background: Theme.of(context).brightness,
      child: routeChild ?? const SizedBox.shrink(),
    ),
    home: home ?? const Scaffold(body: SizedBox.expand()),
  );
}

void main() {
  testWidgets('a page with no AppBar keeps bar icons inverted to the theme', (
    tester,
  ) async {
    // Control first: a bare MaterialApp publishes the framework default —
    // light nav-bar icons over an opaque black bar. Without the root
    // FuncSystemBars wrap (the app.dart wiring this harness mirrors) the
    // assertions below degenerate to exactly this, so the contrast makes
    // the test non-vacuous.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    await tester.pump();
    await tester.pump();
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
    );
    expect(
      SystemChrome.latestStyle?.systemNavigationBarColor,
      const Color(0xFF000000),
    );

    // RenderView applies the AnnotatedRegion during compositing and
    // latestStyle updates in the following microtask — pump twice before
    // reading so the write lands.
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(_app(theme: replicaTheme(brightness)));
      // AnimatedTheme lerps on the second iteration — let it land before
      // reading the brightness-driven style.
      await tester.pumpAndSettle();
      await tester.pump();

      final style = SystemChrome.latestStyle;
      final icons = brightness == Brightness.light
          ? Brightness.dark
          : Brightness.light;
      expect(
        style?.statusBarIconBrightness,
        icons,
        reason: '$brightness theme must paint $icons status-bar icons',
      );
      expect(
        style?.systemNavigationBarIconBrightness,
        icons,
        reason: '$brightness theme must paint $icons nav-bar icons',
      );
      // Both bars stay transparent — the framework default paints an
      // opaque black navigation bar.
      expect(style?.statusBarColor, const Color(0x00000000));
      expect(style?.systemNavigationBarColor, const Color(0x00000000));
    }
  });

  testWidgets('a scoped FuncSystemBars overrides the root and restores', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _app(theme: replicaTheme(Brightness.light), navigatorKey: navigatorKey),
    );
    await tester.pump();
    await tester.pump();
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark);

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const FuncSystemBars(
          background: Brightness.dark,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();
    expect(
      SystemChrome.latestStyle?.statusBarIconBrightness,
      Brightness.light,
      reason: 'the black page must paint light icons while it is mounted',
    );
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
    );

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(
      SystemChrome.latestStyle?.statusBarIconBrightness,
      Brightness.dark,
      reason: 'leaving the page restores the root style — no imperative reset',
    );
  });

  testWidgets('the image viewer pins light bar icons while mounted', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          theme: replicaTheme(Brightness.light),
          home: const ImageViewerPage(
            urls: ['https://i.pximg.net/1/original.jpg'],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    });

    // The black stage overrides the light theme's dark icons; without the
    // override the clock is invisible after immersive mode exits.
    expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.light);
    expect(
      SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
      Brightness.light,
    );
  });
}
