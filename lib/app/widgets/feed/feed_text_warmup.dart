import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../../format/content_locale.dart';

/// One paragraph of card text, described exactly as the card lays it out:
/// its spans in their effective styles, its locale and its strut
/// ([warmLine]).
typedef WarmText = ({TextSpan span, Locale? locale, StrutStyle? strutStyle});

/// The lines of the card at [index], laid out under [context].
typedef WarmTexts = List<WarmText> Function(BuildContext context, int index);

/// [text] as a [Text] under [context] lays it out with [style] and
/// `locale: contentLocale(context, text)`: the style as [warmStyle] gives
/// it; the locale the text's script one, else the inherited one.
WarmText warmLine(
  BuildContext context,
  String text,
  TextStyle? style, {
  TextStyle? inherited,
}) => (
  span: TextSpan(
    text: text,
    style: warmStyle(context, style, inherited: inherited),
  ),
  locale: contentLocale(context, text) ?? Localizations.maybeLocaleOf(context),
  strutStyle: null,
);

/// [style] as a [Text] under [context] lays it out: merged over the
/// inherited style ([inherited], else the [DefaultTextStyle]) and then made
/// bold when the platform asks for bold text.
TextStyle warmStyle(
  BuildContext context,
  TextStyle? style, {
  TextStyle? inherited,
}) {
  final effective = style != null && !style.inherit
      ? style
      : (inherited ?? DefaultTextStyle.of(context).style).merge(style);
  return MediaQuery.boldTextOf(context)
      ? effective.merge(const TextStyle(fontWeight: FontWeight.bold))
      : effective;
}

/// Lays out feed card text between frames, ahead of the frame that builds
/// the card.
///
/// Laying out a glyph for the first time reads its outline from the font
/// file, and on a phone short of memory the pages of rarely used glyphs (the
/// kanji of a Japanese title) are often evicted: the read was a 2–5 ms wait
/// on storage inside the frame that built the card, which then missed its
/// vsync. Skia keeps the glyph's metrics once read, so laying the same text
/// out once beforehand moves the read out of the frame. RecyclerView does
/// the same with its prefetch, binding upcoming items between frames.
///
/// The same layout also spares the frame the shaping: SkParagraph keeps a
/// shaped paragraph (ICU breaks, runs and font fallback) and reuses it for
/// the same text in the same locale and font style, whatever the width,
/// line limit or colour.
///
/// One paragraph runs per gap between frames, right after a frame ends, and
/// only when the frame left room for a slow one before the next vsync.
class FeedTextWarmup {
  FeedTextWarmup({Duration Function()? clock}) : _now = clock ?? _monotonicNow;

  /// The longest a cold paragraph took on device, its font pages read back
  /// from flash.
  static const itemCost = Duration(microseconds: 5500);

  /// One vsync at 120 Hz. A slower display only gets a wider margin; the
  /// reported refresh rate is not trusted, as LTPO panels switch rates.
  static const vsync = Duration(microseconds: 8333);

  static final _stopwatch = Stopwatch()..start();
  static Duration _monotonicNow() => _stopwatch.elapsed;

  final Duration Function() _now;
  final _pending = Queue<_Pending>();
  int? _frameCallback;
  Timer? _gap;
  bool _waiting = false;
  bool _disposed = false;

  /// Queues [texts], the lines of feed item [item], behind any still
  /// pending.
  void add(
    Iterable<WarmText> texts, {
    required int item,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    assert(!_disposed);
    assert(_pending.isEmpty || _pending.last.item <= item);
    for (final text in texts) {
      if (text.span.toPlainText().isEmpty) continue;
      _pending.add(_Pending(text, textScaler, textDirection, item));
    }
    _schedule();
  }

  /// Drops the lines of the items up to [item]: their cards are built, so
  /// laying them out now would only spend a gap.
  void dropThrough(int item) {
    while (_pending.isNotEmpty && _pending.first.item <= item) {
      _pending.removeFirst();
    }
  }

  /// Drops everything still pending (the feed was replaced).
  void clear() => _pending.clear();

  @visibleForTesting
  int get pendingCount => _pending.length;

  void dispose() {
    _disposed = true;
    final frameCallback = _frameCallback;
    if (frameCallback != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frameCallback);
    }
    _gap?.cancel();
    _pending.clear();
  }

