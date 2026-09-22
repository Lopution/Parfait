import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/actionqueue/action_bootstrap.dart';
import '../core/auth/account_store.dart';
import '../core/settings/app_settings.dart';
import '../core/settings/settings_controller.dart';
import '../core/updater/update_auto_check.dart';
import '../core/updater/update_service.dart';
import '../core/widget/widget_coordinator.dart';
import '../core/download/download_providers.dart';
import '../core/network/compat/network_providers.dart';
import '../core/platform/android_intent_channel.dart';
import 'external_intent_bridge.dart';
import 'motion/motion_tokens.dart';
import 'scroll_behavior.dart';
import 'navigation/routes.dart';
import 'startup_gate.dart';
import 'theme/replica_theme.dart';
import 'widgets/app_snack_bar.dart';
import 'widgets/settings_load_error.dart';
import '../l10n/context.dart';
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

  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

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
    // Constructing the pump provider registers the replay handlers and
    // drains the current account's queued mutations once at startup; the
    // resumed hook below repeats it whenever the app returns foreground.
    ref.read(actionQueuePumpProvider);
    // R2: one delayed background update check per throttle window (the
    // pixes/skana launch convention). Failure and no-update stay silent.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), _runAutoUpdateCheck),
    );
  }

  Future<void> _runAutoUpdateCheck() async {
    if (!mounted) return;
    final result = await ref.read(updateAutoCheckProvider).checkOnce();
    // This State's own context sits above MaterialApp — no Localizations —
    // so `context.l10n` throws here. The messenger's context lives inside
    // MaterialApp and resolves l10n correctly.
    final messenger = _messengerKey.currentState;
    final messengerContext = _messengerKey.currentContext;
    if (!mounted ||
        result == null ||
        result.status != UpdateCheckStatus.available ||
        messenger == null ||
        messengerContext == null ||
        !messengerContext.mounted) {
      return;
    }
    final version = result.release?.manifest.version ?? '';
    final l10n = messengerContext.l10n;
    showAppSnackBarOn(
      messenger,
      '${l10n.aboutUpdateAvailable}: $version',
      action: SnackBarAction(
        label: l10n.aboutUpdateOpen,
        onPressed: () => _router.push<void>('/settings/about'),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(widgetCoordinatorProvider).ensureStarted());
      // Returning to the foreground is connectivity evidence: replay any
      // mutations that were queued while offline.
      final accountId = ref.read(accountStoreProvider).value?.usableCurrent?.id;
      if (accountId != null) {
        unawaited(ref.read(actionQueueProvider).drain(accountId));
      }
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
        // Settings are a prerequisite for routing decisions, so the gate
        // stays inert while the async preference read completes — defaults
        // would read guideCompleted == false and bounce a signed-in user
        // through /welcome. The initial route is /splash, a neutral surface
        // that hands off once the data branch mounts the real gate.
        startupSettings: AppSettings.defaults(),
        settingsPending: true,
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
    bool settingsPending = false,
  }) {
    return MaterialApp.router(
      title: 'Pixiv Func',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
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
      // Desktop affordance: mouse and trackpad drag like touch. Wheel
      // smoothing stays per-scrollable — see SmoothWheelScroll.
      scrollBehavior: const FuncScrollBehavior(),
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
                    settingsPending: settingsPending,
                    child: routeChild,
                  ));
        return MotionScope(
          reduce: settings.reduceMotion,
          // ignore: deprecated_member_use
          child: MaterialUiCompatibilityBridge(
            child: ExternalIntentBridge(
              router: _router,
              intentSource: widget.intentSource,
              child: PipelineWarmup(child: content),
            ),
          ),
        );
      },
    );
  }
}
