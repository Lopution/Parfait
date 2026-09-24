import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/watchlist_toggle.dart';
import '../../core/auth/account_store.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/novel/reader_settings.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/context.dart';
import 'novel_layout.dart';
import 'novel_reader.dart';

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
        SafeArea(
          bottom: false,
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

/// Immersive reader stage (Shaft/legado model): the paginated body fills
/// the screen; a center tap toggles the top/bottom chrome, which slides in
/// together and stays interactive until the hide animation finishes.
/// System back closes the chrome first, then leaves the page.
class NovelReaderStage extends ConsumerStatefulWidget {
  const NovelReaderStage({super.key, required this.spec});

  final NovelReaderStageSpec spec;

  @override
  ConsumerState<NovelReaderStage> createState() => _NovelReaderStageState();
}

class _NovelReaderStageState extends ConsumerState<NovelReaderStage> {
  bool _chromeVisible = false;
  final NovelReaderHandle _readerHandle = NovelReaderHandle();
  NovelAnchor? _anchor;
  int _page = 0;
  int _pageCount = 1;

  NovelReaderSettings _settings = const NovelReaderSettings();
  NovelAnchor? _initialAnchor;
  bool _prefsReady = false;
  Object? _loadError;

  NovelEntity get novel => widget.spec.novel;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
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

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _hideChrome() {
    if (_chromeVisible) setState(() => _chromeVisible = false);
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
    unawaited(widget.spec.progress.save(anchor));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = novelReaderPalette(_settings.theme);
    final percent = _pageCount <= 1
        ? 100
        : ((_page + 1) / _pageCount * 100).round();
    return PopScope(
      canPop: !_chromeVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hideChrome();
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
              // legado-style footer tip: title · page · percent, always on
              // the page edge independent of the chrome bars. The baseline
              // sits just above the gesture strip — a fixed bottom:4 placed
              // the line inside it, where the system nav area clipped it.
              Positioned(
                left: 16,
                right: 16,
                bottom: 4 + MediaQuery.viewPaddingOf(context).bottom,
                child: IgnorePointer(
                  child: Text(
                    '${novel.title} · ${_page + 1}/$_pageCount · $percent%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color:
                          (palette.foreground ??
                                  Theme.of(context).colorScheme.onSurface)
                              .withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
              _ChromeBar(
                visible: _chromeVisible,
                edge: _ChromeEdge.top,
                child: _buildTopBar(context, palette),
              ),
              _ChromeBar(
                visible: _chromeVisible,
                edge: _ChromeEdge.bottom,
                child: _buildBottomBar(context, l10n, palette),
              ),
            ],
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
    final content = SafeArea(
      bottom: false,
      child: NovelReader(
        novel: novel,
        settings: _settings,
        initialAnchor: _initialAnchor,
        textColor: palette.foreground,
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
        },
      ),
    );
    return widget.spec.bodyWrapper?.call(context, _anchor, content) ?? content;
  }

  Widget _buildTopBar(BuildContext context, NovelReaderPalette palette) {
    final foreground =
        palette.foreground ?? Theme.of(context).colorScheme.onSurface;
    return Material(
      color: (palette.background ?? Theme.of(context).colorScheme.surface)
          .withValues(alpha: 0.96),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        // The Material paints through the status-bar inset; only the
        // controls are padded below it.
        child: SafeArea(
          bottom: false,
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
      color: (palette.background ?? Theme.of(context).colorScheme.surface)
          .withValues(alpha: 0.96),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground),
        // The Material paints through the gesture-strip inset; only the
        // controls are padded above it.
        child: SafeArea(
          top: false,
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
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          '${_page + 1}/$_pageCount · ${percent.round()}%',
                          textAlign: TextAlign.center,
                          semanticsLabel: l10n.novelReadingProgress,
                          maxLines: 1,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(color: foreground),
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

  void _showInfoSheet(BuildContext context) {
    showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
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
    showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
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

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
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
                          child: Slider(
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
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => jumpTo(preview),
                          child: Text(l10n.confirm),
                        ),
                      ],
                    ),
                    // D4: the TOC section only exists when the document
                    // actually has chapters — local TXT files never do.
                    if (chapters.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Divider(),
                      const SizedBox(height: 8),
                      Text(
                        l10n.novelChapters,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.builder(
                          shrinkWrap: true,
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
    showAppBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void apply(NovelReaderSettings next) {
              setSheetState(() {});
              _applySettings(next);
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
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
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final (theme, label) in [
                          (NovelReaderTheme.system, l10n.novelThemeSystem),
                          (NovelReaderTheme.paper, l10n.novelThemePaper),
                          (NovelReaderTheme.sepia, l10n.novelThemeSepia),
                          (NovelReaderTheme.night, l10n.novelThemeNight),
                        ])
                          ChoiceChip(
                            label: Text(label),
                            selected: _settings.theme == theme,
                            onSelected: (_) =>
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

/// One labelled slider row inside the reader settings sheet — legado's
/// settings panel maps each typography knob to a continuous slider.
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
          child: Slider(
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

/// One sliding chrome bar. The controller keeps the bar hittable until the
/// hide animation fully completes — a tap landing mid-slide still hits the
/// button instead of leaking through to the page-turn zone.
class _ChromeBar extends StatefulWidget {
  const _ChromeBar({
    required this.visible,
    required this.edge,
    required this.child,
  });

  final bool visible;
  final _ChromeEdge edge;
  final Widget child;

  @override
  State<_ChromeBar> createState() => _ChromeBarState();
}

class _ChromeBarState extends State<_ChromeBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: MotionTokens.fast,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant _ChromeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      if (!MotionTokens.enabled(context)) {
        // Reduced motion: land the end state — a zeroed controller still
        // drives the hittable/dismissed boundary correctly.
        _controller.value = widget.visible ? 1 : 0;
      } else if (widget.visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTop = widget.edge == _ChromeEdge.top;
    final slide =
        Tween<Offset>(
          begin: Offset(0, isTop ? -1 : 1),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: _controller, curve: MotionTokens.fastCurve),
        );
    // No SafeArea here: the bar surface must paint edge-to-edge so its
    // background covers the system inset. The inset padding lives inside
    // each bar's Material instead — the bar slides from the screen edge
    // while its controls stay clear of the gesture strip.
    final bar = SlideTransition(position: slide, child: widget.child);
    return Positioned(
      top: isTop ? 0 : null,
      bottom: isTop ? null : 0,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Fully hidden means fully gone: no hit target, no semantics, no
          // leftover widget for finders/a11y to see.
          if (_controller.isDismissed) return const SizedBox.shrink();
          return IgnorePointer(
            ignoring: false,
            child: FadeTransition(opacity: _controller, child: child),
          );
        },
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

final _novelSeriesProvider = FutureProvider.autoDispose
    .family<NovelSeriesPage, int>((ref, seriesId) async {
      final token = CancelToken();
      ref.onDispose(token.cancel);
      return ref
          .read(novelRepositoryProvider)
          .fetchSeries(seriesId, cancelToken: token);
    });

/// Prev/next navigation supplied by the webview payload when the detail
/// metadata carries no `series` object of its own.
class _NovelAdjacentBar extends StatelessWidget {
  const _NovelAdjacentBar({required this.prevId, required this.nextId});

  final int? prevId;
  final int? nextId;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: context.l10n.novelPrevious,
          onPressed: prevId == null
              ? null
              : () => _showNovelPage(context, prevId!),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            context.l10n.novelSeries,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: context.l10n.novelNext,
          onPressed: nextId == null
              ? null
              : () => _showNovelPage(context, nextId!),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

class _NovelSeriesBar extends ConsumerWidget {
  const _NovelSeriesBar({required this.seriesId, required this.novelId});

  final int seriesId;
  final int novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_novelSeriesProvider(seriesId));
    return async.when(
      loading: () => const LinearProgressIndicator(minHeight: 1),
      error: (error, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          '${context.l10n.novelSeriesUnavailable}: $error',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      data: (series) {
        final index = series.entries.indexWhere((entry) => entry.id == novelId);
        if (index < 0) return const SizedBox.shrink();
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
        if (accountId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref
                .read(watchlistReadCursorProvider)
                .markSeen(
                  accountId,
                  WatchlistKey(WatchlistType.novel, seriesId),
                  novelId,
                );
          });
        }
        return Row(
          children: [
            IconButton(
              tooltip: context.l10n.novelPrevious,
              onPressed: previous?.viewable == true
                  ? () => _showNovelPage(context, previous!.id)
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                series.title ?? context.l10n.novelSeries,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            WatchlistToggle(
              seriesKey: WatchlistKey(WatchlistType.novel, seriesId),
              detailAdded: series.watchlistAdded,
              iconOnly: true,
            ),
            IconButton(
              tooltip: context.l10n.novelNext,
              onPressed: next?.viewable == true
                  ? () => _showNovelPage(context, next!.id)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        );
      },
    );
  }
}
