import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../app/accessibility/immersive_chrome_policy.dart';
import '../../app/layout/app_breakpoints.dart';
import '../../app/layout/input_modality.dart';
import '../../app/layout/window_layout_spec.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/home_shell_metrics.dart';
import '../../app/widgets/app_spinner.dart';
import '../../app/system_ui.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/bookmark_switch_button.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/window/desktop_command_bar_scope.dart'
    show DesktopCommandBarScope;
import '../../app/window/desktop_title_bar.dart' show DesktopChromeMetrics;
import '../../core/log.dart';
import '../../core/navigation/route_observer.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/reader_settings.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/context.dart';
import 'novel_bilingual.dart';
import 'novel_layout.dart';
import 'novel_reader.dart';
import 'novel_reader_footer.dart';
import 'novel_reader_series_nav.dart';
import 'novel_reader_shortcuts.dart';
import 'novel_reader_theme.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_choice_chip.dart';
import '../../app/widgets/app_slider.dart';
import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
part 'novel_reader_stage_widgets.dart';

/// How far the reader's faint text (the bottom progress hint, an image's
/// notice) fades the page's text: no further than keeps 4.5:1 on every
/// reader palette (the green one is the closest, about 5:1).
const novelReaderHintAlpha = 0.75;

/// How far the progress pill's outline fades the page's text: no further
/// than keeps 3:1 against every reader palette (the green one is the
/// closest, about 3.4:1).
@visibleForTesting
const novelReaderPillOutlineAlpha = 0.6;

/// Data seam for [NovelReaderStage]: everything that differs between the
/// online novel page and the local TXT reader is injected here, so the
/// stage itself stays source-agnostic.
class NovelReaderStageSpec {
  const NovelReaderStageSpec({
    required this.novel,
    required this.infoTooltip,
    required this.infoSheet,
    required this.progress,
    this.titleBlock,
    this.topActions = const [],
    this.onImageTap,
    this.onLinkTap,
    this.marker,
    this.bodyWrapper,
  });

  /// The document being read — a real detail entity online, a synthetic
  /// one built from the TXT file locally.
  final NovelEntity novel;

  /// Title and byline that open the first page (online only: a file has
  /// no author, and its name is not a title).
  final NovelTitleBlock? titleBlock;

  /// Extra actions rendered before the info button in the top bar
  /// (online: share + bookmark; local: none).
  final List<Widget> topActions;

  /// Opens a tapped illustration (online: the image viewer; a TXT file
  /// has none).
  final void Function(BuildContext context, NovelImageLoadRequest image)?
  onImageTap;

  /// Opens an author's link to a Pixiv address (online: as a caption link
  /// opens; a TXT file's read as text).
  final void Function(BuildContext context, Uri uri)? onLinkTap;

  /// Tooltip of the top-bar info button (`novelInfoTitle` for a work,
  /// `localNovelFileInfo` for a file).
  final String infoTooltip;

  /// Content builder for the info bottom sheet — the stage owns the
  /// `showAppBottomSheet` presentation; the spec owns the fields inside.
  final WidgetBuilder infoSheet;

  /// Reading-position persistence adapter for this data source.
  final ReaderProgressBinding progress;

  /// The account's bookmark of the novel in the progress sheet (online
  /// with an account; a file and a guest have none).
  final NovelMarkerBinding? marker;

  /// Optional wrapper around the reader body. The online page uses it to
  /// attach `HistoryVisibility` (it needs the live anchor for snapshots);
  /// local passes null — imported files never enter account history (D6).
  final Widget Function(
    BuildContext context,
    NovelAnchor? anchor,
    Widget child,
  )?
  bodyWrapper;
}

/// Two-method persistence adapter behind the stage: `load` resolves the
/// resume anchor on open, `save` records user-committed positions.
abstract interface class ReaderProgressBinding {
  /// Null means no usable record — the reader opens on the first page.
  Future<NovelAnchor?> load();

  /// Persists a user-committed anchor. Called only for
  /// [NovelAnchorCause.userTurn] notifications — layout echoes never write.
  Future<void> save(NovelAnchor anchor);
}

