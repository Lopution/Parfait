import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/account_store.dart';
import '../core/errors/error_category.dart';
import '../core/navigation/home_destination.dart';
import '../core/settings/app_settings.dart';
import '../core/settings/settings_controller.dart';
import '../l10n/lookup.dart';
import '../l10n/context.dart';
import 'layout/content_widths.dart';
import 'widgets/app_spinner.dart';
import 'widgets/errors/error_details.dart';
import 'theme/func_semantic_tokens.dart';
import 'icons/ui_icons.dart';

/// Cold-start router driven by real settings and account state.
///
/// - guide not completed -> Welcome
/// - guide completed, no usable account -> Login
/// - guide completed, usable account -> Home
///
/// Hydration failures surface an explicit retryable error instead of silently
/// degrading to the no-account branch.
class StartupGate extends ConsumerStatefulWidget {
  const StartupGate({
    super.key,
    required this.settings,
    required this.router,
    this.settingsPending = false,
    required this.child,
  });

  final AppSettings settings;
  final GoRouter router;
  final Widget child;

  /// True while [settings] itself is still hydrating and carries placeholder
  /// values — defaults read `guideCompleted == false`, which would bounce a
  /// signed-in user through /welcome for no reason. The gate makes no
  /// routing decisions then; the current route child is the neutral /splash
  /// surface and stays painted.
  final bool settingsPending;

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();

  /// Live matched location — `router.state` covers imperative `push`ed routes
  /// too, while `routeInformationProvider.value` only tracks the last
  /// declarative navigation. Reading the latter while the user sits on a
  /// pushed page returns a stale path and makes every gate rebuild misjudge.
  /// `state` throws while the very first match is still being established,
  /// so fall back to the info provider for those early frames.
  static String _currentPath(GoRouter router) {
    try {
      return router.state.uri.path;
    } on Object {
      return router.routeInformationProvider.value.uri.path;
    }
  }

  /// An auth or onboarding route, or the pending splash.
  static bool _isAuthFlowPath(String path) =>
      path == '/splash' ||
      path == '/login' ||
      path.startsWith('/login/') ||
      path == '/welcome' ||
      path.startsWith('/welcome/');

  /// The stack's base: the location without pushed pages, which go_router's
  /// `currentConfiguration.uri` reflects.
  static String _basePath(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.path;
}

class _StartupGateState extends ConsumerState<StartupGate> {
  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_onStackChanged);
  }

  @override
  void didUpdateWidget(StartupGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.router, widget.router)) return;
    oldWidget.router.routerDelegate.removeListener(_onStackChanged);
    widget.router.routerDelegate.addListener(_onStackChanged);
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onStackChanged);
    super.dispose();
  }

  /// A pop (system back onto the splash, say) changes the stack without a
  /// route information notification. The delegate also notifies during
  /// the Router's own build, where rebuilding the gate would assert, so
  /// the gate looks again once the frame is done.
  void _onStackChanged() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted) setState(() {});
      })
      ..ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final router = widget.router;
    final settings = widget.settings;
    final child = widget.child;
    final accounts = ref.watch(accountStoreProvider);
    if (widget.settingsPending) return child;
    // The gate must rebuild when the route changes: while a redirect is
    // pending the route child is held back, so only a route notification
    // can release the spinner once go() lands. `routeInformationProvider`
    // is a ValueListenable that fires on declarative navigation — exactly
    // the go() redirects this gate performs.
    return ValueListenableBuilder<RouteInformation>(
      valueListenable: router.routeInformationProvider,
      builder: (context, _, _) {
        final path = StartupGate._currentPath(router);
        // /splash is a pending surface, never a destination: while a
        // redirect is in flight it stays painted (it is neutral content),
        // where a stale welcome/login route must not appear.
        final isSplash = path == '/splash';
        if (!settings.guideCompleted) {
          // Keep child mounted while the welcome redirect is in flight —
          // child is the Router, and unmounting it here detaches the
          // provider listener that must consume the scheduled go().
          if (!_ensureLocation(context, const {
            '/welcome',
            '/welcome/language',
          })) {
            return child;
          }
          return child;
        }
        // Login and callback routes are usable surfaces in their own right.
        // They must remain visible while secure-storage hydration is pending;
        // otherwise a slow first read leaves the user on an indefinite blank
        // spinner and there is no way to start the first login.
        final isLoginRoute = path == '/login' || path.startsWith('/login/');
        final isStartupDocument = path == '/user-agreement';
        return accounts.when(
          loading: () => isSplash || isLoginRoute || isStartupDocument
              ? child
              : const _StartupProgress(),
          error: (error, stackTrace) => isLoginRoute || isStartupDocument
              ? child
              : _StartupError(error: error),
          data: (state) {
            if (state.status == AccountStatus.failure) {
              return _StartupError(
                error: state.error ?? 'unknown account error',
              );
            }
            if (state.usableCurrent == null) {
              // /user-agreement is part of the no-account flow (opened from
              // the login page). child must stay mounted while a redirect is
              // in flight: `child` is the Router itself, and swapping it for
              // a spinner detaches the Router's provider listener so the
              // scheduled go() is never consumed — a permanent deadlock.
              if (!_ensureLocation(context, const {
                '/login',
                '/login/web',
                '/login/callback',
                '/user-agreement',
              })) {
                return child;
              }
            } else if (StartupGate._isAuthFlowPath(path) &&
                StartupGate._isAuthFlowPath(StartupGate._basePath(router))) {
              // Signed-in: rescue users still sitting on an auth/onboarding
              // route or the pending splash. Every other location (branch
              // roots, /me, pushed detail and settings pages…) is a
              // legitimate place to be — a rebuild here must never navigate.
              // Login pushed over an app page is "add account": a token
              // refresh or settings write rebuilding the gate mid-OAuth
              // must leave it alone. So must a page pushed over the splash,
              // such as an image shared into a cold start.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) {
                  final latest = ref.read(settingsProvider).value ?? settings;
                  router.go(homeStartDestination(latest).rootPath);
                }
              });
              // Keep the current route painted until the redirect lands —
              // unmounting child here deadlocks the in-flight go().
              return child;
            }
            return child;
          },
        );
      },
    );
  }

  /// True when the live location is already inside one of [roots]; false
  /// (with the redirect scheduled) when the current route is stale and must
  /// not be painted.
  bool _ensureLocation(BuildContext context, Set<String> roots) {
    final router = widget.router;
    final path = StartupGate._currentPath(router);
    if (roots.any((root) => path == root || path.startsWith('$root/'))) {
      return true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) router.go(roots.first);
    });
    return false;
  }
}

