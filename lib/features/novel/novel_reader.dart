import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/rendering.dart'
    show ClipRectLayer, LayerHandle, RenderProxyBox, ScrollCacheExtent;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../../core/network/api_error.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/feed_text_warmup.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/skeleton/func_skeleton.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/reader_settings.dart';
import '../../l10n/context.dart';
import 'novel_illustration.dart';
import 'novel_layout.dart';

enum NovelTapZone { previous, center, next }

/// Why an anchor notification was emitted. Persistence binds only to
/// [userTurn] — a layout echo re-asserts position without meaning the user
/// read there (open/restore, settings relayout).
enum NovelAnchorCause {
  /// First-layout restore or a post-commit re-assert of the current page
  /// (relayout after settings/viewport changes).
  layoutEcho,

  /// A user-committed page change: tap-zone/swipe turn, `goToPage`,
  /// keyboard turn.
  userTurn,
}

@immutable
class NovelReaderLayoutContext {
  const NovelReaderLayoutContext({
    required this.generation,
    required this.contentVersion,
    required this.chapterId,
    required this.pageIndex,
    required this.cancelToken,
  });

  final int generation;
  final String contentVersion;
  final String? chapterId;
  final int pageIndex;
  final CancelToken cancelToken;

  bool get isCancelled => cancelToken.isCancelled;
}

enum NovelReaderDiscardReason {
  cancelled,
  stale,
  contentChanged,
  chapterChanged,
  disposed,
}

/// Generation gate for the parse/layout/commit pipeline. Page selection is
/// carried in the context so a late layout can restore the user's current
/// page deliberately; content and chapter identity still fence the commit.
class NovelReaderCommitGate {
  NovelReaderCommitGate({this.maxDiscardEvents = 32})
    : assert(maxDiscardEvents > 0);

  final int maxDiscardEvents;
  final List<NovelReaderDiscardReason> _discardEvents = [];
  NovelReaderLayoutContext? _active;
  int _generation = 0;
  bool _disposed = false;

  int get generation => _generation;

  List<NovelReaderDiscardReason> get discardEvents =>
      List.unmodifiable(_discardEvents);

  NovelReaderLayoutContext beginLayout({
    required String contentVersion,
    required String? chapterId,
    required int pageIndex,
    CancelToken? cancelToken,
  }) {
    if (_disposed) throw StateError('reader gate is disposed');
    _active?.cancelToken.cancel();
    final context = NovelReaderLayoutContext(
      generation: ++_generation,
      contentVersion: contentVersion,
      chapterId: chapterId,
      pageIndex: pageIndex,
      cancelToken: cancelToken ?? CancelToken(),
    );
    _active = context;
    return context;
  }

  bool commit(
    NovelReaderLayoutContext context, {
    required String contentVersion,
    required String? chapterId,
    required void Function() action,
    bool disposed = false,
  }) {
    final reason = _reason(
      context,
      contentVersion: contentVersion,
      chapterId: chapterId,
      disposed: disposed,
    );
    if (reason != null) {
      _record(reason);
      return false;
    }
    action();
    return true;
  }

  bool isCurrent(NovelReaderLayoutContext context) =>
      !_disposed &&
      context.generation == _generation &&
      identical(_active, context);

  void dispose() {
    _disposed = true;
    _active?.cancelToken.cancel();
    _active = null;
    _generation++;
  }

  NovelReaderDiscardReason? _reason(
    NovelReaderLayoutContext context, {
    required String contentVersion,
    required String? chapterId,
    required bool disposed,
  }) {
    if (disposed || _disposed) return NovelReaderDiscardReason.disposed;
    if (context.isCancelled) return NovelReaderDiscardReason.cancelled;
    if (!isCurrent(context)) return NovelReaderDiscardReason.stale;
    if (context.contentVersion != contentVersion) {
      return NovelReaderDiscardReason.contentChanged;
    }
    if (context.chapterId != chapterId) {
      return NovelReaderDiscardReason.chapterChanged;
    }
    return null;
  }

  void _record(NovelReaderDiscardReason reason) {
    if (_discardEvents.length == maxDiscardEvents) _discardEvents.removeAt(0);
    _discardEvents.add(reason);
  }
}

/// Page state that is independent from a particular viewport layout.
///
/// A plain mutable view-model: the reader widget owns it, calls the mutators
/// and repaints itself with `setState` (C7a — no listener machinery).
class NovelReaderController {
  NovelReaderController({required int pageCount, int initialPage = 0})
    : _pageCount = pageCount < 1 ? 1 : pageCount,
      _currentPage = initialPage.clamp(0, (pageCount < 1 ? 1 : pageCount) - 1);

  int _pageCount;
  int _currentPage;

  int get pageCount => _pageCount;
  int get currentPage => _currentPage;

  double get progressPercent => _progressFor(_currentPage);

