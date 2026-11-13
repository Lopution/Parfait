part of 'novel_reader.dart';

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
