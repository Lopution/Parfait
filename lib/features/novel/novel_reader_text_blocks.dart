import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show
        PointerDeviceKind,
        TapGestureRecognizer,
        kDoubleTapTimeout,
        kPrimaryButton,
        kTouchSlop;
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:material_ui/material_ui.dart';

import '../../core/novel/novel_entity.dart';
import 'novel_illustration.dart';
import 'novel_layout.dart';
import 'novel_ruby.dart';

/// A contiguous run of visual lines from the same paragraph slice, painted as
/// one [Text] / [Text.rich] so copying across soft wraps emits no artificial
/// line breaks while preserving [NovelLayout]'s exact measured height.
class NovelParagraphSlice {
  const NovelParagraphSlice({
    required this.text,
    required this.kind,
    required this.height,
    required this.spacingAfter,
    this.image,
    this.links = const [],
    this.rubies = const [],
  });

  final String text;
  final NovelLineKind kind;
  final double height;
  final double spacingAfter;
  final NovelImageLoadRequest? image;
  final List<NovelLineLink> links;
  final List<NovelLineRuby> rubies;

  double get extent => height + spacingAfter;
}

bool _canMergeLines(NovelPageLine prev, NovelPageLine next) =>
    prev.image == null &&
    next.image == null &&
    prev.text.isNotEmpty &&
    next.text.isNotEmpty &&
    prev.spacingAfter == 0 &&
    !prev.isParagraphEnd &&
    prev.paragraphId == next.paragraphId &&
    prev.kind == next.kind;

NovelParagraphSlice _buildSlice(List<NovelPageLine> group) {
  if (group.length == 1) {
    final line = group.single;
    return NovelParagraphSlice(
      text: line.text,
      kind: line.kind,
      height: line.height,
      spacingAfter: line.spacingAfter,
      image: line.image,
      links: line.links,
      rubies: line.rubies,
    );
  }
  final buffer = StringBuffer();
  final links = <NovelLineLink>[];
  final rubies = <NovelLineRuby>[];
  var height = 0.0;
  NovelPageLine? prev;
  for (final line in group) {
    if (prev != null &&
        !line.isTranslation &&
        !line.isTitleBlock &&
        line.startOffset > prev.endOffset) {
      buffer.write(' ' * (line.startOffset - prev.endOffset));
    }
    final offset = buffer.length;
    buffer.write(line.text);
    height += line.height;
    for (final link in line.links) {
      final start = offset + link.start;
      final end = offset + link.end;
      if (links.isNotEmpty &&
          links.last.target == link.target &&
          links.last.end == start) {
        links[links.length - 1] = (
          start: links.last.start,
          end: end,
          target: link.target,
        );
      } else {
        links.add((start: start, end: end, target: link.target));
      }
    }
    for (final ruby in line.rubies) {
      rubies.add((
        start: offset + ruby.start,
        end: offset + ruby.end,
        reading: ruby.reading,
      ));
    }
    prev = line;
  }
  return NovelParagraphSlice(
    text: buffer.toString(),
    kind: group.first.kind,
    height: height,
    spacingAfter: group.last.spacingAfter,
    links: links,
    rubies: rubies,
  );
}

/// Groups adjacent visual lines of the same paragraph into merged render
/// slices without altering page or column geometry.
List<NovelParagraphSlice> groupNovelParagraphSlices(List<NovelPageLine> lines) {
  if (lines.isEmpty) return const [];
  final slices = <NovelParagraphSlice>[];
  var group = <NovelPageLine>[lines.first];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (_canMergeLines(group.last, line)) {
      group.add(line);
    } else {
      slices.add(_buildSlice(group));
      group = [line];
    }
  }
  slices.add(_buildSlice(group));
  return slices;
}

/// One render block inside the scroll mode's [ListView]: either a merged
/// paragraph slice or a page/chapter gap.
typedef NovelScrollBlock = ({
  NovelParagraphSlice? slice,
  NovelPageBreak gap,
  double extent,
});

