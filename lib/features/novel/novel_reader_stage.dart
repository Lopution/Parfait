import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../app/layout/app_breakpoints.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/home_shell_metrics.dart';
import '../../app/navigation/routes.dart';
import '../../app/system_ui.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/watchlist_toggle.dart';
import '../../core/auth/account_store.dart';
import '../../core/errors/no_retry.dart';
import '../../core/log.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/novel/reader_settings.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/context.dart';
import 'novel_bilingual.dart';
import 'novel_layout.dart';
import 'novel_reader.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_choice_chip.dart';
import '../../app/widgets/app_slider.dart';
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

/// Status pages keep an ordinary scaffold+appbar so back navigation is
/// always reachable while the immersive stage is not mounted. Shared by
/// the online and local reader pages.
class NovelStatusScaffold extends StatelessWidget {
  const NovelStatusScaffold({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: MediaQuery.of(context).padding.copyWith(bottom: 0),
          child: Align(
            alignment: Alignment.centerLeft,
            // An explicit control means "leave the page"; only the system
            // back gesture goes through the chrome-first interception.
            child: BackButton(onPressed: () => Navigator.of(context).pop()),
          ),
        ),
        Expanded(child: child),
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
    with SingleTickerProviderStateMixin, BilingualReading {
  /// One controller drives both bars and the passive hint: the hint
  /// tracks the *rendered* chrome state, not the user's intent — it
  /// reappears only once the bottom bar is fully dismissed (R4).
  late final AnimationController _chrome = AnimationController(vsync: this)
    ..addStatusListener(_onChromeStatus);
  bool _chromeVisible = false;
  bool _chromeHidden = true; // == _chrome.isDismissed, cached for build
  // The bars' contents, built while the chrome shows and kept as they were
  // while it is dismissed: a dismissed bar stays mounted offstage, so a
  // page turn does not rebuild it and the next reveal re-lays out only the
  // text that changed.
  Widget? _topBar;
  Widget? _bottomBar;
  final NovelReaderHandle _readerHandle = NovelReaderHandle();
  NovelAnchor? _anchor;
  int _page = 0;
  int _pageCount = 1;

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

  /// Reading takes the whole window: on rail layouts the shell's rail
  /// steps aside while this route is the current one or under a popup
  /// ([_syncShellRail]).
  late final ShellRailHiddenNotifier _shellRail;
  bool _hidesRail = false;
  ModalRoute<Object?>? _route;

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
    _shellRail = ref.read(shellRailHiddenProvider.notifier);
    unawaited(_loadPrefs());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chrome.duration = MotionTokens.resolve(context, MotionTokens.chrome);
    final size = MediaQuery.sizeOf(context);
    final live = MediaQuery.viewPaddingOf(context);
    final next = size == _insetsSize ? _maxEdges(_stableInsets, live) : live;
    _insetsSize = size;
    if (next != _stableInsets) _stableInsets = next;
    final route = ModalRoute.of(context);
    if (route != _route) {
      _route?.secondaryAnimation?.removeStatusListener(_syncShellRail);
      _route = route;
      route?.secondaryAnimation?.addStatusListener(_syncShellRail);
    }
    _syncShellRail();
  }

  /// Hides the rail while the reader is the current route or only popups
  /// (a panel, a dialog, a menu) lie over it: a popup does not drive the
  /// route below's secondary animation, a page pushed over it does, and
  /// then the rail comes back. The text keeps its width under a panel.
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

  static EdgeInsets _maxEdges(EdgeInsets a, EdgeInsets b) => EdgeInsets.only(
    left: math.max(a.left, b.left),
    top: math.max(a.top, b.top),
    right: math.max(a.right, b.right),
    bottom: math.max(a.bottom, b.bottom),
  );

  @override
  void dispose() {
    // Leaving without a pop (route replace, go()) skips the pop callback —
    // restore the ambient bars here as the fallback. Re-setting
    // edgeToEdge is harmless when the route left through a normal pop.
    unawaited(setSystemUiMode(SystemUiMode.edgeToEdge));
    // Providers cannot change while the tree is finalized either; release
    // after the frame (a pending hide above checks `mounted` and skips).
    _route?.secondaryAnimation?.removeStatusListener(_syncShellRail);
    final rail = _shellRail;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => rail.setHidden(this, false),
    );
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

  void _hideChrome() {
    if (_chromeVisible) _setChromeVisible(false);
  }

  void _setChromeVisible(bool visible) {
    setState(() => _chromeVisible = visible);
    // System bars share the chrome's visibility: immersive while hidden,
    // edge-to-edge while the bars are up.
    unawaited(
      setSystemUiMode(
        visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      ),
    );
    if (!MotionTokens.enabled(context)) {
      // Reduced motion: land the end state — a zeroed controller still
      // drives the hittable/dismissed boundary correctly.
      _chrome.value = visible ? 1 : 0;
    } else if (visible) {
      _chrome.forward();
    } else {
      _chrome.reverse();
    }
  }

  void _onChromeStatus(AnimationStatus status) {
    final hidden = _chrome.isDismissed;
    if (hidden != _chromeHidden) setState(() => _chromeHidden = hidden);
  }

  void _applySettings(NovelReaderSettings next) {
    setState(() => _settings = next);
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
    final l10n = context.l10n;
    final palette = novelReaderPalette(_settings.theme);
    final percent = _pageCount <= 1
        ? 100
        : ((_page + 1) / _pageCount * 100).round();
    // The series bar mounts only with the chrome; a bare autoDispose
    // provider drops between reveals and refetches, and a manual
    // subscription does not keep it alive. Watching it here holds the
    // dependency for the stage's lifetime — the fetch starts at open
    // and dies with the stage.
    final seriesId = novel.seriesId;
    if (seriesId != null) {
      ref.watch(_novelSeriesProvider(seriesId));
    }
    if (!_chromeHidden) {
      _topBar = _buildTopBar(context, palette);
      _bottomBar = _buildBottomBar(context, l10n, palette);
    }
    // Bar icons invert off the reading surface: paper/sepia pin dark
    // icons, night pins light ones; `system` follows the app theme. The
    // stage fills the screen, so this region owns both bars while it is
    // mounted and the root style returns on unmount (C2 contract).
    return FuncSystemBars(
      background: palette.brightness ?? Theme.of(context).brightness,
      child: PopScope(
        canPop: !_chromeVisible,
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
            child: Stack(
              children: [
                Positioned.fill(child: _buildStage(context, palette)),
                // Keep the passive progress hint out of the bottom chrome's
                // paint and semantics tree. The chrome owns the interactive
                // progress readout while it is visible; the hint returns when
                // the reader is immersive again.
                // It starts on the body text's edge: the same centred
                // article column the page's lines fill (R4).
                if (_chromeHidden)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 4 + _stableInsets.bottom,
                    child: IgnorePointer(
                      child: Padding(
                        padding: EdgeInsetsDirectional.only(
                          start: _stableInsets.left,
                          end: _stableInsets.right,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final style = NovelLayoutStyle(
                              fontSize: _settings.fontSize,
                            );
                            final width = style.contentWidth(
                              availableWidth: constraints.maxWidth,
                              textScaler: MediaQuery.textScalerOf(context),
                            );
                            return Center(
                              child: SizedBox(
                                width: width,
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: style.horizontalPadding,
                                  ),
                                  child: Text(
                                    '${novel.title} · ${_page + 1}/$_pageCount · $percent%'
                                    '${bilingual && translatingPage ? ' · ${l10n.novelTranslating}' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: _hintStyle(context, palette),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                // Dismissed bars go offstage here, on the status-driven
                // setState frame — not inside the animation builder,
                // where a mid-flush semantics change can trip the
                // semantics attach assert.
                if (_topBar case final bar?)
                  _ChromeBar(
                    animation: _chrome,
                    edge: _ChromeEdge.top,
                    shown: !_chromeHidden,
                    child: bar,
                  ),
                if (_bottomBar case final bar?)
                  _ChromeBar(
                    animation: _chrome,
                    edge: _ChromeEdge.bottom,
                    shown: !_chromeHidden,
                    child: bar,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static bool _isEditingFocused() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  /// Keyboard navigation: arrow keys, PageUp/PageDown, and Space/Shift+Space
  /// scroll in scroll mode or turn pages/spreads in page mode when not editing
  /// text or covered by an overlay route.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_isEditingFocused()) return KeyEventResult.ignored;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (_settings.pageTurn == NovelPageTurn.scroll) {
      final viewport = _readerHandle.viewportHeight?.call() ?? 480;
      const lineStep = 72.0;
      final pageStep = math.max(lineStep, viewport * 0.85);
      final double? delta;
      if (!shift && key == LogicalKeyboardKey.arrowDown) {
        delta = lineStep;
      } else if (!shift && key == LogicalKeyboardKey.arrowUp) {
        delta = -lineStep;
      } else if (key == LogicalKeyboardKey.pageDown ||
          (!shift && key == LogicalKeyboardKey.space)) {
        delta = pageStep;
      } else if (key == LogicalKeyboardKey.pageUp ||
          (shift && key == LogicalKeyboardKey.space)) {
        delta = -pageStep;
      } else {
        delta = null;
      }
      if (delta != null) {
        _readerHandle.scrollBy?.call(delta, animate: event is KeyDownEvent);
        return KeyEventResult.handled;
      }
    }

    final int? step;
    if (!shift &&
        (key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowDown)) {
      step = 1;
    } else if (!shift &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowUp)) {
      step = -1;
    } else if (key == LogicalKeyboardKey.pageDown ||
        (!shift && key == LogicalKeyboardKey.space)) {
      step = 1;
    } else if (key == LogicalKeyboardKey.pageUp ||
        (shift && key == LogicalKeyboardKey.space)) {
      step = -1;
    } else {
      step = null;
    }
    if (step == null) return KeyEventResult.ignored;
    if (_readerHandle.pageCount?.call() == null) return KeyEventResult.ignored;
    _readerHandle.stepPage?.call(step);
    return KeyEventResult.handled;
  }

  /// The hint's text style, shared by the rendered `Text` and the
  /// [TextPainter] that sizes the reserved band — the two must never
  /// diverge or the reserve stops matching the painted glyph height.
  TextStyle? _hintStyle(BuildContext context, NovelReaderPalette palette) =>
      Theme.of(context).textTheme.bodySmall?.copyWith(
        color: (palette.foreground ?? Theme.of(context).colorScheme.onSurface)
            .withValues(alpha: novelReaderHintAlpha),
      );

  /// Bottom padding that keeps the last body line clear of the progress
  /// hint. The hint hangs `4dp` above the (stable) bottom inset, so the
  /// body must yield the inset itself plus whatever part of the hint band
  /// is not already covered by the layout's bottom whitespace.
  double _hintReserve(BuildContext context, NovelReaderPalette palette) {
    final painter = TextPainter(
      text: TextSpan(text: '0', style: _hintStyle(context, palette)),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final hintBand = 4 + painter.height;
    painter.dispose();
    return _stableInsets.bottom +
        math.max(0, hintBand - const NovelLayoutStyle().verticalPadding);
  }

  Widget _buildStage(BuildContext context, NovelReaderPalette palette) {
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
    final padding = _stableInsets.copyWith(
      bottom: _hintReserve(context, palette),
    );
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
      _reader = Padding(
        padding: padding,
        child: NovelReader(
          novel: novel,
          settings: _settings,
          initialAnchor: _initialAnchor,
          textColor: palette.foreground,
          translations: translations,
          titleBlock: widget.spec.titleBlock,
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
    if (page == _page && pageCount == _pageCount) return;
    setState(() {
      _page = page;
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
    return Material(
      color: _chromeBarColor(context, palette),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        // The Material paints through the status-bar inset; only the
        // controls are padded below it.
        child: Padding(
          padding: _stableInsets.copyWith(bottom: 0),
          // An AppBar's geometry: the back button in a toolbar-square
          // slot, the title one middle spacing after it.
          child: SizedBox(
            height: kToolbarHeight,
            child: NavigationToolbar(
              centerMiddle: false,
              leading: SizedBox(
                width: kToolbarHeight,
                child: IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  // Imperative pop: the PopScope only intercepts the system
                  // back gesture (chrome-first); this control always leaves.
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
              middle: Text(
                novel.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: foreground),
              ),
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
                    icon: const Icon(Icons.translate),
                    selectedIcon: translatingPage
                        ? SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: foreground,
                            ),
                          )
                        : Icon(
                            Icons.translate,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                  ),
                  IconButton(
                    tooltip: widget.spec.infoTooltip,
                    onPressed: () => _showInfoSheet(context),
                    icon: const Icon(Icons.info_outline),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(
    BuildContext context,
    AppLocalizations l10n,
    NovelReaderPalette palette,
  ) {
    final percent = _pageCount <= 1 ? 100 : ((_page + 1) / _pageCount * 100);
    final foreground =
        palette.foreground ?? Theme.of(context).colorScheme.onSurface;
    return Material(
      color: _chromeBarColor(context, palette),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        // The Material paints through the gesture-strip inset; only the
        // controls are padded above it.
        child: Padding(
          padding: _stableInsets.copyWith(top: 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (novel.seriesId != null)
                _NovelSeriesBar(seriesId: novel.seriesId!, novelId: novel.id)
              else if (novel.seriesPrevId != null || novel.seriesNextId != null)
                _NovelAdjacentBar(
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
                    icon: const Icon(Icons.text_decrease_outlined),
                  ),
                  // A pill with an expand glyph: it opens the progress
                  // sheet. The readout keeps its a11y label so screen
                  // readers announce the progress control, not a number.
                  middle: OutlinedButton.icon(
                    onPressed: () => _showProgressSheet(context),
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.expand_less),
                    label: Text(
                      '${_page + 1}/$_pageCount · ${percent.round()}%',
                      semanticsLabel: l10n.novelReadingProgress,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.bodyMedium?.tabular,
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
                          _settings.copyWith(fontSize: _settings.fontSize + 1),
                        ),
                        icon: const Icon(Icons.text_increase_outlined),
                      ),
                      Builder(
                        builder: (anchorContext) => IconButton(
                          tooltip: l10n.novelReaderSettings,
                          onPressed: () => _showReaderSettings(anchorContext),
                          icon: const Icon(Icons.tune_outlined),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
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
    unawaited(
      showAppAdaptiveSideSheet<void>(
        context: context,
        isScrollControlled: isScrollControlled,
        showDragHandle: true,
        builder: (sheetContext) => FuncSystemBars(
          background: Theme.of(sheetContext).brightness,
          child: builder(sheetContext),
        ),
      ),
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
    _showReaderSideSheet(
      isScrollControlled: true,
      builder: widget.spec.infoSheet,
    );
  }
}