  NovelTapZone zoneForTap(double dx, double width) {
    if (width <= 0 || dx < 0 || dx > width) return NovelTapZone.center;
    final ratio = dx / width;
    if (ratio < 0.3) return NovelTapZone.previous;
    if (ratio > 0.7) return NovelTapZone.next;
    return NovelTapZone.center;
  }

  bool handleTap(double dx, double width) {
    return switch (zoneForTap(dx, width)) {
      NovelTapZone.previous => previous(),
      NovelTapZone.next => next(),
      NovelTapZone.center => false,
    };
  }

  bool next() {
    if (_currentPage >= _pageCount - 1) return false;
    setPage(_currentPage + 1);
    return true;
  }

  bool previous() {
    if (_currentPage <= 0) return false;
    setPage(_currentPage - 1);
    return true;
  }

  void setPage(int page) {
    final nextPage = page.clamp(0, _pageCount - 1);
    if (nextPage == _currentPage) return;
    _currentPage = nextPage;
  }

  void updatePageCount(int pageCount, {int? page}) {
    _pageCount = pageCount < 1 ? 1 : pageCount;
    final nextPage = (page ?? _currentPage).clamp(0, _pageCount - 1);
    if (nextPage != _currentPage) {
      _currentPage = nextPage;
    }
  }

  double _progressFor(int page) {
    if (_pageCount <= 1) return 100;
    return page.clamp(0, _pageCount - 1) / (_pageCount - 1) * 100;
  }
}

/// Outward control surface of a mounted [NovelReader]. The reader state
/// fills the callbacks on mount and clears them on dispose, so the hosting
/// page's chrome overlay can drive paging/typography without a GlobalKey.
class NovelReaderHandle {
  /// Current page index and total page count for the chrome's progress
  /// readout; null while the first layout is still running.
  int Function()? currentPage;
  int Function()? pageCount;

  /// Turn to [page] (clamped), or in scroll mode scroll its first line to
  /// the top. `animate: false` lands on the target in the same frame — far
  /// jumps from the progress sheet skip the animation entirely.
  void Function(int page, {bool animate})? goToPage;

  /// Chapter entries of the committed layout — `(title, pageIndex)` pairs
  /// in document order. Empty for chapter-less documents and before the
  /// first layout lands.
  List<({String title, int pageIndex})> Function()? chapters;

  /// The committed layout: bilingual reading reads the paragraphs of the
  /// current page from it; tests read `key.viewport` to verify which
  /// measure width actually fed the layout cache key.
  NovelLayout? Function()? layout;
}

/// One pixel past each edge of the page on screen: the pages beside it are
/// built while the reader rests, and the page after them enters only on
/// the frame a turn lands. A page's lines cost about 6 ms of text layout,
/// which the first frame of every swipe used to pay.
const _neighbourPages = ScrollCacheExtent.pixels(1);

/// A short rule where the author wrote `[newpage]` in scroll mode, as wide
/// as three characters and faint, so it reads as a pause and not as text.
const _newPageRuleAlpha = 0.3;
const _newPageRuleCharacters = 3;

/// The body reader with a cancellable relayout path: screenfuls turned
/// left and right, or one column scrolled up and down, over one layout.
class NovelReader extends StatefulWidget {
  const NovelReader({
    super.key,
    required this.novel,
    this.settings = const NovelReaderSettings(),
    this.initialAnchor,
    this.textColor,
    this.translations = const {},
    this.titleBlock,
    this.onAnchorChanged,
    this.onCenterTap,
    this.onImageTap,
    this.onLinkTap,
    this.onProgressChanged,
    this.handle,
    this.layoutEngine,
    this.budget = const NovelLayoutBudget(),
  });

  final NovelEntity novel;

  /// Typography/surface choices — applied through [NovelLayoutStyle], any
  /// change triggers a relayout preserving the current page's anchor.
  final NovelReaderSettings settings;

  /// Persisted resume position applied to the first layout only.
  final NovelAnchor? initialAnchor;

  /// Body text color override (reader theme palette); defaults to the
  /// ambient `colorScheme.onSurface`.
  final Color? textColor;

  /// Paragraph translations shown under their paragraphs (bilingual
  /// reading), by paragraph id. A new map relayouts, keeping the page.
  final Map<String, String> translations;

  /// Title and byline at the top of the first page; null shows none.
  final NovelTitleBlock? titleBlock;

  /// Fires when the current page's start anchor is reported — either by a
  /// layout commit re-asserting position ([NovelAnchorCause.layoutEcho]) or
  /// by a user-committed turn settling ([NovelAnchorCause.userTurn]).
  final void Function(NovelAnchor anchor, NovelAnchorCause cause)?
  onAnchorChanged;

  /// Middle tap-zone hit — the hosting page toggles its reader chrome.
  final VoidCallback? onCenterTap;