/// Derived paragraph-level render projection of [NovelScrollColumn]: total
/// scrollable height matches `column.extent` identically while merging soft
/// wraps of each paragraph into a single selectable widget.
class NovelScrollParagraphBlocks {
  factory NovelScrollParagraphBlocks.fromColumn(NovelScrollColumn column) {
    final blocks = <NovelScrollBlock>[];
    final pendingLines = <NovelPageLine>[];

    void flushLines() {
      if (pendingLines.isEmpty) return;
      for (final slice in groupNovelParagraphSlices(pendingLines)) {
        blocks.add((
          slice: slice,
          gap: NovelPageBreak.none,
          extent: slice.extent,
        ));
      }
      pendingLines.clear();
    }

    for (var i = 0; i < column.items.length; i++) {
      final item = column.items[i];
      if (item.line case final line?) {
        pendingLines.add(line);
      } else {
        flushLines();
        blocks.add((slice: null, gap: item.gap, extent: column.extentAt(i)));
      }
    }
    flushLines();
    return NovelScrollParagraphBlocks._(blocks);
  }

  const NovelScrollParagraphBlocks._(this.blocks);

  final List<NovelScrollBlock> blocks;

  int get length => blocks.length;

  double extentAt(int index) => blocks[index].extent;
}

/// Renders one [NovelParagraphSlice] at its pre-measured height, supporting
/// author links, stacked furigana (`[[rb:base > reading]]`), and clean
/// multi-line paragraph selection without artificial line breaks.
class NovelParagraphSliceView extends StatelessWidget {
  const NovelParagraphSliceView({
    super.key,
    required this.slice,
    required this.style,
    required this.color,
    required this.novel,
    required this.onImageTap,
    required this.onLinkTap,
    required this.openAddresses,
  });

  final NovelParagraphSlice slice;
  final TextStyle? style;
  final Color color;
  final NovelEntity novel;
  final ValueChanged<NovelImageLoadRequest>? onImageTap;
  final ValueChanged<NovelLinkTarget> onLinkTap;
  final bool openAddresses;

  @override
  Widget build(BuildContext context) {
    final links = [
      for (final link in slice.links)
        if (link.target.page != null || openAddresses) link,
    ];
    return SizedBox(
      height: slice.height,
      child: switch (slice) {
        NovelParagraphSlice(:final image?) => NovelIllustration(
          novel: novel,
          image: image,
          color: color,
          onTap: onImageTap,
        ),
        NovelParagraphSlice(text: '') => null,
        _ when links.isNotEmpty || slice.rubies.isNotEmpty => _NovelRichSlice(
          text: slice.text,
          links: links,
          rubies: slice.rubies,
          style: style,
          onTap: onLinkTap,
        ),
        _ => Text(slice.text, style: style),
      },
    );
  }
}

class _NovelRichSlice extends StatefulWidget {
  const _NovelRichSlice({
    required this.text,
    required this.links,
    required this.rubies,
    required this.style,
    required this.onTap,
  });

  final String text;
  final List<NovelLineLink> links;
  final List<NovelLineRuby> rubies;
  final TextStyle? style;
  final ValueChanged<NovelLinkTarget> onTap;

  @override
  State<_NovelRichSlice> createState() => _NovelRichSliceState();
}

class _NovelRichSliceState extends State<_NovelRichSlice> {
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

