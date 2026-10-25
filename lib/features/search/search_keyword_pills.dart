import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/func_semantic_tokens.dart';
import '../../core/search/search_keywords.dart';

/// A pill's padding beside its keyword.
const double _pillInset = FuncSpacing.xs + FuncSpacing.xxs;

/// A pill's padding above and below its keyword's line.
const double _pillOutset = FuncSpacing.xxs;

/// Spacing added to a half-width space so it holds both neighbours'
/// padding and a gap: the space itself is about a quarter em. A full-width
/// space is already an em wide and is left as it is.
const double _spaceSpacing = 2 * _pillInset;

/// [text] styled for [SearchKeywordPills]: half-width spaces spaced out,
/// and the IME's [composing] range underlined as a plain field does.
TextSpan searchKeywordSpan(
  String text,
  TextStyle? style, {
  TextRange composing = TextRange.empty,
}) {
  if (text.isEmpty) return TextSpan(style: style, text: text);
  bool composingAt(int i) =>
      composing.isValid && composing.start <= i && i < composing.end;
  final runs = <TextSpan>[];
  var start = 0;
  for (var i = 1; i <= text.length; i++) {
    if (i < text.length &&
        (text[i] == ' ') == (text[start] == ' ') &&
        composingAt(i) == composingAt(start)) {
      continue;
    }
    runs.add(
      TextSpan(
        text: text.substring(start, i),
        style: TextStyle(
          letterSpacing: text[start] == ' ' ? _spaceSpacing : null,
          decoration: composingAt(start) ? TextDecoration.underline : null,
        ),
      ),
    );
    start = i;
  }
  return TextSpan(style: style, children: runs);
}

/// The search field's text: keywords spaced out for their pills.
class SearchKeywordController extends TextEditingController {
  SearchKeywordController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) => searchKeywordSpan(
    text,
    style,
    composing: withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty,
  );
}

/// Draws each keyword of [text] on a pill behind the text field or the
/// text in [child], where that text lays it out. The text stays plain
/// text: editing, the caret and screen readers see no pills. [finishedOnly]
/// leaves out the keyword still being typed at the end.
///
/// The text must be spaced with [searchKeywordSpan], which leaves room for
/// the pills between keywords.
class SearchKeywordPills extends SingleChildRenderObjectWidget {
  const SearchKeywordPills({
    super.key,
    required this.text,
    this.finishedOnly = false,
    required super.child,
  });

  final String text;
  final bool finishedOnly;

  List<TextRange> get _ranges =>
      finishedOnly ? finishedKeywordRanges(text) : keywordRanges(text);

  @override
  RenderObject createRenderObject(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    return _RenderKeywordPills(
      ranges: _ranges,
      fill: tokens.surface,
      outline: tokens.divider,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final tokens = FuncSemanticTokens.of(context);
    (renderObject as _RenderKeywordPills)
      ..ranges = _ranges
      ..fill = tokens.surface
      ..outline = tokens.divider;
  }
}

class _RenderKeywordPills extends RenderProxyBox {
  _RenderKeywordPills({
    required List<TextRange> ranges,
    required Color fill,
    required Color outline,
  }) : _ranges = ranges,
       _fill = Paint()..color = fill,
       _shape = StadiumBorder(side: BorderSide(color: outline));

  List<TextRange> _ranges;
  set ranges(List<TextRange> value) {
    if (listEquals(value, _ranges)) return;
    _ranges = value;
    markNeedsPaint();
  }

  final Paint _fill;
  set fill(Color value) {
    if (_fill.color == value) return;
    _fill.color = value;
    markNeedsPaint();
  }

  /// A pill's shape and outline.
  StadiumBorder _shape;
  set outline(Color value) {
    if (_shape.side.color == value) return;
    _shape = StadiumBorder(side: BorderSide(color: value));
    markNeedsPaint();
  }

  /// The field's scroll: the editable repaints alone when it scrolls, so
  /// the pills under it follow by listening.
  ViewportOffset? _scroll;

  void _follow(ViewportOffset? scroll) {
    if (identical(scroll, _scroll)) return;
    _scroll?.removeListener(markNeedsPaint);
    _scroll = scroll?..addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _follow(null);
    super.detach();
  }

  /// The field's editable, or else the first paragraph: the text the
  /// pills sit under.
  RenderBox? _findText() {
    RenderEditable? editable;
    RenderParagraph? paragraph;
    void visit(RenderObject node) {
      if (editable != null) return;
      if (node is RenderEditable) {
        editable = node;
        return;
      }
      if (paragraph == null && node is RenderParagraph) paragraph = node;
      node.visitChildren(visit);
    }

    final child = this.child;
    if (child != null) visit(child);
    return editable ?? paragraph;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final text = _ranges.isEmpty ? null : _findText();
    _follow(text is RenderEditable ? text.offset : null);
    if (text != null && text.hasSize) _paintPills(context.canvas, offset, text);
    super.paint(context, offset);
  }

  void _paintPills(Canvas canvas, Offset offset, RenderBox text) {
    final transform = text.getTransformTo(this);
    final line = MatrixUtils.transformRect(
      transform,
      Offset.zero & text.size,
    ).shift(offset);
    canvas
      ..save()
      ..clipRect(line.inflate(_pillInset));
    for (final range in _ranges) {
      final selection = TextSelection(
        baseOffset: range.start,
        extentOffset: range.end,
      );
      final boxes = switch (text) {
        RenderEditable() => text.getBoxesForSelection(selection),
        RenderParagraph() => text.getBoxesForSelection(selection),
        _ => const <TextBox>[],
      };
      if (boxes.isEmpty) continue;
      var left = boxes.first.left;
      var right = boxes.first.right;
      for (final box in boxes) {
        if (box.left < left) left = box.left;
        if (box.right > right) right = box.right;
      }
      // Elided by an ellipsis.
      if (right - left < 1) continue;
      final span = MatrixUtils.transformRect(
        transform,
        Rect.fromLTRB(left, 0, right, text.size.height),
      ).shift(offset);
      final pill = Rect.fromLTRB(
        span.left - _pillInset,
        line.top - _pillOutset,
        span.right + _pillInset,
        line.bottom + _pillOutset,
      );
      canvas.drawPath(_shape.getOuterPath(pill), _fill);
      _shape.paint(canvas, pill);
    }
    canvas.restore();
  }
}