  /// An illustration's tap — the hosting page opens it in a viewer. Null
  /// leaves illustrations to the page's tap zones.
  final ValueChanged<NovelImageLoadRequest>? onImageTap;

  /// A tap on an author's link to a Pixiv address — the hosting page
  /// opens it. Null leaves those links as text; page jumps always work.
  final ValueChanged<Uri>? onLinkTap;

  /// Fires whenever the visible page or page count settles.
  final void Function(int page, int pageCount)? onProgressChanged;

  /// Chrome-facing command surface (see [NovelReaderHandle]).
  final NovelReaderHandle? handle;

  /// Test seam for layout-engine behavior (e.g. counting relayouts);
  /// production leaves the default.
  final NovelLayoutEngine? layoutEngine;

  /// Per-layout transaction budget — inject a small one in tests to reach
  /// the [NovelLayoutBudgetExceeded] error path.
  final NovelLayoutBudget budget;

  @override
  State<NovelReader> createState() => _NovelReaderState();
}

class _NovelReaderState extends State<NovelReader> with WidgetsBindingObserver {
  late final NovelReaderController _reader;
  late PageController _pageController;
  _NovelScrollController _scrollController = _NovelScrollController();
  late final NovelLayoutEngine _layoutEngine =
      widget.layoutEngine ?? NovelLayoutEngine();
  final NovelReaderCommitGate _commitGate = NovelReaderCommitGate();
  final FeedTextWarmup _warmup = FeedTextWarmup();

  NovelLayout? _layout;

  /// A committed-nowhere layout failure (budget overflow, deterministic
  /// engine error) — rendered as a retryable error state instead of an
  /// unhandled async exception.
  Object? _layoutError;
  Size? _requestedViewport;
  Brightness? _requestedBrightness;
  TextDirection? _requestedDirection;
  TextScaler? _requestedTextScaler;
  bool _layoutScheduled = false;

  /// Set while a commit postFrame performs the programmatic restore
  /// `jumpToPage`: that call dispatches `onPageChanged` synchronously, so
  /// the flag turns its notification into a layout echo instead of a user
  /// turn.
  bool _layoutEchoPending = false;

  /// The scroll mode's column over [_layout], built when first read.
  NovelScrollColumn? _column;

  /// The anchor the scroll mode last reported, so a scroll that settles on
  /// the line it started from writes nothing.
  NovelAnchor? _settledAnchor;

  bool get _scrolls => widget.settings.pageTurn == NovelPageTurn.scroll;

