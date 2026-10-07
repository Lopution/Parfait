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
import '../core/platform/accessibility.dart';
import '../core/platform/android_intent_channel.dart';
import 'external_intent_bridge.dart';
import 'haptics/app_haptics.dart';
import 'haptics/haptics_driver.dart';
import 'motion/motion_tokens.dart';
import 'scroll_behavior.dart';
import 'system_ui.dart';
import 'navigation/routes.dart';
import 'startup_gate.dart';
import 'touch_exploration_scope.dart';
import 'theme/replica_theme.dart';
import 'theme/system_colors.dart';
import 'widgets/prompt_host.dart';
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

/// Shows the "update available" prompt on the app's prompt host — the
/// app-level caller holds the root `_promptHostKey`, so this is split out
/// for testability and to keep the l10n lookup on the host's own context
/// (the caller's context sits above MaterialApp and has no Localizations).
@visibleForTesting
void showUpdatePrompt(
  PromptHostState host, {
  required String version,
  required VoidCallback onOpen,
}) {
  final l10n = host.context.l10n;
  host.show(
    l10n.labelValue(l10n.aboutUpdateAvailable, version),
    duration: updatePromptDuration,
    action: PromptAction(label: l10n.aboutUpdateOpen, onPressed: onOpen),
  );
}

class _ParfaitAppState extends ConsumerState<ParfaitApp>
    with WidgetsBindingObserver {
  late final GoRouter _router = createPixivRouter();

  final _promptHostKey = GlobalKey<PromptHostState>();

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
    // so `context.l10n` throws here. The host lives inside MaterialApp and
    // resolves l10n correctly.
    final host = _promptHostKey.currentState;
    if (!mounted ||
        result == null ||
        result.status != UpdateCheckStatus.available ||
        host == null ||
        !host.mounted) {
      return;
    }
    final version = result.release?.manifest.version ?? '';
    showUpdatePrompt(
      host,
      version: '$version',
      onOpen: () => goToAbout(_router),
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
    // Loading keeps the last resolved scheme too (`value` is retained
    // across refreshes); the setting alone gates whether it applies.
    final systemColors = settings.followSystemColors
        ? ref.watch(systemColorSchemesProvider).value
        : null;
    return MaterialApp.router(
      title: 'Parfait',
      debugShowCheckedModeBanner: false,
      locale: settings.locale,
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
        Locale('ja', 'JP'),
        Locale('ru', 'RU'),
      ],
      localizationsDelegates: appLocalizationsDelegates,
      theme: replicaTheme(Brightness.light, systemColors: systemColors?.light),
      darkTheme: replicaTheme(
        Brightness.dark,
        systemColors: systemColors?.dark,
      ),
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
        return AppChrome(
          settings: settings,
          router: _router,
          intentSource: widget.intentSource,
          promptHostKey: _promptHostKey,
          child: PipelineWarmup(child: content),
        );
      },
    );
  }
}

/// Everything between MaterialApp and the route content: system bars,
/// motion settings, the material_ui bridge, touch exploration, prompts and
/// external intents. The UX review harness renders its routes inside the
/// same chrome, so its shots show what the app shows.
class AppChrome extends ConsumerWidget {
  const AppChrome({
    super.key,
    required this.settings,
    required this.router,
    required this.child,
    this.intentSource,
    this.promptHostKey,
  });

  final AppSettings settings;
  final GoRouter router;
  final AndroidIntentSource? intentSource;
  final GlobalKey<PromptHostState>? promptHostKey;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FuncSystemBars(
      background: Theme.of(context).brightness,
      child: MotionScope(
        reduce: settings.reduceMotion,
        speed: settings.animationSpeed,
        pressFeedback: settings.pressFeedback,
        transitionStyle: settings.pageTransitionStyle,
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(
          child: TouchExplorationScope(
            // Above the bridge so intent failures can prompt from its own
            // context; below the motion and touch-exploration scopes it
            // reads.
            child: PromptHost(
              key: promptHostKey,
              accessibility: ref.watch(appAccessibilityProvider),
              child: ExternalIntentBridge(
                router: router,
                intentSource: intentSource,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
