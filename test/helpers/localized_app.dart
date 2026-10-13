import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

/// The locale widget tests render in unless they test another.
const zhCN = Locale('zh', 'CN');

/// A [MaterialApp] with the app's localizations, in [locale]: under
/// [container], or under a [ProviderScope] with [overrides], when given.
Widget localizedApp({
  ProviderContainer? container,
  List<Override>? overrides,
  Widget? home,
  Locale? locale = zhCN,
  TransitionBuilder? builder,
  ThemeData? theme,
  GlobalKey<NavigatorState>? navigatorKey,
  ScrollBehavior? scrollBehavior,
}) => _scoped(
  container,
  overrides,
  MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    builder: builder,
    theme: theme,
    navigatorKey: navigatorKey,
    scrollBehavior: scrollBehavior,
    home: home,
  ),
);

/// [localizedApp] over [router].
Widget localizedRouterApp(
  RouterConfig<Object> router, {
  ProviderContainer? container,
  List<Override>? overrides,
  Locale? locale = zhCN,
  TransitionBuilder? builder,
  ThemeData? theme,
  ScrollBehavior? scrollBehavior,
}) => _scoped(
  container,
  overrides,
  MaterialApp.router(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    builder: builder,
    theme: theme,
    scrollBehavior: scrollBehavior,
    routerConfig: router,
  ),
);

Widget _scoped(
  ProviderContainer? container,
  List<Override>? overrides,
  Widget app,
) {
  assert(container == null || overrides == null, 'one scope, not two');
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  if (overrides != null) return ProviderScope(overrides: overrides, child: app);
  return app;
}