  NovelLineLink? _linkAt(int offset) {
    for (final link in widget.links) {
      if (offset >= link.start && offset < link.end) return link;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final text = widget.text;
    final resolvedBase = DefaultTextStyle.of(context).style.merge(widget.style);
    final linkColor = Theme.of(context).colorScheme.primary;
    final linkStyle = TextStyle(color: linkColor);
    final rubyStyle = novelRubyTextStyle(resolvedBase);
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);

    // Split text on every ruby and link boundary so rubies nested inside links
    // stay clickable and styled while non-ruby segments keep normal TextSpans.
    final cuts = <int>{0, text.length};
    for (final link in widget.links) {
      cuts.add(link.start.clamp(0, text.length));
      cuts.add(link.end.clamp(0, text.length));
    }
    for (final ruby in widget.rubies) {
      cuts.add(ruby.start.clamp(0, text.length));
      cuts.add(ruby.end.clamp(0, text.length));
    }
    final sortedCuts = cuts.toList()..sort();

    NovelLineRuby? rubyStartingAt(int offset) {
      for (final ruby in widget.rubies) {
        if (ruby.start == offset && ruby.end > ruby.start) return ruby;
      }
      return null;
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final cut in sortedCuts) {
      if (cut <= cursor) continue;
      final ruby = rubyStartingAt(cursor);
      if (ruby != null && ruby.end <= text.length) {
        final base = text.substring(ruby.start, ruby.end);
        final link = _linkAt(ruby.start);
        final effectiveBase = link != null
            ? resolvedBase.copyWith(color: linkColor)
            : resolvedBase;
        final effectiveRuby = link != null
            ? rubyStyle.copyWith(color: linkColor)
            : rubyStyle;
        final box = measureNovelRubyBox(
          base: base,
          reading: ruby.reading,
          baseStyle: effectiveBase,
          rubyStyle: effectiveRuby,
          textDirection: textDirection,
          textScaler: textScaler,
        );
        Widget rubyWidget = _NovelRubyInline(
          base: base,
          reading: ruby.reading,
          baseStyle: effectiveBase,
          rubyStyle: effectiveRuby,
          box: box,
        );
        if (link != null) {
          rubyWidget = GestureDetector(
            onTap: () => widget.onTap(link.target),
            child: rubyWidget,
          );
        }
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: rubyWidget,
          ),
        );
        cursor = ruby.end;
        continue;
      }
      final segment = text.substring(cursor, cut);
      final link = _linkAt(cursor);
      if (link != null) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onTap(link.target);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(text: segment, style: linkStyle, recognizer: recognizer),
        );
      } else {
        spans.add(TextSpan(text: segment));
      }
      cursor = cut;
    }
    return Text.rich(TextSpan(children: spans), style: widget.style);
  }
}

/// Stacked furigana unit: the non-positioned base text defines the alphabetic
/// baseline for the line while the reading floats centered above it and is
/// excluded from text selection so copying yields clean base text.
class _NovelRubyInline extends StatelessWidget {
  const _NovelRubyInline({
    required this.base,
    required this.reading,
    required this.baseStyle,
    required this.rubyStyle,
    required this.box,
  });

  final String base;
  final String reading;
  final TextStyle baseStyle;
  final TextStyle rubyStyle;
  final NovelRubyBox box;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        SizedBox(
          width: box.width,
          child: Padding(
            padding: EdgeInsets.only(top: box.rubyHeight),
            child: Center(
              widthFactor: 1,
              child: Text(
                base,
                style: baseStyle,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SelectionContainer.disabled(
            child: Text(
              reading,
              textAlign: TextAlign.center,
              style: rubyStyle,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
            ),
          ),
        ),
      ],
    );
  }
}

/// Coordinates child link/image taps with [NovelReaderTapSurface] so a pointer
/// click handled by a link or illustration never also fires a delayed single
/// click on the reading canvas.
class NovelReaderTapGate {
  VoidCallback? _onChildHandled;

  void markChildHandled() => _onChildHandled?.call();
}

const _touchPointerKinds = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

bool _isMouseLikePointer(PointerDeviceKind kind) =>
    kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;

/// Wraps [SelectionArea] so touch taps toggle chrome or turn pages with zero
/// latency while mouse/trackpad clicks leave the gesture arena to
/// [SelectableRegion] for native drag-select, double-click word selection, and
/// triple-click paragraph selection.
class NovelReaderTapSurface extends StatefulWidget {
  const NovelReaderTapSurface({
    super.key,
    required this.selectionFocusNode,
    required this.tapGate,
    required this.onTap,
    required this.child,
  });

