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
    final slices = groupNovelParagraphSlices(page.lines);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: style.horizontalPadding,
        vertical: style.verticalPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final slice in slices) ...[
            NovelParagraphSliceView(
              slice: slice,
              style: styles[slice.kind],
              color: color,
              novel: novel,
              onImageTap: onImageTap,
              onLinkTap: onLinkTap,
              openAddresses: openAddresses,
            ),
            if (slice.spacingAfter > 0) SizedBox(height: slice.spacingAfter),
          ],
        ],
      ),
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

/// Paints [child] only between the page's top and bottom safe margins, fading
/// lines smoothly across [fadeExtent] once scrolling begins so glyphs never
/// slice into raw half-lines or spill under the status bar and progress hint.
/// Touches still land anywhere, so a drag can start in a margin.
class _TextAreaClip extends SingleChildRenderObjectWidget {
  const _TextAreaClip({
    required this.bottomInset,
    required super.child,
    this.cleanBottom,
    this.controller,
  });

  static const double topSafe = FuncSpacing.xs;
  static const double fadeHeight = FuncSpacing.lg;

  final double bottomInset;
  final double? cleanBottom;
  final ScrollController? controller;

  @override
  _RenderTextAreaClip createRenderObject(BuildContext context) =>
      _RenderTextAreaClip(
        bottomInset: bottomInset,
        cleanBottom: cleanBottom,
        controller: controller,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTextAreaClip renderObject,
  ) {
    renderObject
      ..bottomInset = bottomInset
      ..cleanBottom = cleanBottom
      ..controller = controller;
  }
}

class _RenderTextAreaClip extends RenderProxyBox {
  _RenderTextAreaClip({
    required double bottomInset,
    required double? cleanBottom,
    required ScrollController? controller,
  }) : _bottomInset = bottomInset,
       _cleanBottom = cleanBottom,
       _controller = controller;

  double _bottomInset;
  set bottomInset(double value) {
    if (value == _bottomInset) return;
    _bottomInset = value;
    markNeedsPaint();
  }

  double? _cleanBottom;
  set cleanBottom(double? value) {
    if (value == _cleanBottom) return;
    _cleanBottom = value;
    markNeedsPaint();
  }

  ScrollController? _controller;
  set controller(ScrollController? value) {
    if (identical(value, _controller)) return;
    if (attached) _controller?.removeListener(markNeedsPaint);
    _controller = value;
    if (attached) _controller?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  final _clip = LayerHandle<ClipRectLayer>();
  final _shader = LayerHandle<ShaderMaskLayer>();

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _controller?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null || size.isEmpty) {
      _clip.layer = null;
      _shader.layer = null;
      return;
    }
    var pixels = 0.0;
    var extentAfter = double.infinity;
    final controller = _controller;
    if (controller != null && controller.hasClients) {
      final position = controller.position;
      if (position.hasPixels) pixels = math.max(0.0, position.pixels);
      if (position.hasContentDimensions) {
        extentAfter = math.max(0.0, position.extentAfter);
      }
    }
    const fadeExtent = _TextAreaClip.fadeHeight;
    final scrollIn = (pixels / fadeExtent).clamp(0.0, 1.0);
    final scrollRemain = extentAfter.isFinite
        ? (extentAfter / fadeExtent).clamp(0.0, 1.0)
        : 1.0;
    final topEdge = (pixels > 0 ? _TextAreaClip.topSafe : 0.0).clamp(
      0.0,
      size.height,
    );
    final maxBottom = (size.height - _bottomInset).clamp(topEdge, size.height);
    final cleanBottom = _cleanBottom?.clamp(topEdge, maxBottom) ?? maxBottom;
    final bottomEdge = ui.lerpDouble(cleanBottom, maxBottom, scrollIn)!;
    final visibleHeight = bottomEdge - topEdge;
    if (visibleHeight <= 0) {
      _clip.layer = null;
      _shader.layer = null;
      return;
    }
    final maxFade = visibleHeight / 2;
    final topFade = (fadeExtent * scrollIn).clamp(0.0, maxFade);
    final bottomFade = (fadeExtent * scrollIn * scrollRemain).clamp(
      0.0,
      maxFade,
    );
    final clipRect = Rect.fromLTRB(0, topEdge, size.width, bottomEdge);
    _clip.layer = context.pushClipRect(needsCompositing, offset, clipRect, (
      context,
      innerOffset,
    ) {
      if (topFade <= 0.5 && bottomFade <= 0.5) {
        _shader.layer = null;
        context.paintChild(child, innerOffset);
        return;
      }
      final topStop = (topFade / visibleHeight).clamp(0.0, 0.5);
      final bottomStop = (1.0 - bottomFade / visibleHeight).clamp(0.5, 1.0);
      final shaderLayer = (_shader.layer ??= ShaderMaskLayer())
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, visibleHeight),
          [
            topFade > 0.5 ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            bottomFade > 0.5
                ? const Color(0x00FFFFFF)
                : const Color(0xFFFFFFFF),
          ],
          [0.0, topStop, bottomStop, 1.0],
        )
        ..maskRect = Rect.fromLTWH(
          innerOffset.dx,
          innerOffset.dy + topEdge,
          size.width,
          visibleHeight,
        )
        ..blendMode = BlendMode.dstIn;
      context.pushLayer(
        shaderLayer,
        (context, childOffset) => context.paintChild(child, childOffset),
        innerOffset,
      );
    }, oldLayer: _clip.layer);
  }

  @override
  void dispose() {
    _clip.layer = null;
    _shader.layer = null;
    super.dispose();
  }
}
