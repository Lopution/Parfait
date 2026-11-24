import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/actionqueue/action_bootstrap.dart';
import '../core/auth/account_store.dart';
import '../core/auth/account_transfer_service.dart';
import '../core/navigation/home_destination.dart';
import '../core/settings/app_settings.dart';
import '../core/settings/settings_controller.dart';
import '../core/log.dart';
import '../core/translation/translation_service.dart';
import '../core/translation/legacy_translation_cleanup.dart';
import '../core/updater/update_auto_check.dart';
import '../core/updater/update_service.dart';
import '../core/download/download_providers.dart';
import '../core/network/compat/network_providers.dart';
import '../core/platform/accessibility.dart';
import '../core/platform/account_transfer_clipboard.dart';
import '../core/platform/android_intent_channel.dart';
import '../core/platform/local_network.dart';
import 'dev_shell/dev_shell.dart';
import 'external_intent_bridge.dart';
import 'haptics/app_haptics.dart';
import 'haptics/haptics_driver.dart';
import 'layout/form_factor.dart';
import 'motion/motion_tokens.dart';
import 'scroll_behavior.dart';
import 'system_ui.dart';
import 'navigation/forward_history.dart';
import 'navigation/keyboard_back.dart';
import 'navigation/routes.dart';
import 'startup_gate.dart';
import 'theme/forui_theme_bridge.dart';
import 'theme/replica_theme.dart';
import 'theme/system_colors.dart';
import 'window/desktop_command_bar.dart';
import 'window/desktop_menu_bar.dart';
import 'window/desktop_title_bar.dart';
import 'touch_exploration_scope.dart';
import 'widgets/prompt_host.dart';
import 'widgets/settings_load_error.dart';
import 'window/desktop_window.dart';
import '../l10n/context.dart';
import '../l10n/app_localizations_delegates.dart';

class ParfaitApp extends ConsumerStatefulWidget {
  const ParfaitApp({super.key, this.intentSource, this.devWorkbenchBuilder});

  final AndroidIntentSource? intentSource;
  final Widget Function(GoRouter router, Widget child)? devWorkbenchBuilder;

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
  bool _warmedUp = false;
  ColorScheme? _cachedLightSystemColors;
  Locale? _cachedLightLocale;
  ThemeData? _cachedLightTheme;
  ColorScheme? _cachedDarkSystemColors;
  Locale? _cachedDarkLocale;
  ThemeData? _cachedDarkTheme;

  ThemeData _lightThemeFor(ColorScheme? systemColors, Locale locale) {
    final cached = _cachedLightTheme;
    if (cached != null &&
        _cachedLightSystemColors == systemColors &&
        _cachedLightLocale == locale) {
      return cached;
    }
    _cachedLightSystemColors = systemColors;
    _cachedLightLocale = locale;
    return _cachedLightTheme = replicaTheme(
      Brightness.light,
      systemColors: systemColors,
      locale: locale,
    );
  }

