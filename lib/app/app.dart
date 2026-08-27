import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/replica_strings.dart';
import '../core/navigation/route_observer.dart';
import '../core/settings/app_settings.dart';
import '../core/settings/settings_controller.dart';
import '../features/onboarding/startup_gate.dart';
import 'theme/replica_theme.dart';

class PixivFuncApp extends ConsumerWidget {
  const PixivFuncApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        home: _SettingsStartupError(error: error),
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

class _SettingsStartupError extends ConsumerWidget {
  const _SettingsStartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ReplicaLanguage.fromTag(
      Localizations.localeOf(context).toLanguageTag(),
    );
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.settings_outlined, size: 48),
              const SizedBox(height: 12),
              Text(ReplicaStrings.text(language, 'settingsReadFailed')),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.read(settingsProvider.notifier).reload(),
                child: Text(ReplicaStrings.text(language, 'retry')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
