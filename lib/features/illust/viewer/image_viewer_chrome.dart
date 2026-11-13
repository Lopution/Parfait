part of 'image_viewer_page.dart';

/// Manga-reader page scrubber: dragging shows the target page's thumbnail
/// and label above the track; releasing jumps straight there.
class _PageScrubber extends StatelessWidget {
  const _PageScrubber({
    super.key,
    required this.count,
    required this.current,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.pageLabel,
    required this.thumbnailUrl,
  });

  static const double thumbnailExtent = 72;
  static const double _trackHeight = 48;

  final int count;
  final int current;
  final int value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final String Function(int page) pageLabel;
  final String? Function(int page) thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    const color = FuncTokens.white;
    final dragging = value != current;
    final thumbnail = thumbnailUrl(value);
    return SizedBox(
      height: _trackHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                // No scrim under the chrome: the light run and the dark
                // rest of the track, plus a shadowed thumb, keep the
                // position legible on white and black artwork alike.
                activeTrackColor: color,
                inactiveTrackColor: FuncTokens.imageControl,
                thumbColor: color,
                overlayColor: color.withValues(alpha: 0.16),
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 7,
                  elevation: 2,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
              ),
              // No label: the bubble above is the page indicator, so the
              // slider's own value indicator would be a second one.
              child: AppSlider(
                min: 0,
                max: (count - 1).toDouble(),
                divisions: count - 1,
                value: value.toDouble(),
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
          // After the slider: appearing mid-drag, it must not shift the
          // slider's slot, or the slider is rebuilt and the drag dies.
          // Above the track, over the artwork: display only, so it may
          // overflow the scrubber's own box.
          if (dragging)
            Positioned(
              left: 0,
              right: 0,
              bottom: _trackHeight,
              child: Center(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: FuncTokens.imageControl,
                    borderRadius: FuncShape.control,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(FuncSpacing.xs),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (thumbnail != null)
                          ClipRRect(
                            borderRadius: FuncShape.badge,
                            child: SizedBox.square(
                              dimension: thumbnailExtent,
                              child: PixivImage.avatar(
                                thumbnail,
                                key: ValueKey(thumbnail),
                                size: thumbnailExtent,
                              ),
                            ),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FuncSpacing.xs,
                            vertical: FuncSpacing.xxs,
                          ),
                          child: Text(
                            pageLabel(value),
                            style: const TextStyle(
                              color: color,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Slides the viewer down off the screen while its route pops, for a
/// drag-to-dismiss without a Hero to carry the image back. The slide runs
/// from wherever the pop starts, so it never jumps.
class _ExitSlide extends StatefulWidget {
  const _ExitSlide({required this.slidesOut, required this.child});

  /// Asked as the pop starts, before the viewer can rebuild.
  final bool Function() slidesOut;
  final Widget child;

  @override
  State<_ExitSlide> createState() => _ExitSlideState();
}

class _ExitSlideState extends State<_ExitSlide> {
  Animation<double>? _route;

  /// The route value when the pop began; null while not popping.
  double? _popFrom;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = RouteAnimationScope.of(context);
    if (identical(route, _route)) return;
    _route?.removeStatusListener(_onStatus);
    _route = route?..addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    final route = _route;
    if (route == null || !mounted) return;
    final popFrom = status == AnimationStatus.reverse && widget.slidesOut()
        ? route.value
        : null;
    if (popFrom != _popFrom) setState(() => _popFrom = popFrom);
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_onStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final popFrom = _popFrom;
    // One shape whether popping or not, so the start of a pop never
    // rebuilds the viewer below.
    return AnimatedBuilder(
      animation: _route ?? kAlwaysCompleteAnimation,
      builder: (context, child) {
        final route = _route;
        final progress = route == null || popFrom == null || popFrom <= 0
            ? 0.0
            : ((popFrom - route.value) / popFrom).clamp(0.0, 1.0);
        return FractionalTranslation(
          translation: Offset(0, MotionTokens.pageCurve.transform(progress)),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

enum _ChromeEdge { top, bottom }

/// One chrome bar (top or bottom). Hidden chrome stays mounted — dropping
/// the subtree raced the semantics flush ('!child.attached' in
/// SemanticsNode._replaceChildren when a page turn lands mid-hide), so the
/// bar fades via Opacity and drops out of semantics/hit-testing instead.
class _ChromeEdgeBar extends StatefulWidget {
  const _ChromeEdgeBar({
    required this.visible,
    required this.edge,
    required this.child,
  });

  final bool visible;
  final _ChromeEdge edge;
  final Widget child;

  @override
  State<_ChromeEdgeBar> createState() => _ChromeEdgeBarState();
}

class _ChromeEdgeBarState extends State<_ChromeEdgeBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      value: widget.visible ? 1 : 0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = MotionTokens.resolve(context, MotionTokens.chrome);
  }

  @override
  void didUpdateWidget(covariant _ChromeEdgeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
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
    return Positioned(
      top: widget.edge == _ChromeEdge.top ? 0 : null,
      bottom: widget.edge == _ChromeEdge.bottom ? 0 : null,
      left: 0,
      right: 0,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Opacity(
              opacity: _controller.value,
              // alwaysIncludeSemantics: ExcludeSemantics owns the hidden
              // state; the Opacity stays semantics-complete so the tree
              // never sees a node vanish mid-flush.
              alwaysIncludeSemantics: true,
              child: child,
            ),
            // The stage is always black, whatever the theme.
            child: ArtworkControls(
              glyph: FuncTokens.onImageControl,
              halo: Colors.black,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// The jump sheet's thumbnail grid: about [_cellExtent] per cell, at least
/// [_minColumns] across. The current page carries a primary outline and
/// opens scrolled into view.
class _PageJumpGrid extends StatefulWidget {
  const _PageJumpGrid({
    required this.count,
    required this.current,
    required this.thumbnailFor,
    required this.onSelected,
  });

  static const double _cellExtent = 96;
  static const int _minColumns = 3;
  static const double _spacing = FuncSpacing.sm;
  static const double _padding = FuncSpacing.lg;

  /// The grid scrolls past this share of the screen height.
  static const double _maxHeightFactor = 0.6;

  final int count;
  final int current;
  final String Function(int page) thumbnailFor;
  final ValueChanged<int> onSelected;

  @override
  State<_PageJumpGrid> createState() => _PageJumpGridState();
}

class _PageJumpGridState extends State<_PageJumpGrid> {
  ScrollController? _scroll;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = _PageJumpGrid._spacing;
        const padding = _PageJumpGrid._padding;
        final inner = constraints.maxWidth - padding * 2;
        final columns = math.max(
          _PageJumpGrid._minColumns,
          ((inner + spacing) / (_PageJumpGrid._cellExtent + spacing)).floor(),
        );
        final cell = (inner - spacing * (columns - 1)) / columns;
        final rows = (widget.count / columns).ceil();
        final rowExtent = cell + spacing;
        final contentHeight = rows * rowExtent - spacing + padding * 2;
        final height = math.min(
          contentHeight,
          MediaQuery.sizeOf(context).height * _PageJumpGrid._maxHeightFactor,
        );
        // The current page's row opens with one row of context above it.
        final currentRow = widget.current ~/ columns;
        _scroll ??= ScrollController(
          initialScrollOffset: ((currentRow - 1) * rowExtent).clamp(
            0,
            math.max(0, contentHeight - height),
          ),
        );
        return SizedBox(
          height: height,
          child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(padding),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
            ),
            itemCount: widget.count,
            itemBuilder: (context, page) => _PageThumbnail(
              page: page,
              count: widget.count,
              url: widget.thumbnailFor(page),
              extent: cell,
              current: page == widget.current,
              onTap: () => widget.onSelected(page),
            ),
          ),
        );
      },
    );
  }
}

class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({
    required this.page,
    required this.count,
    required this.url,
    required this.extent,
    required this.current,
    required this.onTap,
  });

  static const double _outline = 2;
  static const double _badgeInset = FuncSpacing.xs;

  final int page;
  final int count;
  final String url;
  final double extent;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The viewer stage is always black: the brand pink, not the light
    // theme's deeper accent, reads on it (THEME-14).
    final primary = FuncSemanticTokens.of(context).brand;
    return Semantics(
      key: ValueKey('viewer-jump-page-$page'),
      container: true,
      button: true,
      selected: current,
      label: context.l10n.viewerPageLabel(page + 1, count),
      onTap: onTap,
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: FuncShape.control,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PixivImage.feed(url, layoutWidth: extent),
            PositionedDirectional(
              start: _badgeInset,
              bottom: _badgeInset,
              child: EntityBadge(label: '${page + 1}'),
            ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap),
            ),
            if (current)
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: FuncShape.control,
                    border: Border.all(color: primary, width: _outline),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
