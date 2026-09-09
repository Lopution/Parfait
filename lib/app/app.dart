import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/account_store.dart';
import '../core/settings/app_settings.dart';
import '../core/settings/settings_controller.dart';
import '../core/widget/widget_coordinator.dart';
import '../core/download/download_providers.dart';
import '../core/network/compat/network_providers.dart';
import '../core/platform/android_intent_channel.dart';
import 'external_intent_bridge.dart';
import 'navigation/routes.dart';
import 'startup_gate.dart';
import 'theme/replica_theme.dart';
import 'widgets/settings_load_error.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

class PixivFuncApp extends ConsumerStatefulWidget {
  const PixivFuncApp({super.key, this.intentSource});

  final AndroidIntentSource? intentSource;

  @override
  ConsumerState<PixivFuncApp> createState() => _PixivFuncAppState();
}

class _PixivFuncAppState extends ConsumerState<PixivFuncApp>
    with WidgetsBindingObserver {
  late final GoRouter _router = createPixivRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // C5: one lightweight recovery bootstrap at process start. Constructing
    // the provider triggers the fireImmediately account listener, which
    // scans durable download/ugoira recovery records and cleans only
    // provably-owned pending output; nothing is auto-retried. The scan
    // touches local storage / MediaStore only — no network request.
    ref.read(downloadManagerProvider);
    // Widget maintenance runs only while a widget instance exists (C6); the
    // coordinator checks the native gate and stays idle otherwise. The
    // resume path re-checks the gate so a widget added while the app is
    // running is picked up without a restart.
    unawaited(ref.read(widgetCoordinatorProvider).start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(widgetCoordinatorProvider).ensureStarted());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final themeMode = ref.watch(themeModeProvider);
    return settings.when(
      loading: () => _materialApp(
        settings: AppSettings.defaults(),
        themeMode: themeMode,
        overlay: const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (error, stackTrace) => _materialApp(
        settings: AppSettings.defaults(),
        themeMode: themeMode,
        overlay: Scaffold(
          body: SettingsLoadError(
            error: error,
            onRetry: () => ref.read(settingsProvider.notifier).reload(),
          ),
        ),
      ),
      data: (value) {
        // Build the shared Pixiv transports while settings are available so
        // the first API/image request does not pay lazy client construction.
        unawaited(ref.read(pixivNetworkFactoryProvider).warmUp());
        // Start account restoration in the background too: StartupGate waits
        // on it, so beginning the secure-storage read now overlaps with the
        // first frame instead of serialising behind it.
        unawaited(ref.read(accountStoreProvider.future));
        return _materialApp(
          settings: value,
          themeMode: themeMode,
          startupSettings: value,
        );
      },
    );
  }

  MaterialApp _materialApp({
    required AppSettings settings,
    required ThemeMode themeMode,
    Widget? overlay,
    AppSettings? startupSettings,
  }) {
    return MaterialApp.router(
      title: 'Pixiv Func',
      debugShowCheckedModeBanner: false,
      locale: settings.locale,
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
        Locale('ja', 'JP'),
        Locale('ru', 'RU'),
      ],
      localizationsDelegates: appLocalizationsDelegates,
      theme: replicaTheme(Brightness.light),
      darkTheme: replicaTheme(Brightness.dark),
      themeMode: themeMode,
      restorationScopeId: 'pixiv-func',
      routerConfig: _router,
      // ignore: deprecated_member_use
      builder: (context, child) {
        final routeChild = child!;
        final content =
            overlay ??
            (startupSettings == null
                ? routeChild
                : StartupGate(
                    settings: startupSettings,
                    router: _router,
                    child: routeChild,
                  ));
        // ignore: deprecated_member_use
        return MaterialUiCompatibilityBridge(
          child: ExternalIntentBridge(
            router: _router,
            intentSource: widget.intentSource,
            child: content,
          ),
        );
      },
    );
  }
}
