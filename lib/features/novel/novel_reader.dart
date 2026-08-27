import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/network/api_error.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';
import 'novel_layout.dart';

enum NovelTapZone { previous, center, next }

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
class NovelReaderController extends ChangeNotifier {
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
    notifyListeners();
  }

  void updatePageCount(int pageCount, {int? page}) {
    _pageCount = pageCount < 1 ? 1 : pageCount;
    final nextPage = (page ?? _currentPage).clamp(0, _pageCount - 1);
    if (nextPage != _currentPage) {
      _currentPage = nextPage;
    }
    notifyListeners();
  }

  double _progressFor(int page) {
    if (_pageCount <= 1) return 100;
    return page.clamp(0, _pageCount - 1) / (_pageCount - 1) * 100;
  }
}

/// Horizontal, non-scrolling body reader with a cancellable relayout path.
class NovelReader extends StatefulWidget {
  const NovelReader({
    super.key,
    required this.novel,
    this.initialFontSize = 17,
    this.onAnchorChanged,
  });

  final NovelEntity novel;
  final double initialFontSize;
  final ValueChanged<NovelAnchor>? onAnchorChanged;

  @override
  State<NovelReader> createState() => _NovelReaderState();
}

class _NovelReaderState extends State<NovelReader> with WidgetsBindingObserver {
  late final NovelReaderController _reader;
  late final PageController _pageController;
  final NovelLayoutEngine _layoutEngine = NovelLayoutEngine();
  final NovelReaderCommitGate _commitGate = NovelReaderCommitGate();

  NovelLayout? _layout;
  Size? _requestedViewport;
  Brightness? _requestedBrightness;
  TextDirection? _requestedDirection;
  double _fontSize = 17;
  final double _lineHeight = 1.7;
  bool _layoutScheduled = false;

  @override
  void initState() {
    super.initState();
    _fontSize = widget.initialFontSize.clamp(12, 30);
    _reader = NovelReaderController(pageCount: 1)
      ..addListener(_onReaderChanged);
    _pageController = PageController();
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
      _scheduleLayout();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleLayout();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleLayout();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _commitGate.dispose();
    _reader
      ..removeListener(_onReaderChanged)
      ..dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewport = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              _scheduleLayout(
                viewport: viewport,
                brightness: theme.brightness,
                direction: Directionality.of(context),
              );
              final layout = _layout;
              if (layout == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final moved = _reader.handleTap(
                    details.localPosition.dx,
                    constraints.maxWidth,
                  );
                  if (moved) _animateToReaderPage();
                },
                child: PageView.builder(
                  controller: _pageController,
                  scrollDirection: Axis.horizontal,
                  itemCount: layout.pages.length,
                  onPageChanged: (page) {
                    _reader.setPage(page);
                    _notifyAnchor();
                  },
                  itemBuilder: (context, index) => _NovelPage(
                    page: layout.pages[index],
                    style: _style,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              );
            },
          ),
        ),
        _ReaderControls(
          percent: _reader.progressPercent,
          onDecrease: () => _changeFontSize(-1),
          onIncrease: () => _changeFontSize(1),
        ),
      ],
    );
  }

  NovelLayoutStyle get _style =>
      NovelLayoutStyle(fontSize: _fontSize, lineHeight: _lineHeight);

  void _scheduleLayout({
    Size? viewport,
    Brightness? brightness,
    TextDirection? direction,
  }) {
    if (!mounted) return;
    if (viewport != null) _requestedViewport = viewport;
    _requestedBrightness ??= brightness;
    if (brightness != null) _requestedBrightness = brightness;
    if (direction != null) _requestedDirection = direction;
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
    final oldAnchor = oldLayout == null || oldLayout.pages.isEmpty
        ? null
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
        textColor: Theme.of(context).colorScheme.onSurface,
        brightness: brightness,
        textDirection: direction,
        cancelToken: layoutContext.cancelToken,
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
          _reader.updatePageCount(result.pages.length, page: restoredPage);
          setState(() => _layout = result);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_pageController.hasClients) return;
            if (!_commitGate.isCurrent(layoutContext)) return;
            _pageController.jumpToPage(restoredPage);
            _notifyAnchor();
          });
        },
      );
    } on ApiCancelled {
      // A newer viewport/style calculation owns the reader now.
    }
  }

  void _onReaderChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _animateToReaderPage() {
    if (!_pageController.hasClients) return;
    _pageController.animateToPage(
      _reader.currentPage,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
    _notifyAnchor();
  }

  void _notifyAnchor() {
    final layout = _layout;
    if (layout == null || layout.pages.isEmpty) return;
    final page =
        layout.pages[_reader.currentPage.clamp(0, layout.pages.length - 1)];
    widget.onAnchorChanged?.call(page.startAnchor);
  }

  void _changeFontSize(double delta) {
    final next = (_fontSize + delta).clamp(12.0, 30.0);
    if (next == _fontSize) return;
    setState(() => _fontSize = next);
    _scheduleLayout();
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

class _ReaderControls extends StatelessWidget {
  const _ReaderControls({
    required this.percent,
    required this.onDecrease,
    required this.onIncrease,
  });

  final double percent;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  @override
  Widget build(BuildContext context) {
    final value = (percent / 100).clamp(0.0, 1.0);
    final languageTag = Localizations.localeOf(context).toLanguageTag();
    final decreaseLabel = ReplicaStrings.fromTag(
      languageTag,
      'novelDecreaseFont',
    );
    final increaseLabel = ReplicaStrings.fromTag(
      languageTag,
      'novelIncreaseFont',
    );
    final progressLabel = ReplicaStrings.fromTag(
      languageTag,
      'novelReadingProgress',
    );
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: value, minHeight: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: decreaseLabel,
                onPressed: onDecrease,
                icon: const Icon(Icons.text_decrease_outlined),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  '${percent.round()}%',
                  textAlign: TextAlign.center,
                  semanticsLabel: '$progressLabel ${percent.round()}%',
                ),
              ),
              IconButton(
                tooltip: increaseLabel,
                onPressed: onIncrease,
                icon: const Icon(Icons.text_increase_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