  void _schedule() {
    if (_waiting || _pending.isEmpty || _disposed) return;
    _waiting = true;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase != SchedulerPhase.idle) {
      // Mid-frame, its start unknown: look again once it is over.
      scheduler.addPostFrameCallback((_) {
        if (!_disposed) _runInGap(null);
      }, debugLabel: 'FeedTextWarmup');
    } else if (scheduler.hasScheduledFrame) {
      // Note when the coming frame starts, and run right after it ends.
      _frameCallback = scheduler.scheduleFrameCallback((_) {
        _frameCallback = null;
        final frameStart = _now();
        scheduler.addPostFrameCallback((_) {
          if (!_disposed) _runInGap(frameStart);
        }, debugLabel: 'FeedTextWarmup');
      }, scheduleNewFrame: false);
    } else {
      _runInGap(null);
    }
  }

  void _runInGap(Duration? frameStart) =>
      _gap = Timer(Duration.zero, () => _runOne(frameStart));

  void _runOne(Duration? frameStart) {
    _waiting = false;
    if (_disposed || _pending.isEmpty) return;
    if (_fits(frameStart)) _layout(_pending.removeFirst());
    _schedule();
  }

  /// Whether a paragraph started now ends before the next frame is due.
  bool _fits(Duration? frameStart) {
    if (!SchedulerBinding.instance.hasScheduledFrame) return true;
    if (frameStart == null) return false;
    return _now() - frameStart + itemCost <= vsync;
  }

  static void _layout(_Pending item) {
    assert(SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle);
    layOut(
      item.text,
      textScaler: item.textScaler,
      textDirection: item.textDirection,
    );
  }

  /// Lays [text] out once, now, for the caches the frame that builds it
  /// reads.
  static void layOut(
    WarmText text, {
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    TextPainter(
        text: text.span,
        locale: text.locale,
        strutStyle: text.strutStyle,
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )
      ..layout()
      ..dispose();
  }
}

class _Pending {
  const _Pending(this.text, this.textScaler, this.textDirection, this.item);

  final WarmText text;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final int item;
}

/// Keeps the lines of the items just past the furthest one a list has
/// built queued on a [FeedTextWarmup], at most [maxTexts] of them.
///
/// SkParagraph keeps its shaped paragraphs in an LRU cache of 128
/// (`ParagraphCache::kMaxEntries`), shared by every text in the app. A
/// page of novel rows has about 120 lines; laid out a whole page ahead, the
/// first rows' lines were pushed out before those rows were built. The
/// window keeps each line until its item is built, and its item is built
/// once the list scrolls it into the cache area.
///
/// A list calls [update] from its build and [built] from its item builder.
class FeedTextWindow {
  FeedTextWindow({FeedTextWarmup? warmup})
    : _warmup = warmup ?? FeedTextWarmup();

  /// Lines laid out ahead of the furthest built item: about a page of
  /// illust cards (two lines each) or twelve novel rows (four or five).
  static const maxTexts = 60;

  final FeedTextWarmup _warmup;
  WarmTexts? _texts;
  Object? _head;
  int _count = 0;

  /// The furthest item built.
  int _built = -1;

  /// Items before this one are queued or built.
  int _next = 0;

  /// Line counts of the queued items not built yet, in item order.
  final _ahead = Queue<int>();
  int _aheadTexts = 0;

  /// Follows a feed of [count] items whose first is [head]. A different
  /// head or fewer items is a replaced feed (a refresh), which starts over.
  void update(
    BuildContext context, {
    required int count,
    required Object? head,
    required WarmTexts texts,
  }) {
    if (head != _head || count < _count) {
      _warmup.clear();
      _ahead.clear();
      _aheadTexts = 0;
      _built = -1;
      _next = 0;
      _head = head;
    }
    _count = count;
    _texts = texts;
    _fill(context);
  }

  /// The list built item [index] (each time it builds it).
  void built(BuildContext context, int index) {
    if (index <= _built) return;
    final leaving = math.min(index, _next - 1) - _built;
    for (var i = 0; i < leaving; i++) {
      _aheadTexts -= _ahead.removeFirst();
    }
    _built = index;
    _next = math.max(_next, index + 1);
    _warmup.dropThrough(index);
    _fill(context);
  }

  void _fill(BuildContext context) {
    final texts = _texts;
    if (texts == null || _next >= _count || _aheadTexts >= maxTexts) return;
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    while (_next < _count && _aheadTexts < maxTexts) {
      final lines = texts(context, _next);
      _warmup.add(
        lines,
        item: _next,
        textScaler: textScaler,
        textDirection: textDirection,
      );
      _ahead.add(lines.length);
      _aheadTexts += lines.length;
      _next++;
    }
  }

  void dispose() => _warmup.dispose();
}
