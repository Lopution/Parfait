import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/widgets/author_summary.dart';
import '../../app/widgets/bookmark_switch_button.dart';
import '../../app/widgets/caption_rich_text.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/tag_chips.dart';
import '../../app/navigation/routes.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../core/history/history_snapshot.dart';
import '../../core/history/history_visibility.dart';
import '../../core/network/api_error.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/auth/account_store.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/search/search_models.dart';
import '../../core/novel/reader_settings.dart';
import '../../core/novel/novel_store.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/share/share_service.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../app/widgets/watchlist_toggle.dart';
import 'novel_reader.dart';
import 'novel_layout.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/context.dart';

/// Opens the JSON Novel detail route.
void _showNovelPage(BuildContext context, int novelId) {
  if (novelId <= 0) {
    showAppSnackBar(context, context.l10n.novelNotFound);
    return;
  }
  openNovel(context, novelId);
}

final _novelDetailProvider = FutureProvider.autoDispose
    .family<NovelEntity, int>((ref, novelId) async {
      final token = CancelToken();
      ref.onDispose(token.cancel);
      final repository = ref.read(novelRepositoryProvider);
      final entity = await repository.fetchDetail(novelId, cancelToken: token);
      ref.read(novelStoreProvider.notifier).mergeAll([entity]);
      return entity;
    });

final _novelSeriesProvider = FutureProvider.autoDispose
    .family<NovelSeriesPage, int>((ref, seriesId) async {
      final token = CancelToken();
      ref.onDispose(token.cancel);
      return ref
          .read(novelRepositoryProvider)
          .fetchSeries(seriesId, cancelToken: token);
    });

class NovelPage extends ConsumerWidget {
  const NovelPage({super.key, required this.novelId});

  final int novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_novelDetailProvider(novelId));
    return Scaffold(
      body: async.when(
        loading: () => _NovelStatusScaffold(
          child: FeedEmpty(
            icon: Icons.menu_book_outlined,
            title: context.l10n.novelLoading,
          ),
        ),
        error: (error, _) {
          final isNotFound = error is ApiHttpError && error.statusCode == 404;
          return _NovelStatusScaffold(
            child: FeedError(
              title: isNotFound
                  ? context.l10n.novelNotFound
                  : context.l10n.novelLoadFailed,
              error: error,
              retryLabel: context.l10n.novelRetry,
              onRetry: () => ref.invalidate(_novelDetailProvider(novelId)),
            ),
          );
        },
        data: (novel) {
          if (novel.isRestricted) {
            return _NovelStatusScaffold(
              child: FeedEmpty(
                icon: Icons.lock_outline,
                title: context.l10n.novelRestricted,
              ),
            );
          }
          if (!novel.contentAvailable) {
            return _NovelStatusScaffold(
              child: FeedEmpty(
                icon: Icons.text_snippet_outlined,
                title: context.l10n.novelContentUnavailable,
              ),
            );
          }
          return _NovelReaderStage(novel: novel);
        },
      ),
    );
  }
}

/// Status pages keep an ordinary scaffold+appbar so back navigation is
/// always reachable while the immersive stage is not mounted.
class _NovelStatusScaffold extends StatelessWidget {
  const _NovelStatusScaffold({required this.child});

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

/// Immersive reader stage (Shaft/legado model): the paginated body fills the
/// screen; a center tap toggles the top/bottom chrome, which slides in
/// together and stays interactive until the hide animation finishes.
/// System back closes the chrome first, then leaves the page.
class _NovelReaderStage extends ConsumerStatefulWidget {
  const _NovelReaderStage({required this.novel});

  final NovelEntity novel;

  @override
  ConsumerState<_NovelReaderStage> createState() => _NovelReaderStageState();
}

class _NovelReaderStageState extends ConsumerState<_NovelReaderStage> {
  bool _chromeVisible = false;
  final NovelReaderHandle _readerHandle = NovelReaderHandle();
  NovelAnchor? _anchor;
  int _page = 0;
  int _pageCount = 1;

