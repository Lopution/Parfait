import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/navigation/route_observer.dart';
import '../core/settings/app_settings.dart';
import '../core/settings/settings_controller.dart';
import '../core/widget/widget_coordinator.dart';
import '../features/onboarding/startup_gate.dart';
import 'theme/replica_theme.dart';
import 'widgets/settings_load_error.dart';

class PixivFuncApp extends ConsumerStatefulWidget {
  const PixivFuncApp({super.key});

  @override
  ConsumerState<PixivFuncApp> createState() => _PixivFuncAppState();
}

class _PixivFuncAppState extends ConsumerState<PixivFuncApp> {
  @override
  void initState() {
    super.initState();
    // Widget maintenance runs for the app lifetime; the coordinator keeps
    // render state in sync with account changes (PRD R6).
    ref.read(widgetCoordinatorProvider).start();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final themeMode = ref.watch(themeModeProvider);
    return settings.when(
      loading: () => _materialApp(
        settings: AppSettings.defaults(),
        themeMode: themeMode,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
      error: (error, stackTrace) => _materialApp(
        settings: AppSettings.defaults(),
        themeMode: themeMode,
        home: Scaffold(
          body: SettingsLoadError(
            error: error,
            onRetry: () => ref.read(settingsProvider.notifier).reload(),
          ),
        ),
      ),
      data: (value) => _materialApp(
        settings: value,
        themeMode: themeMode,
        home: StartupGate(settings: value),
      ),
    );
  }

  MaterialApp _materialApp({
    required AppSettings settings,
    required ThemeMode themeMode,
    required Widget home,
  }) {
    return MaterialApp(
      title: 'Pixiv Func',
      debugShowCheckedModeBanner: false,
      locale: settings.locale,
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
        Locale('ja', 'JP'),
        Locale('ru', 'RU'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: replicaTheme(Brightness.light),
      darkTheme: replicaTheme(Brightness.dark),
      themeMode: themeMode,
      navigatorObservers: [replicaRouteObserver],
      home: home,
    );
  }
}