  @override
  void initState() {
    super.initState();
    _reader = NovelReaderController(pageCount: 1);
    _pageController = PageController();
    final handle = widget.handle;
    if (handle != null) {
      handle.currentPage = () => _reader.currentPage;
      handle.pageCount = () => _reader.pageCount;
      handle.goToPage = _goToPage;
      handle.chapters = () => [
        for (final page in _layout?.pages ?? const <NovelLayoutPage>[])
          if (page.chapterTitle != null)
            (title: page.chapterTitle!, pageIndex: page.index),
      ];
      handle.layout = () => _layout;
    }
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleLayout();
    });
  }

  void _goToPage(int page, {bool animate = true}) {
    final target = page.clamp(0, _reader.pageCount - 1);
    final layout = _layout;
    if (_scrolls) {
      if (layout == null || !_scrollController.hasClients) return;
      final column = _columnOf(layout);
      _scrollTo(_columnOffset(layout, column.itemOfPage(target)), animate);
      return;
    }
    // The PageView is unmounted while the layout-error state is shown;
    // driving a detached controller asserts/throws.
    if (!_pageController.hasClients) return;
    if (!animate) {
      _pageController.jumpToPage(target);
      return;
    }
    turnPage(context, _pageController, target);
  }

  /// An author's link: a page jump brings that Pixiv page's first line,
  /// as a turn does; an address goes to the hosting page.
  void _followLink(NovelLinkTarget target) {
    if (target.uri case final uri?) {
      widget.onLinkTap?.call(uri);
      return;
    }
    final layout = _layout;
    final page = target.page;
    final starts = widget.novel.markup?.pixivPageStarts ?? const <String>[];
    if (layout == null || page == null || starts.isEmpty) return;
    final start = starts[math.min(page, starts.length) - 1];
    _goToPage(
      layout.pageIndexForAnchor(NovelAnchor(paragraphId: start, offset: 0)),
      animate: false,
    );
  }

  @override
  void didUpdateWidget(covariant NovelReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pageTurn = widget.settings.pageTurn;
    if (oldWidget.settings.pageTurn != pageTurn) _switchPageTurn();
    if (oldWidget.novel.contentVersion != widget.novel.contentVersion) {
      _layoutEngine.cache.clear();
      _scheduleLayout(force: true);
    } else if (oldWidget.settings.copyWith(pageTurn: pageTurn) !=
            widget.settings ||
        oldWidget.titleBlock != widget.titleBlock ||
        !identical(oldWidget.translations, widget.translations)) {
      _scheduleLayout(force: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ambient = DefaultTextStyle.of(context).style;
    final fontsChanged =
        ambient.fontFamily != _ambientFamily ||
        !listEquals(ambient.fontFamilyFallback, _ambientFallback);
    _ambientFamily = ambient.fontFamily;
    _ambientFallback = ambient.fontFamilyFallback;
    _scheduleLayout(force: fontsChanged && _layout != null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleLayout(force: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final handle = widget.handle;
    if (handle != null) {
      handle.currentPage = null;
      handle.pageCount = null;
      handle.goToPage = null;
      handle.chapters = null;
      handle.layout = null;
    }
    _commitGate.dispose();
    _warmup.dispose();
    _pageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Opens the view just chosen where the one it replaces was: the page
  /// that holds the line at the top, or the first line of the page. The
  /// entering view is not mounted yet, so its controller is made anew,
  /// starting there.
  void _switchPageTurn() {
    _warmup.clear();
    final layout = _layout;
    final anchor = _anchorOnScreen(scrolls: !_scrolls);
    if (layout == null || anchor == null) return;
    final page = layout.pageIndexForAnchor(anchor);
    _reader.setPage(page);
    if (_scrolls) {
      final column = _columnOf(layout);
      _settledAnchor = anchor;
      _scrollController.dispose();
      _scrollController = _NovelScrollController(
        initialScrollOffset: _columnOffset(
          layout,
          column.itemForAnchor(anchor),
        ),
      );
    } else {
      _pageController.dispose();
      _pageController = PageController(initialPage: page, keepPage: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // WCAG 1.4.8 line-length cap: ~40 CJK glyphs per line, relative to
        // the font slider so the cap scales with settings and only bites
        // on wide screens (a 390dp phone is narrower than 17*40+48).
        // The body follows the system font size like any text.
        final textScaler = MediaQuery.textScalerOf(context);
        final layoutWidth = math.min(
          constraints.maxWidth,
          textScaler.scale(_style.fontSize) * 40 + _style.horizontalPadding * 2,
        );
        final viewport = Size(layoutWidth, constraints.maxHeight);
        _scheduleLayout(
          viewport: viewport,
          brightness: theme.brightness,
          direction: Directionality.of(context),
          textScaler: textScaler,
        );
        final layoutError = _layoutError;
        if (layoutError != null) {
          return FeedError(
            title: context.l10n.novelLayoutFailed,
            error: layoutError,
            retryLabel: context.l10n.retry,
            onRetry: () => _scheduleLayout(force: true),
          );
        }
        final layout = _layout;
        if (layout == null) {
          return NovelPageSkeleton(style: _style);
        }
        final color = widget.textColor ?? theme.colorScheme.onSurface;
        if (_scrolls) return _scrollBody(layout, color);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final zone = _reader.zoneForTap(
              details.localPosition.dx,
              constraints.maxWidth,
            );
            if (zone == NovelTapZone.center) {
              // Chrome toggle owns the middle zone; paging keeps the edges.
              widget.onCenterTap?.call();
              return;
            }
            // Drive the physical page only — onPageChanged is the single
            // writer of the logical page, so a stale in-flight notification
            // can never clobber a newer target.
            final target =
                _reader.currentPage + (zone == NovelTapZone.next ? 1 : -1);
            if (target < 0 || target >= _reader.pageCount) return;
            turnPage(context, _pageController, target);
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: _onPageScroll,
            child: PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.horizontal,
              allowImplicitScrolling: true,
              scrollCacheExtent: _neighbourPages,
              itemCount: layout.pages.length,
              onPageChanged: (page) {
                // Nothing built reads the page: a rebuild here, mid-swipe,
                // rebuilt every line of the pages on screen.
                _reader.setPage(page);
                _notifyAnchor(
                  _layoutEchoPending
                      ? NovelAnchorCause.layoutEcho
                      : NovelAnchorCause.userTurn,
                );
                _notifyProgress();
              },
              itemBuilder: (context, index) => _NovelPage(
                page: layout.pages[index],
                style: _style,
                color: color,
                novel: widget.novel,
                onImageTap: widget.onImageTap,
                onLinkTap: _followLink,
                openAddresses: widget.onLinkTap != null,
                // The layout viewport already carries the line-length cap —
                // the text column centers inside it while tap zones keep the
                // full width.
                maxWidth: layout.key.viewport.width,
              ),
            ),
          ),
        );
      },
    );
  }

  /// The scroll mode: the pages' lines in one column, each at its measured
  /// extent. A tap anywhere toggles the chrome, unless it caught the column
  /// moving: then it only stops it, as a tap on any list does.
  Widget _scrollBody(NovelLayout layout, Color color) {
    final column = _columnOf(layout);
    final styles = {
      for (final kind in NovelLineKind.values)
        kind: _style.lineStyle(kind, color),
    };
    final onImageTap = widget.onImageTap;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_scrollController.caughtScroll) return;
        widget.onCenterTap?.call();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onColumnScroll,
        child: _TextAreaClip(
          inset: _style.verticalPadding,
          child: ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(vertical: _style.verticalPadding),
            itemCount: column.items.length,
            itemExtentBuilder: (index, _) =>
                index < column.items.length ? column.extentAt(index) : null,
            itemBuilder: (context, index) {
              final item = column.items[index];
              final line = item.line;
              if (line == null) {
                // A null child would end the list here.
                if (item.gap != NovelPageBreak.newPage) {
                  return const SizedBox.shrink();
                }
                return Center(
                  child: SizedBox(
                    width: _style.fontSize * _newPageRuleCharacters,
                    height: 1,
                    child: ColoredBox(
                      color: color.withValues(alpha: _newPageRuleAlpha),
                    ),
                  ),
                );
              }
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  // The layout viewport carries the line-length cap; the
                  // column centres in the list, which scrolls at full width.
                  width: layout.key.viewport.width,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: _style.horizontalPadding,
                    ),
                    child: _NovelLine(
                      line: line,
                      style: styles[line.kind],
                      color: color,
                      novel: widget.novel,
                      onImageTap: onImageTap == null
                          ? null
                          : (image) {
                              if (_scrollController.caughtScroll) return;
                              onImageTap(image);
                            },
                      onLinkTap: (target) {
                        if (_scrollController.caughtScroll) return;
                        _followLink(target);
                      },
                      openAddresses: widget.onLinkTap != null,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// A scroll that settles reports the line now at the top and its page.
  bool _onColumnScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification is! ScrollEndNotification) {
      return false;
    }
    // A restore reports itself once it has jumped.
    if (_layoutEchoPending) return false;
    final layout = _layout;
    if (layout == null) return false;
    final column = _columnOf(layout);
    final item = column.itemAt(notification.metrics.pixels);
    final anchor = column.anchorAt(item);
    if (anchor == _settledAnchor) return false;
    _settledAnchor = anchor;
    _reader.setPage(column.items[item].page);
    _notifyAnchor(NovelAnchorCause.userTurn);
    _notifyProgress();
    return false;
  }

  NovelScrollColumn _columnOf(NovelLayout layout) {
    final column = _column;
    if (column != null && identical(column.layout, layout)) return column;
    return _column = NovelScrollColumn(layout, _style);
  }

  /// The scroll offset that puts [item] at the top of the text, short of
  /// the column's end.
  double _columnOffset(NovelLayout layout, int item) {
    final column = _columnOf(layout);
    final end =
        column.extent + _style.verticalPadding * 2 - layout.key.viewport.height;
    return math.min(column.offsetOf(item), math.max(0.0, end));
  }

  void _scrollTo(double offset, bool animate) {
    final duration = animate
        ? MotionTokens.resolve(context, MotionTokens.spatial)
        : Duration.zero;
    if (duration > Duration.zero) {
      _scrollController.animateTo(
        offset,
        duration: duration,
        curve: MotionTokens.spatialCurve,
      );
    } else {
      _scrollController.jumpTo(offset);
    }
  }

  bool _onPageScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) _warmup.clear();
    if (notification is ScrollEndNotification) _warmPagesAhead();
    return false;
  }

  /// Lays out the lines of the pages two away from the one on screen,
  /// between frames while the reader rests. The pages beside it are built
  /// already; a turn builds the next one out in the frame it lands, and
  /// those lines' first layout (about 6 ms a page) dropped that frame.
  void _warmPagesAhead() {
    _warmup.clear();
    final pages = _layout?.pages;
    if (pages == null) return;
    final color = widget.textColor ?? Theme.of(context).colorScheme.onSurface;
    final page = _reader.currentPage;
    for (final index in [page - 2, page + 2]) {
      if (index < 0 || index >= pages.length) continue;
      _warmup.add(
        _NovelPage.warmTexts(context, pages[index], _style, color),
        item: index,
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
      );
    }
  }

  /// The family and fallbacks the lines inherit from the theme; the
  /// layout measures with them (LAYOUT-04).
  String? _ambientFamily;
  List<String>? _ambientFallback;

  NovelLayoutStyle get _style => NovelLayoutStyle(
    fontFamily: _ambientFamily,
    fontFamilyFallback: _ambientFallback,
    fontSize: widget.settings.fontSize,
    lineHeight: widget.settings.lineHeight,
  );

  /// A build-driven call with identical inputs must not re-run the layout
  /// pipeline — otherwise every setState would schedule a relayout whose
  /// commit rebuilds again, looping forever. [force] is how real changes
  /// (font size, content version, lifecycle resume) invalidate the cache.
  void _scheduleLayout({
    Size? viewport,
    Brightness? brightness,
    TextDirection? direction,
    TextScaler? textScaler,
    bool force = false,
  }) {
    if (!mounted) return;
    final nextViewport = viewport ?? _requestedViewport;
    final nextBrightness = brightness ?? _requestedBrightness;
    final nextDirection = direction ?? _requestedDirection;
    final nextTextScaler = textScaler ?? _requestedTextScaler;
    final unchanged =
        nextViewport == _requestedViewport &&
        nextBrightness == _requestedBrightness &&
        nextDirection == _requestedDirection &&
        nextTextScaler == _requestedTextScaler;
    // A recorded layout error counts as "answered" for the same request —
    // re-running it automatically would retry a deterministic failure
    // forever; only an explicit [force] (retry/settings change) re-enters.
    if (unchanged && !force && (_layout != null || _layoutError != null)) {
      return;
    }
    _requestedViewport = nextViewport;
    _requestedBrightness = nextBrightness;
    _requestedDirection = nextDirection;
    _requestedTextScaler = nextTextScaler;
    if (_requestedViewport == null || _layoutScheduled) return;
    _layoutScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutScheduled = false;
      if (mounted) unawaited(_relayout());
    });
  }

  Future<void> _relayout() async {
    final viewport = _requestedViewport;
    if (viewport == null || viewport.isEmpty) return;
    final brightness = _requestedBrightness ?? Theme.of(context).brightness;
    final direction = _requestedDirection ?? Directionality.of(context);
    final document =
        widget.novel.markup ??
        NovelMarkupDocument.fromParagraphs(widget.novel.paragraphs);
    final layoutContext = _commitGate.beginLayout(
      contentVersion: widget.novel.contentVersion,
      chapterId: null,
      pageIndex: _reader.currentPage,
    );
    try {
      final result = await _layoutEngine.layoutDocumentCancellable(
        document: document,
        contentVersion: widget.novel.contentVersion,
        viewport: viewport,
        style: _style,
        textColor: widget.textColor ?? Theme.of(context).colorScheme.onSurface,
        brightness: brightness,
        textDirection: direction,
        textScaler: _requestedTextScaler ?? TextScaler.noScaling,
        translations: widget.translations,
        titleBlock: widget.titleBlock,
        cancelToken: layoutContext.cancelToken,
        budget: widget.budget,
        jumpLabel: context.l10n.novelJumpToPage,
      );
      _commitGate.commit(
        layoutContext,
        contentVersion: widget.novel.contentVersion,
        chapterId: null,
        disposed: !mounted,
        action: () {
          // Restore the stable paragraph/UTF-16 anchor of the page on
          // screen now — the first layout restores the persisted resume
          // anchor. A swipe made while the layout ran is a user choice
          // and wins; its anchor, unlike its index, still names the same
          // text once translations have moved the page breaks.
          final anchor = _liveAnchor ?? widget.initialAnchor;
          final restoredPage = anchor == null
              ? _reader.currentPage.clamp(0, result.pages.length - 1)
              : result.pageIndexForAnchor(anchor);
          setState(() {
            _reader.updatePageCount(result.pages.length, page: restoredPage);
          });
          double scrollOffset() {
            final column = _columnOf(result);
            return _columnOffset(
              result,
              anchor == null
                  ? column.itemOfPage(restoredPage)
                  : column.itemForAnchor(anchor),
            );
          }

          setState(() {
            _layout = result;
            _layoutError = null;
            // The column's first build starts at the anchor's line, rather
            // than showing the text's top for a frame first.
            if (_scrolls && !_scrollController.hasClients) {
              _scrollController.dispose();
              _scrollController = _NovelScrollController(
                initialScrollOffset: scrollOffset(),
              );
            }
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_commitGate.isCurrent(layoutContext)) return;
            if (_scrolls) {
              if (!_scrollController.hasClients) return;
              final offset = scrollOffset();
              // As with pages, a jump cuts short a scroll in progress, so
              // the column jumps only when the line moved.
              if (_scrollController.offset != offset) {
                _layoutEchoPending = true;
                _scrollController.jumpTo(offset);
                _layoutEchoPending = false;
              }
              _settledAnchor = _liveAnchor;
            } else {
              if (!_pageController.hasClients) return;
              // Jump only when the page moved: a jump idles the position,
              // which would cut short a swipe the user is making while a
              // relayout (a translation arriving) lands.
              if (_pageController.page?.round() != restoredPage) {
                _layoutEchoPending = true;
                _pageController.jumpToPage(restoredPage);
                _layoutEchoPending = false;
              }
            }
            // The explicit echo also covers the skipped jump where the
            // restored page already equals the current one (no
            // onPageChanged fires then).
            _notifyAnchor(NovelAnchorCause.layoutEcho);
            _notifyProgress();
            if (!_scrolls) _warmPagesAhead();
          });
        },
      );
    } on ApiCancelled {
      // A newer viewport/style calculation owns the reader now.
    } catch (error) {
      // Budget overflows and other deterministic layout failures must not
      // surface as unhandled async errors — a stale context's failure is
      // still dropped because a newer layout owns the reader.
      if (!mounted || !_commitGate.isCurrent(layoutContext)) return;
      setState(() => _layoutError = error);
    }
  }

  NovelAnchor? get _liveAnchor => _anchorOnScreen(scrolls: _scrolls);

  /// Where the reader is: the line at the top of the column in scroll
  /// mode, the start of the page on screen in page mode; null before the
  /// first layout.
  NovelAnchor? _anchorOnScreen({required bool scrolls}) {
    final layout = _layout;
    if (layout == null || layout.pages.isEmpty) return null;
    if (scrolls && _scrollController.hasClients) {
      final column = _columnOf(layout);
      return column.anchorAt(column.itemAt(_scrollController.offset));
    }
    return layout
        .pages[_reader.currentPage.clamp(0, layout.pages.length - 1)]
        .startAnchor;
  }

  void _notifyAnchor(NovelAnchorCause cause) {
    final anchor = _liveAnchor;
    if (anchor != null) widget.onAnchorChanged?.call(anchor, cause);
  }

  void _notifyProgress() {
    widget.onProgressChanged?.call(_reader.currentPage, _reader.pageCount);
  }
}