  final FocusNode selectionFocusNode;
  final NovelReaderTapGate tapGate;
  final ValueChanged<Offset> onTap;
  final Widget child;

  @override
  State<NovelReaderTapSurface> createState() => _NovelReaderTapSurfaceState();
}

class _NovelReaderTapSurfaceState extends State<NovelReaderTapSurface> {
  bool _hasSelection = false;
  int? _mousePointer;
  Offset _mouseDownPos = Offset.zero;
  bool _mouseDragged = false;
  bool _hadSelectionOnDown = false;
  bool _childHandled = false;
  bool _inMultiClick = false;
  Timer? _pendingMouseTap;
  Timer? _multiClickCooldown;

  @override
  void initState() {
    super.initState();
    widget.tapGate._onChildHandled = _markChildHandled;
  }

  @override
  void didUpdateWidget(covariant NovelReaderTapSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tapGate != widget.tapGate) {
      oldWidget.tapGate._onChildHandled = null;
      widget.tapGate._onChildHandled = _markChildHandled;
    }
  }

  @override
  void dispose() {
    if (widget.tapGate._onChildHandled == _markChildHandled) {
      widget.tapGate._onChildHandled = null;
    }
    _pendingMouseTap?.cancel();
    _multiClickCooldown?.cancel();
    super.dispose();
  }

  void _markChildHandled() {
    _childHandled = true;
    _pendingMouseTap?.cancel();
    _pendingMouseTap = null;
  }

  void _onSelectionChanged(SelectedContent? content) {
    final text = content?.plainText;
    _hasSelection = text != null && text.isNotEmpty;
    if (_hasSelection) {
      _pendingMouseTap?.cancel();
      _pendingMouseTap = null;
    }
  }

  bool _clearSelectionOnTap() {
    if (!_hasSelection) return false;
    widget.selectionFocusNode.unfocus();
    _hasSelection = false;
    return true;
  }

  void _onTouchTapUp(TapUpDetails details) {
    if (_clearSelectionOnTap()) return;
    widget.onTap(details.localPosition);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!_isMouseLikePointer(event.kind)) return;
    if (event.buttons & kPrimaryButton == 0) return;
    final repeatedClick =
        (_pendingMouseTap?.isActive ?? false) ||
        (_multiClickCooldown?.isActive ?? false);
    _pendingMouseTap?.cancel();
    _pendingMouseTap = null;
    _multiClickCooldown?.cancel();
    _multiClickCooldown = null;
    _mousePointer = event.pointer;
    _mouseDownPos = event.localPosition;
    _mouseDragged = false;
    _hadSelectionOnDown = _hasSelection;
    _childHandled = false;
    _inMultiClick = repeatedClick;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _mousePointer) return;
    if ((event.localPosition - _mouseDownPos).distance > kTouchSlop) {
      _mouseDragged = true;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _mousePointer) return;
    _mousePointer = null;
    if (_inMultiClick) {
      _inMultiClick = false;
      _multiClickCooldown = Timer(kDoubleTapTimeout, () {});
      return;
    }
    if (_mouseDragged ||
        _hadSelectionOnDown ||
        _childHandled ||
        _hasSelection) {
      return;
    }
    final pos = event.localPosition;
    _pendingMouseTap = Timer(kDoubleTapTimeout, () {
      _pendingMouseTap = null;
      if (!mounted || _hasSelection || _childHandled) return;
      widget.onTap(pos);
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _mousePointer) _mousePointer = null;
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      focusNode: widget.selectionFocusNode,
      onSelectionChanged: _onSelectionChanged,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(
                    supportedDevices: _touchPointerKinds,
                  ),
                  (recognizer) => recognizer.onTapUp = _onTouchTapUp,
                ),
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Snapshot of the exact scroll viewport anchor taken right before committing
/// a new [NovelLayout], preserving lead padding, sub-item pixel offset, and
/// translation-line position so off-screen updates never jump back or cancel
/// an active scroll.
class NovelScrollRelayoutAnchor {
  const NovelScrollRelayoutAnchor._({
    required this.prevPixels,
    required this.inLeadPadding,
    this.anchor,
    this.deltaInItem = 0,
    this.translationParagraphId,
    this.translationLineOrdinal = 0,
  });