/// One-shot Impeller pipeline warm-up.
///
/// The first artwork Hero flight composites a clipped + transformed image
/// layer; that exact pipeline variant is compiled lazily on first use,
/// which is why the *first* back animation visibly drops frames while later
/// ones are smooth. Painting an invisible clipped + transformed image (plus
/// `replicaTheme`'s rounded-rect [InkHighlight] overlay) for the first few
/// frames compiles those pipelines up front.
class PipelineWarmup extends StatefulWidget {
  const PipelineWarmup({super.key, required this.child});

  final Widget child;

  @override
  State<PipelineWarmup> createState() => _PipelineWarmupState();
}

class _PipelineWarmupState extends State<PipelineWarmup> {
  int _framesLeft = 3;
  bool _ticking = false;

  // 1x1 transparent PNG — enough to exercise the image pipeline variant
  // without shipping an asset.
  static final Uint8List _pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() {
    if (_ticking) return;
    _ticking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ticking = false;
      if (!mounted || _framesLeft <= 0) return;
      setState(() {
        _framesLeft--;
      });
      _tick();
    });
  }

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).highlightColor;
    return Stack(
      // The content stays the first child, laid out as without the Stack:
      // unwrapping it when the warm-up ends remounted the whole app.
      fit: StackFit.passthrough,
      children: [
        widget.child,
        // Exercises the ops the artwork Hero flights and flat press highlights
        // composite — saveLayer, transform, rect clip, rounded-rect clip,
        // translucent RRect fill, image — whose pipeline variants are compiled
        // lazily and otherwise show up on first interaction. Painted offscreen
        // (not zero-alpha: a fully transparent layer may be culled entirely
        // and compile nothing).
        if (_framesLeft > 0) ...[
          Positioned(
            left: -64,
            top: -64,
            child: RepaintBoundary(
              child: Transform.scale(
                scale: 1.001,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: highlight.a > 0
                        ? highlight
                        : const Color(0x14000000),
                    borderRadius: FuncShape.card,
                  ),
                  child: ClipRRect(
                    borderRadius: FuncShape.card,
                    child: Image.memory(
                      _pixel,
                      width: 8,
                      height: 8,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: -96,
            top: -96,
            child: ClipRect(child: Image.memory(_pixel, width: 8, height: 8)),
          ),
        ],
      ],
    );
  }
}

/// Neutral cold-start surface and the router's initial location.
///
/// Routing decisions (welcome/login/home) can only be made after settings
/// and the account store hydrate — the first frame before that used to be
/// the WelcomePage, which is the flash a signed-in user saw on cold start.
/// The splash is neutral content that hands off seamlessly once the gate
/// resolves.
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  /// Android 12+ shows the launcher icon's 72dp visible area at 160dp on the
  /// system splash. The mark asset spans that same area, so the icon stays in
  /// place when the system splash hands over to this page.
  static const double markSize = 160;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Image.asset(
          'assets/branding/parfait_icon.png',
          width: markSize,
          height: markSize,
        ),
      ),
    );
  }
}

class _StartupProgress extends StatelessWidget {
  const _StartupProgress();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: AppSpinner()));
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    String text(String key) => l10nLookup(context.l10n, key);
    return Scaffold(
      body: Center(
        // Content-width role cap (not a breakpoint) keeps the error block
        // readable on wide surfaces.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ContentWidths.form),
          child: Padding(
            padding: const EdgeInsets.all(FuncSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(UiIcons.errorOutline, size: 48),
                const SizedBox(height: FuncSpacing.lg),
                Text(text('accountReadFailed')),
                const SizedBox(height: FuncSpacing.sm),
                Text(
                  errorCategoryText(context, categorizeError(error)),
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                FailureReport(action: text('accountReadFailed'), error: error),
                CopyDiagnosticsButton(error: error),
                const SizedBox(height: FuncSpacing.lg),
                // Retry is the page's primary action — same weight as
                // FeedError's retry, not a low-emphasis text button.
                Consumer(
                  builder: (context, ref, _) => FilledButton(
                    onPressed: () =>
                        ref.read(accountStoreProvider.notifier).reload(),
                    child: Text(text('retry')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