class _NovelPage extends StatelessWidget {
  const _NovelPage({
    required this.page,
    required this.style,
    required this.color,
    required this.novel,
    required this.onImageTap,
    required this.onLinkTap,
    required this.openAddresses,
    required this.maxWidth,
  });

  final NovelLayoutPage page;
  final NovelLayoutStyle style;
  final Color color;

  /// The novel whose payload holds the images of its image lines.
  final NovelEntity novel;
  final ValueChanged<NovelImageLoadRequest>? onImageTap;
  final ValueChanged<NovelLinkTarget> onLinkTap;
  final bool openAddresses;

  /// Width of the layout viewport that measured this page — the text
  /// column centers inside the (possibly wider) page slot.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: _buildColumn(context),
      ),
    );
  }

  /// The lines of [page] as its `Text`s lay them out: the reader's style
  /// over the ambient one, in the UI locale, as the lines set none.
  static List<WarmText> warmTexts(
    BuildContext context,
    NovelLayoutPage page,
    NovelLayoutStyle style,
    Color color,
  ) {
    final styles = {
      for (final kind in NovelLineKind.values)
        kind: warmStyle(context, style.lineStyle(kind, color)),
    };
    final locale = Localizations.maybeLocaleOf(context);
    return [
      for (final line in page.lines)
        if (line.text.isNotEmpty)
          (
            span: TextSpan(text: line.text, style: styles[line.kind]),
            locale: locale,
            strutStyle: null,
          ),
    ];
  }

  Widget _buildColumn(BuildContext context) {
    final styles = {
      for (final kind in NovelLineKind.values)
        kind: style.lineStyle(kind, color),
    };
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: style.horizontalPadding,
        vertical: style.verticalPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in page.lines) ...[
            _NovelLine(
              line: line,
              style: styles[line.kind],
              color: color,
              novel: novel,
              onImageTap: onImageTap,
              onLinkTap: onLinkTap,
              openAddresses: openAddresses,
            ),
            if (line.spacingAfter > 0) SizedBox(height: line.spacingAfter),
          ],
        ],
      ),
    );
  }
}