  final double prevPixels;
  final bool inLeadPadding;
  final NovelAnchor? anchor;
  final double deltaInItem;
  final String? translationParagraphId;
  final int translationLineOrdinal;

  static NovelScrollRelayoutAnchor capture({
    required NovelScrollColumn column,
    required double pixels,
    required double leadExtra,
  }) {
    if (pixels < leadExtra) {
      return NovelScrollRelayoutAnchor._(
        prevPixels: pixels,
        inLeadPadding: true,
      );
    }
    final content = math.max(0.0, pixels - leadExtra);
    final item = column.itemAt(content);
    final delta = (content - column.offsetOf(item)).clamp(
      0.0,
      column.extentAt(item),
    );
    final line = column.items[item].line;
    if (line != null && line.isTranslation) {
      var ordinal = 0;
      for (var i = item - 1; i >= 0; i--) {
        final earlier = column.items[i].line;
        if (earlier != null &&
            earlier.isTranslation &&
            earlier.paragraphId == line.paragraphId) {
          ordinal += 1;
        } else if (earlier != null && earlier.paragraphId != line.paragraphId) {
          break;
        }
      }
      return NovelScrollRelayoutAnchor._(
        prevPixels: pixels,
        inLeadPadding: false,
        anchor: line.startAnchor,
        deltaInItem: delta,
        translationParagraphId: line.paragraphId,
        translationLineOrdinal: ordinal,
      );
    }
    return NovelScrollRelayoutAnchor._(
      prevPixels: pixels,
      inLeadPadding: false,
      anchor: column.anchorAt(item),
      deltaInItem: delta,
    );
  }

  double resolveTarget({
    required NovelScrollColumn nextColumn,
    required double leadExtra,
    required double maxExtent,
  }) {
    if (inLeadPadding) return prevPixels.clamp(0.0, maxExtent);
    var item = -1;
    final trPid = translationParagraphId;
    if (trPid != null) {
      var seen = 0;
      for (var i = 0; i < nextColumn.items.length; i++) {
        final line = nextColumn.items[i].line;
        if (line != null && line.isTranslation && line.paragraphId == trPid) {
          if (seen == translationLineOrdinal) {
            item = i;
            break;
          }
          seen += 1;
          item = i;
        }
      }
    }
    if (item < 0) {
      item = anchor == null ? 0 : nextColumn.itemForAnchor(anchor!);
    }
    if (item <= 0 && deltaInItem <= 0) return 0.0;
    return (nextColumn.offsetOf(item) + deltaInItem + leadExtra).clamp(
      0.0,
      maxExtent,
    );
  }

  /// Applies any >= 0.5px layout shift above the viewport to [controller],
  /// skipping no-op relayouts so flings and smooth-wheel animations keep going.
  void applyToController({
    required ScrollController controller,
    required NovelScrollColumn nextColumn,
    required double leadExtra,
    required void Function(void Function()) runAsLayoutEcho,
  }) {
    final position = controller.position;
    final target = resolveTarget(
      nextColumn: nextColumn,
      leadExtra: leadExtra,
      maxExtent: position.maxScrollExtent,
    );
    final shift = target - prevPixels;
    if (shift.abs() < 0.5) return;
    final corrected = (position.pixels + shift).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((corrected - position.pixels).abs() < 0.5) return;
    if (position.isScrollingNotifier.value) {
      position.correctBy(corrected - position.pixels);
    } else {
      runAsLayoutEcho(() => controller.jumpTo(corrected));
    }
  }
}