  ThemeData _darkThemeFor(ColorScheme? systemColors, Locale locale) {
    final cached = _cachedDarkTheme;
    if (cached != null &&
        _cachedDarkSystemColors == systemColors &&
        _cachedDarkLocale == locale) {
      return cached;
    }
    _cachedDarkSystemColors = systemColors;
    _cachedDarkLocale = locale;
    return _cachedDarkTheme = replicaTheme(
      Brightness.dark,
      systemColors: systemColors,
      locale: locale,
    );
  }

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
    // Constructing the pump provider registers the replay handlers and its
    // account listener, which drains each account's queued mutations as it
    // becomes current; the resumed hook below repeats it on foreground.
    ref.read(actionQueuePumpProvider);
    unawaited(_retireLegacyTranslationSession());
    _sweepExpiredTransferClipboard();
    // R2: one delayed background update check per throttle window.
    // Failure and no-update stay silent.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), _runAutoUpdateCheck),
    );
  }

  Future<void> _retireLegacyTranslationSession() async {
    try {
      await retireLegacyTranslationData(
        ref.read(translationCredentialStoreProvider),
      );
    } catch (error) {
      log('translation legacy credential cleanup failed: $error');
    }
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

  void _sweepExpiredTransferClipboard() {
    final clipboard = ref.read(transferClipboardProvider);
    if (clipboard is ExpirableTransferClipboard) {
      unawaited(
        clipboard.sweepExpired().catchError((Object error, _) {
          log('transfer clipboard sweep failed: $error');
          return false;
        }),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The local network permission may have changed in the system
      // settings meanwhile.
      ref.read(localNetworkBlockedHostsProvider.notifier).refresh();
      _sweepExpiredTransferClipboard();
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
    // Watch only the root chrome slice of settings so toggling unrelated
    // preferences (rail state, feed density, history, haptics, window bounds…)
    // never rebuilds MaterialApp or retriggers a full-tree AnimatedTheme lerp.
    final rootState = ref.watch(
      settingsProvider.select((async) {
        if (async.hasError) {
          return (
            pending: false,
            error: async.error,
            locale: null,
            followSystemColors: false,
            reduceMotion: false,
            animationSpeed: AnimationSpeed.normal,
            pressFeedback: true,
            interfaceForm: InterfaceForm.auto,
            guideCompleted: false,
          );
        }
        final value = async.value;
        if (value == null) {
          return (
            pending: true,
            error: null,
            locale: null,
            followSystemColors: false,
            reduceMotion: false,
            animationSpeed: AnimationSpeed.normal,
            pressFeedback: true,
            interfaceForm: InterfaceForm.auto,
            guideCompleted: false,
          );
        }
        return (
          pending: false,
          error: null,
          locale: value.locale,
          followSystemColors: value.followSystemColors,
          reduceMotion: value.reduceMotion,
          animationSpeed: value.animationSpeed,
          pressFeedback: value.pressFeedback,
          interfaceForm: value.interfaceForm,
          guideCompleted: value.guideCompleted,
        );
      }),
    );
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
    if (rootState.error case final error?) {
      return _materialApp(
        settings: AppSettings.defaults(),
        themeMode: themeMode,
        overlay: Scaffold(
          body: SettingsLoadError(
            error: error,
            onRetry: () => ref.read(settingsProvider.notifier).reload(),
          ),
        ),
      );
    }
    if (rootState.pending) {
      return _materialApp(
        settings: AppSettings.defaults(),
        themeMode: themeMode,
        // Settings are a prerequisite for routing decisions, so the gate
        // stays inert while the async preference read completes — defaults
        // would read guideCompleted == false and bounce a signed-in user
        // through /welcome. The initial route is /splash, a neutral surface
        // that hands off once the data branch mounts the real gate.
        startupSettings: AppSettings.defaults(),
        settingsPending: true,
      );
    }
    final value = ref.read(settingsProvider).value ?? AppSettings.defaults();
    if (!_warmedUp) {
      _warmedUp = true;
      // Build the shared Pixiv transports while settings are available so
      // the first API/image request does not pay lazy client construction.
      unawaited(ref.read(pixivNetworkFactoryProvider).warmUp());
      // Start account restoration in the background too: StartupGate waits
      // on it, so beginning the secure-storage read now overlaps with the
      // first frame instead of serialising behind it.
      unawaited(ref.read(accountStoreProvider.future));
    }
    return _materialApp(
      settings: value,
      themeMode: themeMode,
      startupSettings: value,
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
      theme: _lightThemeFor(systemColors?.light, settings.locale),
      darkTheme: _darkThemeFor(systemColors?.dark, settings.locale),
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
        MotionTokens.themeChange,
        reduce: settings.reduceMotion,
        speed: settings.animationSpeed,
      ),
      themeAnimationCurve: MotionTokens.themeChangeCurve,
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
        final chrome = AppChrome(
          settings: settings,
          router: _router,
          intentSource: widget.intentSource,
          promptHostKey: _promptHostKey,
          child: PipelineWarmup(child: content),
        );
        final shellChild = kParfaitDevShell
            ? DevShellHost(child: chrome)
            : chrome;
        return widget.devWorkbenchBuilder?.call(_router, shellChild) ??
            shellChild;
      },
    );
  }
}

