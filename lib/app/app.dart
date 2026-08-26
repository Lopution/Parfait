import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings/app_settings.dart';
import '../core/settings/settings_controller.dart';
import '../features/onboarding/startup_gate.dart';
import 'theme/replica_theme.dart';

class PixivFuncApp extends ConsumerWidget {
  const PixivFuncApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return settings.when(
      loading: () => _materialApp(
        settings: AppSettings.defaults(),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
      error: (error, stackTrace) => _materialApp(
        settings: AppSettings.defaults(),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
      data: (value) => _materialApp(
        settings: value,
        home: StartupGate(settings: value),
      ),
    );
  }

  MaterialApp _materialApp({
    required AppSettings settings,
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
      themeMode: settings.themeMode,
      home: home,
    );
  }
}
