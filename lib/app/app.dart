import 'dart:async';

import 'package:flutter/services.dart';
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
import 'haptics/app_haptics.dart';
import 'haptics/haptics_driver.dart';
import 'motion/motion_tokens.dart';
import 'navigation/home_shell_metrics.dart';
import 'scroll_behavior.dart';
import 'system_ui.dart';
import 'navigation/routes.dart';
import 'startup_gate.dart';
import 'theme/replica_theme.dart';
import 'widgets/app_snack_bar.dart';
import 'widgets/func_bottom_nav.dart';
import 'widgets/settings_load_error.dart';
import '../l10n/context.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

class ParfaitApp extends ConsumerStatefulWidget {
  const ParfaitApp({super.key, this.intentSource});

  final AndroidIntentSource? intentSource;

  @override
  ConsumerState<ParfaitApp> createState() => _ParfaitAppState();
}

/// Dwell time of the auto-update prompt (D2): long enough to read and act
/// on, short enough that a stale "new version" hint cannot linger on screen
/// after the user has already seen it.
const updatePromptDuration = Duration(seconds: 8);

/// Shows the "update available" prompt on the given messenger — the app
/// level caller holds the root `_messengerKey`, so this is split out for
/// testability and to keep the l10n lookup on the messenger's own context
/// (the caller's context sits above MaterialApp and has no Localizations).
@visibleForTesting
void showUpdatePrompt(
  ScaffoldMessengerState messenger, {
  required String version,
  required bool shellBarVisible,
  required bool reduceMotion,
  required AnimationSpeed animationSpeed,
  required VoidCallback onOpen,
}) {
  final l10n = messenger.context.l10n;
  // The prompt is presented by the root messenger above the shell, so it
  // cannot read HomeShellChrome — the visible flag says whether a bar
  // exists and the extent is recomputed from this context's padding with
  // the same formula the shell uses.
  final bottomBarExtent = shellBarVisible
      ? FuncBottomNav.restingExtent(
          MediaQuery.paddingOf(messenger.context).bottom,
        )
      : 0.0;
  showAppSnackBarOn(
    messenger,
    '${l10n.aboutUpdateAvailable}: $version',
    duration: updatePromptDuration,
    action: SnackBarAction(label: l10n.aboutUpdateOpen, onPressed: onOpen),
    margin: appSnackBarShellMargin(bottomBarExtent),
    animationStyle: appSnackBarAnimationStyle(
      (base) => MotionTokens.resolveWith(
        messenger.context,
        base,
        reduce: reduceMotion,
        speed: animationSpeed,
      ),
    ),
  );
}

class _ParfaitAppState extends ConsumerState<ParfaitApp>
    with WidgetsBindingObserver {
  late final GoRouter _router = createPixivRouter();

  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // D2: edge-to-edge from process start. Previously only exiting the
    // viewer set this, so Android 10-14 rendered a different layout before
    // and after the first viewer visit (and the transparent nav bar only
    // means something edge-to-edge). Android 15+ enforces it anyway.
    unawaited(setSystemUiMode(SystemUiMode.edgeToEdge));
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
    // R2: one delayed background update check per throttle window.
    // Failure and no-update stay silent.
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
    // The root ScaffoldMessenger sits above MotionScope, so the in-app
    // motion settings are read from the provider directly (the same source
    // the scope publishes); the platform half of the gate is still
    // reachable through the messenger's context.
    final settings = ref.read(settingsProvider).value;
    showUpdatePrompt(
      messenger,
      version: '$version',
      shellBarVisible: ref.read(homeShellBarVisibleProvider),
      reduceMotion: settings?.reduceMotion ?? false,
      animationSpeed: settings?.animationSpeed ?? AnimationSpeed.normal,
      onOpen: () => _router.push<void>('/settings/about'),
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
    // §5.6: AppHaptics is the sole haptic entry. The reader re-reads the
    // latest persisted setting on each trigger, so the settings toggle
    // applies immediately without a restart.
    AppHaptics.configure(
      strength: () =>
          ref.read(settingsProvider).value?.hapticStrength ??
          HapticStrength.standard,
      driver: ref.watch(hapticsDriverProvider),
    );
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
      title: 'Parfait',
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
      restorationScopeId: 'parfait',
      routerConfig: _router,
      // Desktop affordance: mouse and trackpad drag like touch. Wheel
      // smoothing stays per-scrollable — see SmoothWheelScroll.
      scrollBehavior: const FuncScrollBehavior(),
      // The light/dark and palette cross-fade. MaterialApp sits above
      // MotionScope, so the settings are passed in directly.
      themeAnimationDuration: MotionTokens.resolveWith(
        context,
        MotionTokens.medium,
        reduce: settings.reduceMotion,
        speed: settings.animationSpeed,
      ),
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
        return FuncSystemBars(
          background: Theme.of(context).brightness,
          child: MotionScope(
            reduce: settings.reduceMotion,
            speed: settings.animationSpeed,
            pressFeedback: settings.pressFeedback,
            // ignore: deprecated_member_use
            child: MaterialUiCompatibilityBridge(
              child: ExternalIntentBridge(
                router: _router,
                intentSource: widget.intentSource,
                child: PipelineWarmup(child: content),
              ),
            ),
          ),
        );
      },
    );
  }
}