/// Everything between MaterialApp and the route content: the form factor,
/// system bars, motion settings, the material_ui bridge, touch exploration, prompts and
/// external intents. The UX review harness renders its routes inside the
/// same chrome, so its shots show what the app shows.
class AppChrome extends ConsumerStatefulWidget {
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
  ConsumerState<AppChrome> createState() => _AppChromeState();
}

class _AppChromeState extends ConsumerState<AppChrome> {
  final DesktopSystemBarsController _systemBars = DesktopSystemBarsController();
  final DesktopCommandBarController _commandBar = DesktopCommandBarController();
  final GlobalKey _routerSubtreeKey = GlobalKey();
  bool _isPreHome = false;
  bool _preHomeRebuildPending = false;

  @override
  void initState() {
    super.initState();
    _isPreHome = isDesktopPreHomePath(liveRouterUri(widget.router).path);
    widget.router.routerDelegate.addListener(_onRouterChanged);
  }

  @override
  void didUpdateWidget(covariant AppChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      oldWidget.router.routerDelegate.removeListener(_onRouterChanged);
      widget.router.routerDelegate.addListener(_onRouterChanged);
      _isPreHome = isDesktopPreHomePath(liveRouterUri(widget.router).path);
    }
  }

  void _onRouterChanged() {
    final next = isDesktopPreHomePath(liveRouterUri(widget.router).path);
    if (next == _isPreHome) return;
    _isPreHome = next;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_preHomeRebuildPending) return;
      _preHomeRebuildPending = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _preHomeRebuildPending = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onRouterChanged);
    _commandBar.dispose();
    _systemBars.dispose();
    super.dispose();
  }

  Widget _buildScopedChrome(
    BuildContext scopeContext,
    TargetPlatform platform,
  ) {
    final form = FormFactor.of(scopeContext);
    final size = MediaQuery.sizeOf(scopeContext);
    final shownDestinations = ref.watch(homeArrangementProvider).shown;
    final canToggleRail = form.canToggleRail(size.width, height: size.height);
    final usesCommandBar =
        !kIsWeb &&
        form == FormFactor.pc &&
        (platform == TargetPlatform.windows ||
            platform == TargetPlatform.macOS ||
            platform == TargetPlatform.linux);
    return DesktopWindowFrame(
      suppressOverlayBar: usesCommandBar,
      // Above the bridge so intent failures can prompt from its own context;
      // below the motion, touch-exploration, and desktop chrome scopes it reads.
      child: PromptHost(
        key: widget.promptHostKey,
        accessibility: ref.watch(appAccessibilityProvider),
        child: ExternalIntentBridge(
          router: widget.router,
          intentSource: widget.intentSource,
          child: KeyboardBack(
            router: widget.router,
            destinations: shownDestinations,
            onToggleRail: canToggleRail
                ? () {
                    final current = form.railExpanded(
                      size.width,
                      height: size.height,
                      choice:
                          ref.read(railExpandedProvider) ??
                          widget.settings.railExpanded,
                    );
                    unawaited(
                      ref
                          .read(settingsProvider.notifier)
                          .setRailExpanded(!current),
                    );
                  }
                : null,
            child: usesCommandBar
                ? Builder(
                    builder: (frameContext) => _buildDesktopCommandBarShell(
                      frameContext,
                      shownDestinations: shownDestinations,
                    ),
                  )
                : widget.child,
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopCommandBarShell(
    BuildContext frameContext, {
    required List<HomeDestination> shownDestinations,
  }) {
    final chrome = DesktopChromeMetrics.maybeOf(frameContext);
    final isFullScreen = chrome?.isFullScreen ?? false;
    return DesktopMenuBar(
      settings: widget.settings,
      router: widget.router,
      destinations: shownDestinations,
      child: ValueListenableBuilder<bool>(
        valueListenable: _commandBar.hidden,
        builder: (context, commandBarHidden, _) {
          final showCommandBar = !isFullScreen && !commandBarHidden;
          return DesktopCommandBarScope(
            active: showCommandBar && !_isPreHome,
            controller: _commandBar,
            child: Overlay.wrap(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showCommandBar)
                    DesktopCommandBar(
                      settings: widget.settings,
                      router: widget.router,
                    ),
                  Expanded(
                    // Isolate Router's ModalBarrier BlockSemantics so earlier
                    // sibling DesktopCommandBar stays reachable.
                    child: Semantics(
                      container: true,
                      explicitChildNodes: true,
                      child: Builder(
                        builder: (contentContext) => _buildRoutedDesktopContent(
                          contentContext,
                          commandBarHidden: commandBarHidden,
                          showCommandBar: showCommandBar,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRoutedDesktopContent(
    BuildContext contentContext, {
    required bool commandBarHidden,
    required bool showCommandBar,
  }) {
    final innerChrome = DesktopChromeMetrics.maybeOf(contentContext);
    final fallbackCustomChrome =
        commandBarHidden && innerChrome != null && innerChrome.hasCustomChrome;
    final preserveTopForButtons =
        fallbackCustomChrome && innerChrome.showCustomButtons;
    final contentChild = preserveTopForButtons
        ? MediaQuery(
            data: MediaQuery.of(contentContext).copyWith(
              padding: MediaQuery.paddingOf(contentContext).copyWith(
                top: math.max(
                  MediaQuery.paddingOf(contentContext).top,
                  innerChrome.titleBarHeight,
                ),
              ),
              viewPadding: MediaQuery.viewPaddingOf(contentContext).copyWith(
                top: math.max(
                  MediaQuery.viewPaddingOf(contentContext).top,
                  innerChrome.titleBarHeight,
                ),
              ),
            ),
            child: widget.child,
          )
        : MediaQuery.removePadding(
            context: contentContext,
            removeTop: true,
            child: widget.child,
          );
    if (innerChrome == null) {
      return KeyedSubtree(key: _routerSubtreeKey, child: contentChild);
    }
    final scopedChrome = innerChrome.copyWith(
      titleBarHeight: preserveTopForButtons ? innerChrome.titleBarHeight : 0,
      leadingInset: showCommandBar ? 0 : innerChrome.leadingInset,
      trailingInset: preserveTopForButtons ? innerChrome.trailingInset : 0,
      child: contentChild,
    );
    return DesktopFallbackWindowChrome(
      enabled: fallbackCustomChrome,
      chrome: innerChrome,
      child: KeyedSubtree(key: _routerSubtreeKey, child: scopedChrome),
    );
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    return DesktopSystemBarsScope(
      controller: _systemBars,
      child: DesktopWindowBinding(
        onOpenDownloads: () => openDownloadsFromRouter(widget.router),
        child: FormFactorScope(
          choice: widget.settings.interfaceForm,
          child: FuncSystemBars(
            background: Theme.of(context).brightness,
            child: MotionScope(
              reduce: widget.settings.reduceMotion,
              speed: widget.settings.animationSpeed,
              pressFeedback: widget.settings.pressFeedback,
              // octo_image, flutter_staggered_grid_view and the WebView plugins
              // still build package:flutter/material widgets; the bridge hands
              // them this theme until they move to material_ui.
              // ignore: deprecated_member_use
              child: MaterialUiCompatibilityBridge(
                child: ForuiThemeHost(
                  child: TouchExplorationScope(
                    child: Builder(
                      builder: (scopeContext) =>
                          _buildScopedChrome(scopeContext, platform),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