/// One line of the text, at its measured height: a row of text, or the
/// illustration of an image line.
class _NovelLine extends StatelessWidget {
  const _NovelLine({
    required this.line,
    required this.style,
    required this.color,
    required this.novel,
    required this.onImageTap,
    required this.onLinkTap,
    required this.openAddresses,
  });

  final NovelPageLine line;
  final TextStyle? style;
  final Color color;
  final NovelEntity novel;
  final ValueChanged<NovelImageLoadRequest>? onImageTap;
  final ValueChanged<NovelLinkTarget> onLinkTap;

  /// Whether links to addresses open; off, they read as text.
  final bool openAddresses;

  @override
  Widget build(BuildContext context) {
    final links = [
      for (final link in line.links)
        if (link.target.page != null || openAddresses) link,
    ];
    return SizedBox(
      height: line.height,
      child: switch (line) {
        NovelPageLine(:final image?) => NovelIllustration(
          novel: novel,
          image: image,
          color: color,
          onTap: onImageTap,
        ),
        NovelPageLine(text: '') => null,
        _ when links.isNotEmpty => _NovelLinkText(
          text: line.text,
          links: links,
          style: style,
          onTap: onLinkTap,
        ),
        _ => Text(
          line.text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: style,
        ),
      },
    );
  }
}