/// The progress sheet's view of the account's bookmark (Pixiv's marker)
/// of the novel: the marked Pixiv page and whether a change is on its way,
/// watched while the sheet is open, and the write (a null page removes it).
class NovelMarkerBinding {
  const NovelMarkerBinding({
    required this.page,
    required this.pending,
    required this.write,
  });

  final ProviderListenable<int?> page;
  final ProviderListenable<bool> pending;
  final Future<void> Function(int? page) write;
}

bool _desktopCommandBarOwnsBack(BuildContext context) {
  if (!DesktopCommandBarScope.isActiveOf(context)) return false;
  if (DesktopChromeMetrics.maybeOf(context)?.isFullScreen ?? false) {
    return false;
  }
  final controller = DesktopCommandBarScope.controllerOf(context);
  if (controller != null && controller.hidden.value) return false;
  return true;
}

/// Hides the shell rail while a novel reader route (including its initial
/// loading or error scaffold) is the current route or covered only by popups,
/// preventing a 200dp layout jump when async detail/prefs resolve.
mixin _ReaderRailSuppression<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  late final ShellRailHiddenNotifier _shellRail;
  bool _hidesRail = false;
  ModalRoute<Object?>? _route;

  void initRailSuppression() {
    _shellRail = ref.read(shellRailHiddenProvider.notifier);
  }

  /// Hides the rail while the reader is the current route or only popups
  /// (a panel, a dialog, a menu) lie over it: a popup does not drive the
  /// route below's secondary animation, a page pushed over it does, and
  /// then the rail comes back. The text keeps its width under a panel.
  void updateRailSuppression() {
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.secondaryAnimation?.removeStatusListener(_syncShellRail);
      _route = route;
      route?.secondaryAnimation?.addStatusListener(_syncShellRail);
    }
    _syncShellRail();
  }

  void _syncShellRail([AnimationStatus? _]) {
    final route = _route;
    final hidesRail =
        route != null &&
        (route.isCurrent || (route.secondaryAnimation?.isDismissed ?? true));
    if (hidesRail == _hidesRail) return;
    _hidesRail = hidesRail;
    // Providers cannot change while widgets build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _shellRail.setHidden(this, _hidesRail);
    });
  }

  void disposeRailSuppression() {
    // Providers cannot change while the tree is finalized either; release
    // after the frame (a pending hide above checks `mounted` and skips).
    _route?.secondaryAnimation?.removeStatusListener(_syncShellRail);
    final rail = _shellRail;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => rail.setHidden(this, false),
    );
  }
}