  NovelReaderSettings _settings = const NovelReaderSettings();
  NovelAnchor? _initialAnchor;
  bool _prefsReady = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final settings = await ref.read(novelReaderSettingsStoreProvider).load();
    final accountId = ref.read(
      accountStoreProvider.select((a) => a.value?.usableCurrent?.id),
    );
    final saved = accountId == null
        ? null
        : await ref
              .read(novelProgressStoreProvider)
              .read(accountId, widget.novel.id);
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _initialAnchor = saved == null
          ? null
          : NovelAnchor(paragraphId: saved.paragraphId, offset: saved.offset);
      _prefsReady = true;
    });
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _hideChrome() {
    if (_chromeVisible) setState(() => _chromeVisible = false);
  }

  void _applySettings(NovelReaderSettings next) {
    setState(() => _settings = next);
    unawaited(ref.read(novelReaderSettingsStoreProvider).save(next));
  }

  void _persistAnchor(NovelAnchor anchor) {
    final accountId = ref.read(
      accountStoreProvider.select((a) => a.value?.usableCurrent?.id),
    );
    if (accountId == null) return;
    unawaited(
      ref
          .read(novelProgressStoreProvider)
          .write(
            accountId,
            widget.novel.id,
            paragraphId: anchor.paragraphId,
            offset: anchor.offset,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final novel = widget.novel;
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
      child: ColoredBox(
        color: palette.background ?? Theme.of(context).scaffoldBackgroundColor,
        child: Stack(
          children: [
            Positioned.fill(child: _buildStage(context, novel, palette)),
            // legado-style footer tip: title · page · percent, always on the
            // page edge independent of the chrome bars. The baseline sits
            // just above the gesture strip — a fixed bottom:4 placed the
            // line inside it, where the system nav area clipped it.
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
              child: _buildTopBar(context, novel, palette),
            ),
            _ChromeBar(
              visible: _chromeVisible,
              edge: _ChromeEdge.bottom,
              child: _buildBottomBar(context, novel, l10n, palette),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStage(
    BuildContext context,
    NovelEntity novel,
    NovelReaderPalette palette,
  ) {
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
        onAnchorChanged: (anchor) {
          if (_anchor == anchor) return;
          setState(() => _anchor = anchor);
          _persistAnchor(anchor);
        },
      ),
    );
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return content;
    final pixivEnabled = ref.watch(pixivHistoryEnabledProvider);
    return HistoryVisibility(
      accountId: accountId,
      contentType: HistoryContentType.novel,
      contentId: novel.id,
      snapshot: snapshotFromNovel(
        novel,
        anchorParagraphId: _anchor?.paragraphId,
        anchorOffset: _anchor?.offset,
      ),
      localHistoryEnabled: ref.watch(localHistoryEnabledProvider),
      pixivHistoryEnabled: pixivEnabled,
      repository: ref.watch(historyRepositoryProvider),
      remote: pixivEnabled ? ref.watch(pixivHistoryRemoteProvider) : null,
      isAccountCurrent: () => ref.read(historyAccountIdProvider) == accountId,
      child: content,
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    NovelEntity novel,
    NovelReaderPalette palette,
  ) {
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
              IconButton(
                tooltip: context.l10n.cardActionShare,
                onPressed: () => _shareNovel(context, novel),
                icon: const Icon(Icons.share_outlined),
              ),
              BookmarkSwitchButton(
                illustId: novel.id,
                title: novel.title,
                isNovel: true,
              ),
              IconButton(
                tooltip: context.l10n.novelInfoTitle,
                onPressed: () => _showNovelInfo(context, novel),
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
    NovelEntity novel,
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
                      min: 12,
                      max: 30,
                      onChanged: (v) => apply(_settings.copyWith(fontSize: v)),
                    ),
                    _SettingsSliderRow(
                      label: l10n.novelLineHeight,
                      value: _settings.lineHeight,
                      min: 1.1,
                      max: 2.2,
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

  Future<void> _shareNovel(BuildContext context, NovelEntity novel) async {
    final outcome = await ref
        .read(shareServiceProvider)
        .share(
          SharePayload.novel(
            id: novel.id,
            title: novel.title,
            author: novel.user.name,
          ),
          sharePositionOrigin: shareOriginOf(context),
        );
    if (outcome == ShareOutcome.copiedToClipboard && context.mounted) {
      showAppSnackBar(context, context.l10n.linkCopied);
    }
  }

  void _showNovelInfo(BuildContext context, NovelEntity novel) {
    showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text(novel.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            AuthorSummary(
              name: novel.user.name,
              imageUrl: novel.user.profileImageUrl,
              avatarRadius: 16,
              compact: true,
              onTap: () {
                Navigator.of(sheetContext).pop();
                openUser(context, novel.user.id);
              },
            ),
            if (novel.caption.isNotEmpty) ...[
              const SizedBox(height: 12),
              // Caption HTML renders through the shared parser — <br> tags
              // become real line breaks and links stay clickable.
              CaptionRichText(caption: novel.caption),
            ],
            if (novel.tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                children: [
                  for (final tag in novel.tags)
                    TagChip(
                      label: tag.name,
                      translated: tag.translatedName,
                      onTap: () {
                        // Same close-then-navigate sequence as the author
                        // chip above.
                        Navigator.of(sheetContext).pop();
                        openSearchResults(
                          context,
                          NovelSearchQuery(keyword: tag.name),
                        );
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  openNovelComments(context, novel.id);
                },
                icon: const Icon(Icons.comment_outlined),
                label: Text(
                  novel.totalComments > 0
                      ? '${context.l10n.commentTitle} (${novel.totalComments})'
                      : context.l10n.commentTitle,
                ),
              ),
            ),
          ],
        ),
      ),
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
      if (widget.visible) {
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