/// A line with an author's links: each in the accent colour, a tap on it
/// following it. Same font and size, so the line keeps its measure.
class _NovelLinkText extends StatefulWidget {
  const _NovelLinkText({
    required this.text,
    required this.links,
    required this.style,
    required this.onTap,
  });

  final String text;
  final List<NovelLineLink> links;
  final TextStyle? style;
  final ValueChanged<NovelLinkTarget> onTap;

  @override
  State<_NovelLinkText> createState() => _NovelLinkTextState();
}

class _NovelLinkTextState extends State<_NovelLinkText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final text = widget.text;
    final linkStyle = TextStyle(color: Theme.of(context).colorScheme.primary);
    final spans = <TextSpan>[];
    var at = 0;
    for (final link in widget.links) {
      if (link.start > at) {
        spans.add(TextSpan(text: text.substring(at, link.start)));
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onTap(link.target);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: text.substring(link.start, link.end),
          style: linkStyle,
          recognizer: recognizer,
        ),
      );
      at = link.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: widget.style,
    );
  }
}

/// First-load stand-in for a reader page: paragraphs of text-line bones on
/// the page's own margins and line box, so the text arrives where its
/// placeholder was instead of after a centred spinner.
class NovelPageSkeleton extends StatelessWidget {
  const NovelPageSkeleton({super.key, this.label, this.style});

