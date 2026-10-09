import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/routes.dart';
import '../../app/system_ui.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/watchlist_toggle.dart';
import '../../core/auth/account_store.dart';
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

/// Data seam for [NovelReaderStage]: everything that differs between the
/// online novel page and the local TXT reader is injected here, so the
/// stage itself stays source-agnostic.
class NovelReaderStageSpec {
  const NovelReaderStageSpec({
    required this.novel,
    required this.infoTooltip,
    required this.infoSheet,
    required this.progress,
    this.topActions = const [],
    this.bodyWrapper,
  });

  /// The document being read — a real detail entity online, a synthetic
  /// one built from the TXT file locally.
  final NovelEntity novel;

  /// Extra actions rendered before the info button in the top bar
  /// (online: share + bookmark; local: none).
  final List<Widget> topActions;

  /// Tooltip of the top-bar info button (`novelInfoTitle` for a work,
  /// `localNovelFileInfo` for a file).
  final String infoTooltip;

  /// Content builder for the info bottom sheet — the stage owns the
  /// `showAppBottomSheet` presentation; the spec owns the fields inside.
  final WidgetBuilder infoSheet;

  /// Reading-position persistence adapter for this data source.
  final ReaderProgressBinding progress;

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
  final NovelReaderHandle _readerHandle = NovelReaderHandle();
  NovelAnchor? _anchor;
  int _page = 0;
  int _pageCount = 1;

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
    _loadPrefs();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _chrome.duration = MotionTokens.resolve(context, MotionTokens.fast);
    final size = MediaQuery.sizeOf(context);
    final live = MediaQuery.of(context).viewPadding;
    final next = size == _insetsSize ? _maxEdges(_stableInsets, live) : live;
    _insetsSize = size;
    if (next != _stableInsets) _stableInsets = next;
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
                if (_chromeHidden)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 4 + _stableInsets.bottom,
                    child: IgnorePointer(
                      child: Text(
                        '${novel.title} · ${_page + 1}/$_pageCount · $percent%'
                        '${bilingual && translatingPage ? ' · ${l10n.novelTranslating}' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _hintStyle(context, palette),
                      ),
                    ),
                  ),
                // Dismissed bars are removed here, on the status-driven
                // setState frame — not inside the animation builder,
                // where mid-flush reparenting can trip the semantics
                // attach assert.
                if (!_chromeHidden)
                  _ChromeBar(
                    animation: _chrome,
                    edge: _ChromeEdge.top,
                    child: _buildTopBar(context, palette),
                  ),
                if (!_chromeHidden)
                  _ChromeBar(
                    animation: _chrome,
                    edge: _ChromeEdge.bottom,
                    child: _buildBottomBar(context, l10n, palette),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// ←/→ turn the page. The handle reports the live position, so the key
  /// path shares the same clamp and user-turn semantics as the tap zones.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final current = _readerHandle.currentPage?.call();
    final count = _readerHandle.pageCount?.call();
    if (current == null || count == null) return KeyEventResult.ignored;
    final next = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => current - 1,
      LogicalKeyboardKey.arrowRight => current + 1,
      _ => null,
    };
    if (next == null) return KeyEventResult.ignored;
    if (next < 0 || next >= count) return KeyEventResult.handled;
    _readerHandle.goToPage?.call(next);
    return KeyEventResult.handled;
  }

  /// The hint's text style, shared by the rendered `Text` and the
  /// [TextPainter] that sizes the reserved band — the two must never
  /// diverge or the reserve stops matching the painted glyph height.
  TextStyle? _hintStyle(BuildContext context, NovelReaderPalette palette) =>
      Theme.of(context).textTheme.bodySmall?.copyWith(
        fontSize: 11,
        color: (palette.foreground ?? Theme.of(context).colorScheme.onSurface)
            .withValues(alpha: 0.45),
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
    final content = Padding(
      // The reserve depends only on the stable insets and the text scaler,
      // so chrome show/hide never repaginates (C6 R3 contract).
      padding: _stableInsets.copyWith(bottom: _hintReserve(context, palette)),
      child: NovelReader(
        novel: novel,
        settings: _settings,
        initialAnchor: _initialAnchor,
        textColor: palette.foreground,
        translations: pageTranslations,
        handle: _readerHandle,
        onCenterTap: _toggleChrome,
        onProgressChanged: (page, pageCount) {
          if (page == _page && pageCount == _pageCount) return;
          setState(() {
            _page = page;
            _pageCount = pageCount;
          });
        },
        onAnchorChanged: (anchor, cause) {
          if (_anchor != anchor) setState(() => _anchor = anchor);
          // D1: only a user-committed turn persists progress. Layout
          // echoes (open/restore, settings relayout) are not reads —
          // opening and closing the book leaves no record behind.
          if (cause == NovelAnchorCause.userTurn) _persistAnchor(anchor);
          bilingualPageSettled();
        },
      ),
    );
    return widget.spec.bodyWrapper?.call(context, _anchor, content) ?? content;
  }

  /// Shared fill for both chrome bars: the reading palette's background
  /// (the page surface under `system`) at 0.96 alpha — a tinted glass over
  /// the body, kept one brightness with the palette's bar-icon override.
  Color _chromeBarColor(BuildContext context, NovelReaderPalette palette) =>
      (palette.background ?? Theme.of(context).colorScheme.surface).withValues(
        alpha: 0.96,
      );

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
          child: Row(
            children: [
              IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                // Imperative pop: the PopScope only intercepts the system
                // back gesture (chrome-first); this control always leaves.
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  novel.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: foreground),
                ),
              ),
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
              Row(
                children: [
                  IconButton(
                    tooltip: l10n.novelDecreaseFont,
                    onPressed: () => _applySettings(
                      _settings.copyWith(fontSize: _settings.fontSize - 1),
                    ),
                    icon: const Icon(Icons.text_decrease_outlined),
                  ),
                  Expanded(
                    // Tap opens the progress/TOC sheet — the readout keeps
                    // its a11y label so screen readers announce it as the
                    // progress control, not a bare number.
                    child: InkWell(
                      onTap: () => _showProgressSheet(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: FuncSpacing.md,
                        ),
                        child: Text(
                          '${_page + 1}/$_pageCount · ${percent.round()}%',
                          textAlign: TextAlign.center,
                          semanticsLabel: l10n.novelReadingProgress,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: foreground)
                              .tabular,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.novelIncreaseFont,
                    onPressed: () => _applySettings(
                      _settings.copyWith(fontSize: _settings.fontSize + 1),
                    ),
                    icon: const Icon(Icons.text_increase_outlined),
                  ),
                  IconButton(
                    tooltip: l10n.novelReaderSettings,
                    onPressed: () => _showReaderSettings(context),
                    icon: const Icon(Icons.tune_outlined),
                  ),
                ],
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
  Future<T?> _showReaderSheet<T>({
    required WidgetBuilder builder,
    bool isScrollControlled = false,
  }) {
    return showAppBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      showDragHandle: true,
      builder: (sheetContext) => FuncSystemBars(
        background: Theme.of(sheetContext).brightness,
        child: builder(sheetContext),
      ),
    );
  }

  void _showInfoSheet(BuildContext context) {
    _showReaderSheet<void>(
      isScrollControlled: true,
      builder: widget.spec.infoSheet,
    );
  }

  /// Page-jump sheet: the slider only moves a local preview — the reader
  /// stays put until confirm, so a cancelled drag never rewinds the user.
  /// Chapter rows jump immediately on tap (D2/D4).
  void _showProgressSheet(BuildContext context) {
    final l10n = context.l10n;
    final pageCount = _pageCount;
    final chapters = _readerHandle.chapters?.call() ?? const [];
    var preview = _page;
    _showReaderSheet<void>(
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            // Same formula as the footer/bottom-bar readout — the sheet
            // and the bar must report the same percent for the same
            // page, not position-over-range.
            final percent = pageCount <= 1
                ? 100
                : ((preview + 1) / pageCount * 100).round();
            void jumpTo(int page) {
              Navigator.of(sheetContext).pop();
              _readerHandle.goToPage?.call(page, animate: false);
            }

            return Padding(
              padding: MediaQuery.of(context).padding,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  FuncSpacing.xl,
                  0,
                  FuncSpacing.xl,
                  FuncSpacing.xl,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.novelReadingProgress,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: AppSlider(
                            value: preview.toDouble().clamp(
                              0.0,
                              (pageCount - 1).toDouble(),
                            ),
                            min: 0,
                            max: (pageCount - 1).toDouble(),
                            onChanged: pageCount <= 1
                                ? null
                                : (v) =>
                                      setSheetState(() => preview = v.round()),
                          ),
                        ),
                        SizedBox(
                          width: 88,
                          child: Text(
                            '${preview + 1}/$pageCount · $percent%',
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: Text(l10n.cancel),
                        ),
                        const SizedBox(width: FuncSpacing.sm),
                        FilledButton(
                          onPressed: () => jumpTo(preview),
                          child: Text(l10n.confirm),
                        ),
                      ],
                    ),
                    // D4: the TOC section only exists when the document
                    // actually has chapters — local TXT files never do.
                    if (chapters.isNotEmpty) ...[
                      const SizedBox(height: FuncSpacing.sm),
                      const Divider(),
                      const SizedBox(height: FuncSpacing.sm),
                      Text(
                        l10n.novelChapters,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: FuncSpacing.xs),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.builder(
                          shrinkWrap: true,
                          primary: false,
                          itemCount: chapters.length,
                          itemBuilder: (context, index) {
                            final chapter = chapters[index];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                chapter.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(
                                '${chapter.pageIndex + 1}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              onTap: () => jumpTo(chapter.pageIndex),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showReaderSettings(BuildContext context) {
    final l10n = context.l10n;
    _showReaderSheet<void>(
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void apply(NovelReaderSettings next) {
              setSheetState(() {});
              _applySettings(next);
            }

            return Padding(
              padding: MediaQuery.of(context).padding,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  FuncSpacing.xl,
                  0,
                  FuncSpacing.xl,
                  FuncSpacing.xl,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SettingsSliderRow(
                      label: l10n.novelFontSize,
                      value: _settings.fontSize,
                      min: NovelReaderSettings.minFontSize,
                      max: NovelReaderSettings.maxFontSize,
                      onChanged: (v) => apply(_settings.copyWith(fontSize: v)),
                    ),
                    // Slider range == the model's clamp range (1.3–2.4):
                    // the old 1.1–2.2 span was a dead zone at the bottom
                    // and unreachable at the top.
                    _SettingsSliderRow(
                      label: l10n.novelLineHeight,
                      value: _settings.lineHeight,
                      min: NovelReaderSettings.minLineHeight,
                      max: NovelReaderSettings.maxLineHeight,
                      divisions: 11,
                      onChanged: (v) =>
                          apply(_settings.copyWith(lineHeight: v)),
                    ),
                    const SizedBox(height: FuncSpacing.md),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final (theme, label) in [
                          (NovelReaderTheme.system, l10n.novelThemeSystem),
                          (NovelReaderTheme.paper, l10n.novelThemePaper),
                          (NovelReaderTheme.sepia, l10n.novelThemeSepia),
                          (NovelReaderTheme.night, l10n.novelThemeNight),
                        ])
                          AppChoiceChip(
                            label: Text(label),
                            selected: _settings.theme == theme,
                            onSelected: () =>
                                apply(_settings.copyWith(theme: theme)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// One labelled slider row inside the reader settings sheet: each
/// typography knob maps to a continuous slider.
class _SettingsSliderRow extends StatelessWidget {
  const _SettingsSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Expanded(
          child: AppSlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1),
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

enum _ChromeEdge { top, bottom }

/// One sliding chrome bar driven by the stage's controller. The bar stays
/// hittable until the hide animation fully completes — a tap landing
/// mid-slide still hits the button instead of leaking through to the
/// page-turn zone.
class _ChromeBar extends StatelessWidget {
  const _ChromeBar({
    required this.animation,
    required this.edge,
    required this.child,
  });

  final Animation<double> animation;
  final _ChromeEdge edge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isTop = edge == _ChromeEdge.top;
    final slide =
        Tween<Offset>(
          begin: Offset(0, isTop ? -1 : 1),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: animation, curve: MotionTokens.fastCurve),
        );
    // No SafeArea here: the bar surface must paint edge-to-edge so its
    // background covers the system inset. The inset padding lives inside
    // each bar's Material instead — the bar slides from the screen edge
    // while its controls stay clear of the gesture strip.
    final bar = SlideTransition(position: slide, child: child);
    return Positioned(
      top: isTop ? 0 : null,
      bottom: isTop ? null : 0,
      left: 0,
      right: 0,
      // RenderOpacity drops the child's semantics below full opacity;
      // the boundary flipping on each animation frame trips the
      // semantics attach assert during repeated hide/reveal cycles.
      // Pinning the boundary keeps one stable semantics parent — the
      // dismissed bar is still removed from the tree by the stage.
      child: FadeTransition(
        opacity: animation,
        alwaysIncludeSemantics: true,
        child: bar,
      ),
    );
  }
}

/// Opens the JSON Novel detail route.
void _showNovelPage(BuildContext context, int novelId) {
  if (novelId <= 0) {
    showAppSnackBar(context, context.l10n.novelNotFound);
    return;
  }
  openNovel(context, novelId);
}

// Riverpod's default retry would re-run the failed fetch on a backoff
// and silently turn the error strip into data — the contract wants the
// failure to stay until the user taps retry, so auto-retry is off.
final _novelSeriesProvider = FutureProvider.autoDispose
    .family<NovelSeriesPage, int>((ref, seriesId) async {
      final token = CancelToken();
      ref.onDispose(token.cancel);
      try {
        return await ref
            .read(novelRepositoryProvider)
            .fetchSeries(seriesId, cancelToken: token);
      } catch (error) {
        // The bar shows only the localized fallback; the real error goes
        // to the log once, here at the fetch boundary — never inside
        // build, which would re-log on every rebuild.
        log('novel series $seriesId failed: $error');
        rethrow;
      }
    }, retry: (_, _) => null);

/// Fixed strip height shared by every series-bar state — an
/// [IconButton]'s minimum hit target. Loading, failure, missing-entry and
/// data never resize the strip under the bottom chrome.
const _seriesBarHeight = 48.0;

/// One fixed-height series row: prev/next chevrons at the edges, centered
/// content, an optional trailing control (watchlist, retry) beside next.
/// All series-bar states share it so layout never shifts between them.
class _SeriesBarRow extends StatelessWidget {
  const _SeriesBarRow({
    this.onPrevious,
    this.onNext,
    this.center,
    this.trailing,
  });

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final Widget? center;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _seriesBarHeight,
      child: Row(
        children: [
          IconButton(
            tooltip: context.l10n.novelPrevious,
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(child: center ?? const SizedBox.shrink()),
          ?trailing,
          IconButton(
            tooltip: context.l10n.novelNext,
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

/// Prev/next navigation supplied by the webview payload when the detail
/// metadata carries no `series` object of its own.
class _NovelAdjacentBar extends StatelessWidget {
  const _NovelAdjacentBar({required this.prevId, required this.nextId});

  final int? prevId;
  final int? nextId;

  @override
  Widget build(BuildContext context) {
    return _SeriesBarRow(
      onPrevious: prevId == null
          ? null
          : () => _showNovelPage(context, prevId!),
      onNext: nextId == null ? null : () => _showNovelPage(context, nextId!),
      center: Text(
        context.l10n.novelSeries,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _NovelSeriesBar extends ConsumerStatefulWidget {
  const _NovelSeriesBar({required this.seriesId, required this.novelId});

  final int seriesId;
  final int novelId;

  @override
  ConsumerState<_NovelSeriesBar> createState() => _NovelSeriesBarState();
}

class _NovelSeriesBarState extends ConsumerState<_NovelSeriesBar> {
  /// The watchlist cursor is written once per mounted bar — scheduling it
  /// on every build would re-fire the write on each chrome rebuild.
  bool _seenMarked = false;

  int get seriesId => widget.seriesId;
  int get novelId => widget.novelId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(_novelSeriesProvider(seriesId));
    Widget seriesTitle(NovelSeriesPage series) => Text(
      series.title ?? l10n.novelSeries,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return async.when(
      // Same row skeleton as the data state — disabled chevrons and a
      // small spinner where the series name will land.
      loading: () => const _SeriesBarRow(
        center: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      // Localized fallback plus retry — the raw error is logged in the
      // provider, never stitched into the visible text.
      error: (error, _) => _SeriesBarRow(
        center: Text(
          l10n.novelSeriesUnavailable,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: TextButton(
          onPressed: () => ref.invalidate(_novelSeriesProvider(seriesId)),
          child: Text(l10n.retry),
        ),
      ),
      data: (series) {
        final index = series.entries.indexWhere((entry) => entry.id == novelId);
        // The opened work is not in this series: keep title and watchlist
        // but dead-end navigation — a cursor cannot point at a novel the
        // series does not contain, so markSeen must not run either.
        if (index < 0) {
          return _SeriesBarRow(
            center: seriesTitle(series),
            trailing: WatchlistToggle(
              seriesKey: WatchlistKey(WatchlistType.novel, seriesId),
              detailAdded: series.watchlistAdded,
              iconOnly: true,
            ),
          );
        }
        final previous = index > 0 ? series.entries[index - 1] : null;
        final next = index + 1 < series.entries.length
            ? series.entries[index + 1]
            : null;
        // Opening a series novel marks the watchlist cursor at the opened
        // work — an older entry leaves the badge on the newer one.
        final accountId = ref.watch(
          accountStoreProvider.select(
            (async) => async.value?.usableCurrent?.id,
          ),
        );
        if (accountId != null && !_seenMarked) {
          _seenMarked = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ref
                .read(watchlistReadCursorProvider)
                .markSeen(
                  accountId,
                  WatchlistKey(WatchlistType.novel, seriesId),
                  novelId,
                );
          });
        }
        return _SeriesBarRow(
          onPrevious: previous?.viewable == true
              ? () => _showNovelPage(context, previous!.id)
              : null,
          onNext: next?.viewable == true
              ? () => _showNovelPage(context, next!.id)
              : null,
          center: seriesTitle(series),
          trailing: WatchlistToggle(
            seriesKey: WatchlistKey(WatchlistType.novel, seriesId),
            detailAdded: series.watchlistAdded,
            iconOnly: true,
          ),
        );
      },
    );
  }
}
