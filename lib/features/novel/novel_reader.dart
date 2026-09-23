import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/network/api_error.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/reader_settings.dart';
import '../../l10n/context.dart';
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

  /// Jump the PageView to [page] (clamped). `animate: false` lands on the
  /// target in the same frame — far jumps from the progress sheet skip the
  /// page-turn animation entirely.
  void Function(int page, {bool animate})? goToPage;
}

/// Horizontal, non-scrolling body reader with a cancellable relayout path.
class NovelReader extends StatefulWidget {
  const NovelReader({
    super.key,
    required this.novel,
    this.settings = const NovelReaderSettings(),
    this.initialAnchor,
    this.textColor,
    this.onAnchorChanged,
    this.onCenterTap,
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

  /// Fires when the current page's start anchor is reported — either by a
  /// layout commit re-asserting position ([NovelAnchorCause.layoutEcho]) or
  /// by a user-committed turn settling ([NovelAnchorCause.userTurn]).
  final void Function(NovelAnchor anchor, NovelAnchorCause cause)?
  onAnchorChanged;

  /// Middle tap-zone hit — the hosting page toggles its reader chrome.
  final VoidCallback? onCenterTap;

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
  late final PageController _pageController;
  late final NovelLayoutEngine _layoutEngine =
      widget.layoutEngine ?? NovelLayoutEngine();
  final NovelReaderCommitGate _commitGate = NovelReaderCommitGate();

  NovelLayout? _layout;

  /// A committed-nowhere layout failure (budget overflow, deterministic
  /// engine error) — rendered as a retryable error state instead of an
  /// unhandled async exception.
  Object? _layoutError;
  Size? _requestedViewport;
  Brightness? _requestedBrightness;
  TextDirection? _requestedDirection;
  bool _layoutScheduled = false;

  /// Set while a commit postFrame performs the programmatic restore
  /// `jumpToPage`: that call dispatches `onPageChanged` synchronously, so
  /// the flag turns its notification into a layout echo instead of a user
  /// turn.
  bool _layoutEchoPending = false;

  @override
  void initState() {
    super.initState();
    _reader = NovelReaderController(pageCount: 1);
    _pageController = PageController();
    final handle = widget.handle;
    if (handle != null) {
      handle.currentPage = () => _reader.currentPage;
      handle.pageCount = () => _reader.pageCount;
      handle.goToPage = (page, {animate = true}) {
        final target = page.clamp(0, _reader.pageCount - 1);
        if (!animate) {
          _pageController.jumpToPage(target);
          return;
        }
        _pageController.animateToPage(
          target,
          duration: MotionTokens.fast,
          curve: MotionTokens.fastCurve,
        );
      };
    }
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleLayout();
    });
  }

  @override
  void didUpdateWidget(covariant NovelReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.novel.contentVersion != widget.novel.contentVersion) {
      _layoutEngine.cache.clear();
      _scheduleLayout(force: true);
    } else if (oldWidget.settings != widget.settings) {
      _scheduleLayout(force: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleLayout();
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
    }
    _commitGate.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _scheduleLayout(
          viewport: viewport,
          brightness: theme.brightness,
          direction: Directionality.of(context),
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
          return const FeedLoading();
        }
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
            _pageController.animateToPage(
              target,
              duration: MotionTokens.fast,
              curve: MotionTokens.fastCurve,
            );
          },
          child: PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.horizontal,
            itemCount: layout.pages.length,
            onPageChanged: (page) {
              setState(() => _reader.setPage(page));
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
              color: widget.textColor ?? theme.colorScheme.onSurface,
            ),
          ),
        );
      },
    );
  }

  NovelLayoutStyle get _style => NovelLayoutStyle(
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
    bool force = false,
  }) {
    if (!mounted) return;
    final nextViewport = viewport ?? _requestedViewport;
    final nextBrightness = brightness ?? _requestedBrightness;
    final nextDirection = direction ?? _requestedDirection;
    final unchanged =
        nextViewport == _requestedViewport &&
        nextBrightness == _requestedBrightness &&
        nextDirection == _requestedDirection;
    // A recorded layout error counts as "answered" for the same request —
    // re-running it automatically would retry a deterministic failure
    // forever; only an explicit [force] (retry/settings change) re-enters.
    if (unchanged && !force && (_layout != null || _layoutError != null)) {
      return;
    }
    _requestedViewport = nextViewport;
    _requestedBrightness = nextBrightness;
    _requestedDirection = nextDirection;
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
    final oldLayout = _layout;
    final oldPage = _reader.currentPage;
    // First layout restores the persisted resume anchor; later relayouts
    // keep the live page's start anchor.
    final oldAnchor = oldLayout == null || oldLayout.pages.isEmpty
        ? widget.initialAnchor
        : oldLayout
              .pages[oldPage.clamp(0, oldLayout.pages.length - 1)]
              .startAnchor;
    final document =
        widget.novel.markup ??
        NovelMarkupDocument.fromParagraphs(widget.novel.paragraphs);
    final layoutContext = _commitGate.beginLayout(
      contentVersion: widget.novel.contentVersion,
      chapterId: null,
      pageIndex: oldPage,
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
        cancelToken: layoutContext.cancelToken,
        budget: widget.budget,
      );
      _commitGate.commit(
        layoutContext,
        contentVersion: widget.novel.contentVersion,
        chapterId: null,
        disposed: !mounted,
        action: () {
          // A page swipe that happened while layout was running is a user
          // choice and wins over the old anchor. Otherwise restore the
          // stable paragraph/UTF-16 anchor captured before relayout.
          final pageWasChanged = _reader.currentPage != layoutContext.pageIndex;
          final restoredPage = pageWasChanged
              ? _reader.currentPage.clamp(0, result.pages.length - 1)
              : oldAnchor == null
              ? layoutContext.pageIndex.clamp(0, result.pages.length - 1)
              : result.pageIndexForAnchor(oldAnchor);
          setState(() {
            _reader.updatePageCount(result.pages.length, page: restoredPage);
          });
          setState(() {
            _layout = result;
            _layoutError = null;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_pageController.hasClients) return;
            if (!_commitGate.isCurrent(layoutContext)) return;
            _layoutEchoPending = true;
            _pageController.jumpToPage(restoredPage);
            _layoutEchoPending = false;
            // The explicit echo also covers the no-op jump where the
            // restored page already equals the current one (no
            // onPageChanged fires then).
            _notifyAnchor(NovelAnchorCause.layoutEcho);
            _notifyProgress();
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

  void _notifyAnchor(NovelAnchorCause cause) {
    final layout = _layout;
    if (layout == null || layout.pages.isEmpty) return;
    final page =
        layout.pages[_reader.currentPage.clamp(0, layout.pages.length - 1)];
    widget.onAnchorChanged?.call(page.startAnchor, cause);
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
  });

  final NovelLayoutPage page;
  final NovelLayoutStyle style;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: style.horizontalPadding,
        vertical: style.verticalPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in page.lines) ...[
            if (line.text.isEmpty)
              SizedBox(height: line.height)
            else
              SizedBox(
                height: line.height,
                child: Text(
                  line.text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: style.textStyle(color),
                ),
              ),
            if (line.isParagraphEnd) SizedBox(height: style.paragraphSpacing),
          ],
        ],
      ),
    );
  }
}