  /// Spoken while loading; defaults to the generic loading label.
  final String? label;

  /// The page's text settings; null takes the defaults.
  final NovelLayoutStyle? style;

  /// Lines per placeholder paragraph, repeated down the page.
  static const _paragraphLines = [4, 3, 5, 2];

  /// A paragraph's last line stops short, as real text does.
  static const _lastLineWidth = 0.6;

  @override
  Widget build(BuildContext context) {
    final style = this.style ?? const NovelLayoutStyle();
    final lineExtent = style.fontSize * style.lineHeight;
    // A bone covers the glyphs, not the whole line box, so the leading
    // stays open between lines as it does in the text.
    final leading = (lineExtent - style.fontSize) / 2;
    return FuncSkeleton(
      label: label ?? context.l10n.contentLoading,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final lines = constraints.hasBoundedHeight
              ? (constraints.maxHeight / lineExtent).ceil()
              : _paragraphLines.first;
          final children = <Widget>[];
          var placed = 0;
          for (var p = 0; placed < lines; p++) {
            final count = _paragraphLines[p % _paragraphLines.length];
            if (p > 0) {
              children.add(SizedBox(height: style.paragraphSpacing));
            }
            for (var i = 0; i < count; i++, placed++) {
              children.add(
                Padding(
                  padding: EdgeInsets.symmetric(vertical: leading),
                  child: FractionallySizedBox(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: i == count - 1 ? _lastLineWidth : 1,
                    child: SkeletonBone(
                      height: style.fontSize,
                      borderRadius: FuncShape.badge,
                    ),
                  ),
                ),
              );
            }
          }
          return ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              maxHeight: double.infinity,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: style.horizontalPadding,
                  vertical: style.verticalPadding,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Remembers whether a touch caught the column moving, so the tap that
/// stops a fling does not also toggle the chrome or open an image.
class _NovelScrollController extends ScrollController {
  _NovelScrollController({super.initialScrollOffset})
    : super(keepScrollOffset: false);

  bool get caughtScroll =>
      hasClients && (position as _NovelScrollPosition).caughtScroll;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _NovelScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _NovelScrollPosition extends ScrollPositionWithSingleContext {
  _NovelScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// Whether the last touch found the column moving. A touch holds the
  /// position the moment it lands, before a tap can be told from a drag.
  bool caughtScroll = false;

  @override
  ScrollHoldController hold(VoidCallback holdCancelCallback) {
    caughtScroll = activity?.isScrolling ?? false;
    return super.hold(holdCancelCallback);
  }
}

/// Paints [child] only between the page's top and bottom margins, as a page
/// shows its text: lines scroll out of sight there instead of under the
/// status bar and the progress hint. Touches still land anywhere, so a
/// drag can start in a margin.
class _TextAreaClip extends SingleChildRenderObjectWidget {
  const _TextAreaClip({required this.inset, required super.child});

  final double inset;

  @override
  _RenderTextAreaClip createRenderObject(BuildContext context) =>
      _RenderTextAreaClip(inset);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTextAreaClip renderObject,
  ) {
    renderObject.inset = inset;
  }
}

class _RenderTextAreaClip extends RenderProxyBox {
  _RenderTextAreaClip(this._inset);

  double _inset;
  set inset(double value) {
    if (value == _inset) return;
    _inset = value;
    markNeedsPaint();
  }

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Rect.fromLTRB(0, _inset, size.width, size.height - _inset),
      (context, offset) => context.paintChild(child, offset),
      oldLayer: _clip.layer,
    );
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }
}
