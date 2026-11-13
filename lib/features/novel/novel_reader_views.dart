part of 'novel_reader.dart';

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