/// Status pages keep an ordinary scaffold+appbar so back navigation is
/// always reachable while the immersive stage is not mounted, and suppress
/// the shell rail from frame one so loading never shifts 200dp on resolve.
class NovelStatusScaffold extends ConsumerStatefulWidget {
  const NovelStatusScaffold({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NovelStatusScaffold> createState() =>
      _NovelStatusScaffoldState();
}

class _NovelStatusScaffoldState extends ConsumerState<NovelStatusScaffold>
    with _ReaderRailSuppression {
  @override
  void initState() {
    super.initState();
    initRailSuppression();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateRailSuppression();
  }

  @override
  void dispose() {
    disposeRailSuppression();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ownsBack = _desktopCommandBarOwnsBack(context);
    return Column(
      children: [
        if (!ownsBack)
          AppTopBar(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            automaticallyImplyLeading: false,
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

/// Immersive reader stage: the paginated body fills
/// the screen; a center tap toggles the top/bottom chrome, which slides in
/// together and stays interactive until the hide animation finishes.
/// System back closes the chrome first, then leaves the page.
class NovelReaderStage extends ConsumerStatefulWidget {
  const NovelReaderStage({super.key, required this.spec});

  final NovelReaderStageSpec spec;

  @override
  ConsumerState<NovelReaderStage> createState() => _NovelReaderStageState();
}

class _NovelReaderStageState extends ConsumerState<NovelReaderStage>
    with
        SingleTickerProviderStateMixin,
        RouteAware,
        BilingualReading,
        _ReaderRailSuppression {
  /// One controller drives both bars and the passive hint: the hint
  /// tracks the *rendered* chrome state, not the user's intent — it
  /// reappears only once the bottom bar is fully dismissed (R4).
  late final AnimationController _chrome = AnimationController(vsync: this)
    ..addStatusListener(_onChromeStatus);
  bool _chromeVisible = false;
  bool _chromeHidden = true; // == _chrome.isDismissed, cached for build
  int _activeSideSheets = 0;
  // The bars' contents, built while the chrome shows and kept as they were
  // while it is dismissed: a dismissed bar stays mounted offstage, so a
  // page turn does not rebuild it and the next reveal re-lays out only the
  // text that changed.
  Widget? _topBar;
  Widget? _bottomBar;
  final NovelReaderHandle _readerHandle = NovelReaderHandle();
  NovelAnchor? _anchor;
  int _page = 0;
  int _displayPage = 0;
  int _pageCount = 1;
  RouteObserver<ModalRoute<dynamic>>? _routeObserver;
  ModalRoute<dynamic>? _subscribedRoute;

  /// The reader subtree and what it was built from ([_buildStage]).
  Widget? _reader;
  Object? _readerInputs;

  NovelReaderSettings _settings = const NovelReaderSettings();
  NovelAnchor? _initialAnchor;
  bool _prefsReady = false;
  Object? _loadError;

  /// System-bar insets as seen with the bars shown (D1). Hiding the bars
  /// reports zero insets; reading them live would grow the body and
  /// repaginate. Each edge keeps its maximum until the screen size changes.
  EdgeInsets _stableInsets = EdgeInsets.zero;
  Size? _insetsSize;

  NovelEntity get novel => widget.spec.novel;

  @override
  NovelEntity get bilingualNovel => novel;

  @override
  NovelReaderHandle get bilingualReader => _readerHandle;

  /// The settings page needs the system bars the immersive reader hides.
  @override
  void showTranslationSettings() {
    if (!_chromeVisible) _setChromeVisible(true);
    super.showTranslationSettings();
  }

  @override
  void initState() {
    super.initState();
    // Chrome starts hidden, so the reader opens straight into immersion.
    unawaited(setSystemUiMode(SystemUiMode.immersiveSticky));
    initRailSuppression();
    unawaited(_loadPrefs());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chrome.duration = MotionTokens.resolve(context, MotionTokens.chrome);
    if (pinsImmersiveChromeForAccessibility(context) && !_chromeVisible) {
      _chromeVisible = true;
      _chromeHidden = false;
      _chrome.value = 1;
      unawaited(setSystemUiMode(SystemUiMode.edgeToEdge));
    }
    final size = MediaQuery.sizeOf(context);
    final live = MediaQuery.viewPaddingOf(context);
    final next = size == _insetsSize ? _maxEdges(_stableInsets, live) : live;
    _insetsSize = size;
    if (next != _stableInsets) _stableInsets = next;
    updateRailSuppression();
    final route = ModalRoute.of(context);
    final observer =
        RouteObserverScope.maybeOf(context) ?? replicaRouteObserver;
    if (route != _subscribedRoute || observer != _routeObserver) {
      _subscribedRoute?.secondaryAnimation?.removeStatusListener(
        _onRouteSecondaryAnimationStatus,
      );
      _routeObserver?.unsubscribe(this);
      _subscribedRoute = route;
      _routeObserver = observer;
      if (route != null) {
        observer.subscribe(this, route);
        route.secondaryAnimation?.addStatusListener(
          _onRouteSecondaryAnimationStatus,
        );
      }
    }
  }

  @override
  void didPushNext() {
    // Another page route (e.g. [[jumpuri]] destination or illustration viewer)
    // covers the reader — restore system bars so immersive mode never leaks.
    unawaited(setSystemUiMode(SystemUiMode.edgeToEdge));
  }

  @override
  void didPopNext() {
    // Returned from a covering route — re-enter immersion if chrome is hidden.
    if (!_chromeVisible) {
      unawaited(setSystemUiMode(SystemUiMode.immersiveSticky));
    }
  }

  void _onRouteSecondaryAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    // An exiting immersive route (such as ImageViewerPage) restores edgeToEdge
    // in its dispose on the frame the pop transition finishes; re-assert
    // immersiveSticky once the reader is the sole active route again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _chromeVisible) return;
      if (_subscribedRoute?.isCurrent ?? false) {
        unawaited(setSystemUiMode(SystemUiMode.immersiveSticky));
      }
    });
  }

  static EdgeInsets _maxEdges(EdgeInsets a, EdgeInsets b) => EdgeInsets.only(
    left: math.max(a.left, b.left),
    top: math.max(a.top, b.top),
    right: math.max(a.right, b.right),
    bottom: math.max(a.bottom, b.bottom),
  );

  @override
  void dispose() {
    _subscribedRoute?.secondaryAnimation?.removeStatusListener(
      _onRouteSecondaryAnimationStatus,
    );
    _routeObserver?.unsubscribe(this);
    // Leaving without a pop (route replace, go()) skips the pop callback —
    // restore the ambient bars here as the fallback. Re-setting
    // edgeToEdge is harmless when the route left through a normal pop.
    unawaited(setSystemUiMode(SystemUiMode.edgeToEdge));
    disposeRailSuppression();
    _chrome.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      final settings = await ref.read(novelReaderSettingsStoreProvider).load();
      final saved = await widget.spec.progress.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _initialAnchor = saved;
        _prefsReady = true;
      });
    } catch (error) {
      // A failed read must not leave the stage spinning forever — surface
      // the error with a retry instead of silently defaulting (the saved
      // anchor may still be there).
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  void _toggleChrome() => _setChromeVisible(!_chromeVisible);

  void _showChrome() {
    if (!_chromeVisible) _setChromeVisible(true);
  }

  void _hideChrome() {
    if (_chromeVisible) _setChromeVisible(false);
  }

  void _setChromeVisible(bool visible) {
    final effective = visible || pinsImmersiveChromeForAccessibility(context);
    setState(() => _chromeVisible = effective);
    // System bars share the chrome's visibility: immersive while hidden,
    // edge-to-edge while the bars are up.
    unawaited(
      setSystemUiMode(
        effective ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      ),
    );
    if (!MotionTokens.enabled(context)) {
      // Reduced motion: land the end state — a zeroed controller still
      // drives the hittable/dismissed boundary correctly.
      _chrome.value = effective ? 1 : 0;
    } else if (effective) {
      _chrome.forward();
    } else {
      _chrome.reverse();
    }
  }

  void _onChromeStatus(AnimationStatus status) {
    final hidden = _chrome.isDismissed;
    if (hidden != _chromeHidden) setState(() => _chromeHidden = hidden);
  }

  void _previewSettings(NovelReaderSettings next) {
    if (next == _settings) return;
    setState(() => _settings = next);
  }

  void _applySettings(NovelReaderSettings next) {
    if (next != _settings) setState(() => _settings = next);
    unawaited(_saveSettings(next));
  }

  /// Immediate write-through for the settings sheet. A failed save must
  /// be visible — silently dropping it would leave the on-screen values
  /// pretending to be persisted.
  Future<void> _saveSettings(NovelReaderSettings next) async {
    try {
      await ref.read(novelReaderSettingsStoreProvider).save(next);
    } catch (error) {
      if (mounted) {
        showAppSnackBar(context, context.l10n.novelSettingsSaveFailed);
      }
    }
  }

  void _persistAnchor(NovelAnchor anchor) {
    // Anchor writes stay fire-and-forget — a lost position is non-fatal —
    // but a broken store must still be observable. Log instead of a
    // snackbar: this fires on every page turn, so a persistently failing
    // write would spam the UI far worse than it informs.
    unawaited(
      widget.spec.progress.save(anchor).catchError((Object error, _) {
        log('novel anchor persist failed: $error');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = novelReaderPalette(_settings.theme);
    // The series bar mounts only with the chrome; a bare autoDispose
    // provider drops between reveals and refetches, and a manual
    // subscription does not keep it alive. Watching it here holds the
    // dependency for the stage's lifetime — the fetch starts at open
    // and dies with the stage.
    final seriesId = novel.seriesId;
    if (seriesId != null) {
      ref.watch(
        novelSeriesNavProvider((seriesId: seriesId, novelId: novel.id)),
      );
    }
    final readerTheme = novelReaderThemeData(
      Theme.of(context),
      palette,
      hintAlpha: novelReaderHintAlpha,
    );
    final stageForeground =
        palette.foreground ?? readerTheme.colorScheme.onSurface;
    return FuncSystemBars(
      background: palette.brightness ?? Theme.of(context).brightness,
      child: Theme(
        data: readerTheme,
        child: DefaultTextStyle.merge(
          style: TextStyle(color: stageForeground),
          child: Builder(
            builder: (stageContext) =>
                _buildThemedStage(stageContext, palette, stageForeground),
          ),
        ),
      ),
    );
  }

  Widget _buildThemedStage(
    BuildContext context,
    NovelReaderPalette palette,
    Color stageForeground,
  ) {
    final l10n = context.l10n;
    final percent = _pageCount <= 1
        ? 100
        : ((_displayPage + 1) / _pageCount * 100).round();
    final windowSpec = WindowLayoutSpec.of(context);
    final bookLeft =
        windowSpec.posture == FoldPosture.book &&
            windowSpec.hingeBounds != null &&
            windowSpec.hingeBounds!.left > 180
        ? windowSpec.hingeBounds!.left
        : null;
    final isPointer = windowSpec.inputModality == InputModality.pointer;
    final cueFg = stageForeground.withValues(alpha: novelReaderHintAlpha);
    final cueBg =
        (palette.background ??
                Theme.of(context).colorScheme.surfaceContainerHigh)
            .withValues(alpha: 0.82);
    if (!_chromeHidden) {
      _topBar = _buildTopBar(context, palette);
      _bottomBar = _buildBottomBar(context, l10n, palette);
    }
    return PopScope(
      // On iOS there is no hardware back button, so keep interactive left-edge
      // swipe-back active even while reader chrome is open (TRANS-02/NOVEL-05);
      // Android/desktop still dismiss chrome first on back/Esc.
      canPop:
          !_chromeVisible ||
          Theme.of(context).platform == TargetPlatform.iOS ||
          pinsImmersiveChromeForAccessibility(context),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          // Restore the bars as the pop starts — dispose only runs
          // after the pop animation, and the previous route needs its
          // status bar while the transition is still on screen.
          unawaited(setSystemUiMode(SystemUiMode.edgeToEdge));
        } else {
          _hideChrome();
        }
      },
      // Arrow-key paging lives on the stage's own Focus — when a sheet
      // route opens it takes the primary focus, so keys reach the sheet
      // instead of the reader without any extra guard.
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: ColoredBox(
          color:
              palette.background ?? Theme.of(context).scaffoldBackgroundColor,
          child: LayoutBuilder(
            builder: (context, stageConstraints) {
              final hintStyle = _hintStyle(context, palette);
              final stagePadding = _stableInsets.copyWith(
                bottom: novelReaderFooterReserve(
                  context,
                  hintStyle: hintStyle,
                  stableInsets: _stableInsets,
                  isPointer: isPointer,
                ),
              );
              final readerViewport = Size(
                math.max(
                  0.0,
                  stageConstraints.maxWidth - stagePadding.horizontal,
                ),
                math.max(
                  0.0,
                  stageConstraints.maxHeight - stagePadding.vertical,
                ),
              );
              final hasBookSplit =
                  bookLeft != null &&
                  windowSpec.hingeBounds != null &&
                  stageConstraints.maxWidth - windowSpec.hingeBounds!.right >=
                      180;
              final isSpread = NovelReader.shouldSpreadFor(
                viewport: readerViewport,
                settings: _settings,
                hasBookSplit: hasBookSplit,
              );
              return Stack(
                children: [
                  Positioned.fill(
                    child: _buildStage(context, palette, stagePadding),
                  ),
                  // Keep the passive progress hint (and pointer toolbar cue)
                  // inside the reserved bottom strip while chrome is dismissed.
                  if (_chromeHidden)
                    NovelReaderFooterStrip(
                      title: novel.title,
                      suffix:
                          ' · ${_displayPage + 1}/$_pageCount · $percent%'
                          '${bilingual && translatingPage ? ' · ${l10n.novelTranslating}' : ''}',
                      hintStyle: hintStyle,
                      fontSize: _settings.fontSize,
                      stableInsets: _stableInsets,
                      bookLeft: bookLeft,
                      isSpread: isSpread,
                      isPointer: isPointer,
                      cueForeground: cueFg,
                      cueBackground: cueBg,
                      showToolbarLabel: l10n.novelShowToolbar,
                      onShowChrome: _showChrome,
                    ),
                  // Dismissed bars go offstage here, on the status-driven
                  // setState frame — not inside the animation builder,
                  // where a mid-flush semantics change can trip the
                  // semantics attach assert. While a wide side sheet covers
                  // the stage, hide the floating bars so their left half
                  // never hangs orphaned under the modal scrim.
                  if (_topBar case final bar?)
                    _ChromeBar(
                      animation: _chrome,
                      edge: _ChromeEdge.top,
                      shown: !_chromeHidden && _activeSideSheets == 0,
                      child: bar,
                    ),
                  if (_bottomBar case final bar?)
                    _ChromeBar(
                      animation: _chrome,
                      edge: _ChromeEdge.bottom,
                      shown: !_chromeHidden && _activeSideSheets == 0,
                      child: bar,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) =>
      handleNovelReaderKeyEvent(
        context,
        event,
        pageTurn: _settings.pageTurn,
        readerHandle: _readerHandle,
        onToggleChrome: _toggleChrome,
        onOpenToc: () => _showProgressSheet(context),
        onToggleBookmark: novel.id > 0
            ? () => unawaited(
                toggleBookmark(
                  context,
                  BookmarkKey(BookmarkEntityType.novel, novel.id),
                ),
              )
            : null,
      );

  /// The hint's text style, shared by the rendered `Text` and the
  /// [TextPainter] that sizes the reserved band — the two must never
  /// diverge or the reserve stops matching the painted glyph height.
  TextStyle? _hintStyle(BuildContext context, NovelReaderPalette palette) =>
      Theme.of(context).textTheme.bodySmall?.copyWith(
        color: (palette.foreground ?? Theme.of(context).colorScheme.onSurface)
            .withValues(alpha: novelReaderHintAlpha),
      );

  Widget _buildStage(
    BuildContext context,
    NovelReaderPalette palette,
    EdgeInsets padding,
  ) {
    final loadError = _loadError;
    if (loadError != null) {
      return FeedError(
        title: context.l10n.settingsReadFailed,
        error: loadError,
        retryLabel: context.l10n.retry,
        scrollable: false,
        onRetry: () {
          setState(() => _loadError = null);
          unawaited(_loadPrefs());
        },
      );
    }
    // Hold the reader until prefs resolve — mounting early would lay the
    // document out twice (defaults, then the saved settings/anchor).
    if (!_prefsReady) {
      return const FeedLoading();
    }
    // The reserve depends only on the stable insets and the text scaler,
    // so chrome show/hide never repaginates (C6 R3 contract).
    final translations = pageTranslations;
    final inputs = (
      novel,
      _settings,
      _initialAnchor,
      palette.foreground,
      translations,
      widget.spec.titleBlock,
      padding,
    );
    // The same reader while its inputs hold: the chrome, the progress hint
    // and the anchor rebuild the stage on a tap and on every page turn,
    // and a new reader rebuilt every line of the pages on screen.
    if (inputs != _readerInputs) {
      _readerInputs = inputs;
      final hasSeriesStrip =
          novel.seriesId != null ||
          novel.seriesPrevId != null ||
          novel.seriesNextId != null;
      _reader = Padding(
        padding: padding,
        child: NovelReader(
          novel: novel,
          settings: _settings,
          initialAnchor: _initialAnchor,
          textColor: palette.foreground,
          translations: translations,
          titleBlock: widget.spec.titleBlock,
          scrollTopPadding: kToolbarHeight + FuncSpacing.sm,
          scrollBottomPadding:
              (hasSeriesStrip ? novelSeriesBarHeight : 0.0) +
              kMinInteractiveDimension +
              FuncSpacing.lg,
          handle: _readerHandle,
          onCenterTap: _toggleChrome,
          onImageTap: switch (widget.spec.onImageTap) {
            final open? => (image) => open(context, image),
            null => null,
          },
          onLinkTap: switch (widget.spec.onLinkTap) {
            final open? => (uri) => open(context, uri),
            null => null,
          },
          onProgressChanged: _onProgressChanged,
          onAnchorChanged: _onAnchorChanged,
        ),
      );
    }
    final content = _reader!;
    return widget.spec.bodyWrapper?.call(context, _anchor, content) ?? content;
  }

  void _onProgressChanged(int page, int pageCount) {
    final displayPage = _readerHandle.displayPage?.call() ?? page;
    if (page == _page &&
        displayPage == _displayPage &&
        pageCount == _pageCount) {
      return;
    }
    setState(() {
      _page = page;
      _displayPage = displayPage;
      _pageCount = pageCount;
    });
  }

  void _onAnchorChanged(NovelAnchor anchor, NovelAnchorCause cause) {
    if (_anchor != anchor) setState(() => _anchor = anchor);
    // D1: only a user-committed turn persists progress. Layout echoes
    // (open/restore, settings relayout) are not reads — opening and
    // closing the book leaves no record behind.
    if (cause == NovelAnchorCause.userTurn) _persistAnchor(anchor);
    bilingualPageSettled();
  }

  /// Shared fill for both chrome bars: the reading palette's background
  /// (the page surface under `system`), kept one brightness with the
  /// palette's bar-icon override. Opaque: the page lies under the bars,
  /// and text showing through a see-through bar read as a smudge behind
  /// the controls.
  Color _chromeBarColor(BuildContext context, NovelReaderPalette palette) =>
      palette.background ?? Theme.of(context).colorScheme.surface;

  Widget _buildTopBar(BuildContext context, NovelReaderPalette palette) {
    final foreground =
        palette.foreground ?? Theme.of(context).colorScheme.onSurface;
    final ownsBack = _desktopCommandBarOwnsBack(context);
    final hairline = foreground.withValues(alpha: 0.10);
    final titleText = Text(
      novel.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(color: foreground),
    );
    return Material(
      color: _chromeBarColor(context, palette),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        // The Material paints through the status-bar inset; only the
        // controls are padded below it.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: _stableInsets.copyWith(bottom: 0),
              // An AppBar's geometry: the back button in a toolbar-square
              // slot, the title one middle spacing after it; when the
              // desktop command bar already owns back navigation, skip the
              // duplicate second arrow.
              child: SizedBox(
                height: kToolbarHeight,
                child: NavigationToolbar(
                  centerMiddle: false,
                  leading: ownsBack
                      ? null
                      : SizedBox(
                          width: kToolbarHeight,
                          child: IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).backButtonTooltip,
                            // Imperative pop: the PopScope only intercepts the
                            // system back gesture (chrome-first); this control
                            // always leaves.
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const BackButtonIcon(),
                          ),
                        ),
                  middle: ownsBack
                      ? Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: FuncSpacing.lg,
                          ),
                          child: titleText,
                        )
                      : titleText,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ...widget.spec.topActions,
                      IconButton(
                        tooltip: bilingual
                            ? context.l10n.translationHide
                            : context.l10n.novelTranslatePage,
                        isSelected: bilingual,
                        onPressed: toggleBilingual,
                        icon: const Icon(AppIcons.translate),
                        selectedIcon: translatingPage
                            ? AppSpinner(
                                size: 20,
                                strokeWidth: 2,
                                color: foreground,
                              )
                            : Icon(
                                AppIcons.translate,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                      ),
                      IconButton(
                        tooltip: widget.spec.infoTooltip,
                        onPressed: () => _showInfoSheet(context),
                        icon: const Icon(AppIcons.info),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ColoredBox(
              color: hairline,
              child: const SizedBox(width: double.infinity, height: 1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    AppLocalizations l10n,
    NovelReaderPalette palette,
  ) {
    final percent = _pageCount <= 1
        ? 100
        : ((_displayPage + 1) / _pageCount * 100);
    final foreground =
        palette.foreground ?? Theme.of(context).colorScheme.onSurface;
    final hairline = foreground.withValues(alpha: 0.10);
    return Material(
      color: _chromeBarColor(context, palette),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        // The Material paints through the gesture-strip inset; only the
        // controls are padded above it.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredBox(
              color: hairline,
              child: const SizedBox(width: double.infinity, height: 1),
            ),
            Padding(
              padding: _stableInsets.copyWith(top: 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (novel.seriesId != null)
                    NovelSeriesBar(
                      seriesId: novel.seriesId!,
                      novelId: novel.id,
                      fallbackPrevId: novel.seriesPrevId,
                      fallbackNextId: novel.seriesNextId,
                    )
                  else if (novel.seriesPrevId != null ||
                      novel.seriesNextId != null)
                    NovelAdjacentBar(
                      prevId: novel.seriesPrevId,
                      nextId: novel.seriesNextId,
                    ),
                  // The readout sits on the bar's centre line, whatever the
                  // controls on either side.
                  SizedBox(
                    height: kMinInteractiveDimension,
                    child: NavigationToolbar(
                      middleSpacing: 0,
                      leading: IconButton(
                        tooltip: l10n.novelDecreaseFont,
                        onPressed: () => _applySettings(
                          _settings.copyWith(fontSize: _settings.fontSize - 1),
                        ),
                        icon: const Icon(AppIcons.textDecrease),
                      ),
                      // A pill with an expand glyph: it opens the progress
                      // sheet. The readout keeps its a11y label so screen
                      // readers announce the progress control, not a number.
                      middle: OutlinedButton.icon(
                        onPressed: () => _showProgressSheet(context),
                        iconAlignment: IconAlignment.end,
                        icon: const Icon(UiIcons.expandLess),
                        label: Text(
                          '${_displayPage + 1}/$_pageCount · ${percent.round()}%',
                          semanticsLabel: l10n.novelReadingProgress,
                          maxLines: 1,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.tabular,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: foreground,
                          side: BorderSide(
                            color: foreground.withValues(
                              alpha: novelReaderPillOutlineAlpha,
                            ),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: l10n.novelIncreaseFont,
                            onPressed: () => _applySettings(
                              _settings.copyWith(
                                fontSize: _settings.fontSize + 1,
                              ),
                            ),
                            icon: const Icon(AppIcons.textIncrease),
                          ),
                          Builder(
                            builder: (anchorContext) => IconButton(
                              tooltip: l10n.novelReaderSettings,
                              onPressed: () =>
                                  _showReaderSettings(anchorContext),
                              icon: const Icon(AppIcons.filter),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Reader sheets keep the app theme's colors (not the reading palette),
  /// so the sheet publishes its own [FuncSystemBars] region: the nav bar
  /// under it takes icon brightness from the sheet's theme brightness,
  /// not from the stage behind it.
  void _showReaderSideSheet({
    required WidgetBuilder builder,
    bool isScrollControlled = false,
  }) {
    final wide = useWideOverlay(context);
    if (wide) setState(() => _activeSideSheets += 1);
    unawaited(
      showAppAdaptiveSideSheet<void>(
        context: context,
        isScrollControlled: isScrollControlled,
        showDragHandle: !wide,
        builder: (sheetContext) => FuncSystemBars(
          background: Theme.of(sheetContext).brightness,
          child: builder(sheetContext),
        ),
      ).whenComplete(() {
        if (wide && mounted) {
          setState(
            () => _activeSideSheets = math.max(0, _activeSideSheets - 1),
          );
        }
      }),
    );
  }

  void _showReaderSettingsPopover({
    required BuildContext anchorContext,
    required WidgetBuilder builder,
  }) {
    unawaited(
      showAppAdaptivePopover<void>(
        context: context,
        anchorContext: anchorContext,
        minWidth: 320,
        maxWidth: 380,
        maxHeight: 520,
        showDragHandle: true,
        builder: (sheetContext) => FuncSystemBars(
          background: Theme.of(sheetContext).brightness,
          child: builder(sheetContext),
        ),
      ),
    );
  }

  void _showInfoSheet(BuildContext context) {
    final title = widget.spec.infoTooltip;
    _showReaderSideSheet(
      isScrollControlled: true,
      builder: (sheetContext) {
        if (!useWideOverlay(sheetContext)) {
          return widget.spec.infoSheet(sheetContext);
        }
        return SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  FuncSpacing.xl,
                  FuncSpacing.lg,
                  FuncSpacing.md,
                  FuncSpacing.xs,
                ),
                child: _ReaderSheetHeader(
                  title: title,
                  onClose: () => Navigator.of(sheetContext).pop(),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: MediaQuery.removePadding(
                  context: sheetContext,
                  removeTop: true,
                  child: widget.spec.infoSheet(sheetContext),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
