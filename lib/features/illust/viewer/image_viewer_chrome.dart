part of 'image_viewer_page.dart';

/// Manga-reader page scrubber: dragging or pointer hovering shows the target
/// page's thumbnail and label above the track; releasing jumps straight there.
class _PageScrubber extends StatefulWidget {
  const _PageScrubber({
    super.key,
    required this.count,
    required this.current,
    required this.value,
    required this.dragging,
    required this.onChanged,
    required this.onChangeEnd,
    required this.pageLabel,
    required this.thumbnailUrl,
    this.onHoverPageChanged,
  });

  static const double thumbnailExtent = 72;
  static const double _trackHeight = 48;
  static const double _trackHorizontalInset = 24;

  final int count;
  final int current;
  final int value;
  final bool dragging;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final String Function(int page) pageLabel;
  final String? Function(int page) thumbnailUrl;
  final ValueChanged<int?>? onHoverPageChanged;

  @override
  State<_PageScrubber> createState() => _PageScrubberState();
}

class _PageScrubberState extends State<_PageScrubber> {
  int? _hoverPage;

  void _setHoverPage(int? page) {
    if (_hoverPage == page) return;
    setState(() => _hoverPage = page);
    widget.onHoverPageChanged?.call(page);
  }

  int _pageForOffset(double dx, double width) {
    if (widget.count <= 1) return 0;
    final effectiveWidth = math.max(
      1.0,
      width - _PageScrubber._trackHorizontalInset * 2,
    );
    final fraction =
        ((dx - _PageScrubber._trackHorizontalInset) / effectiveWidth).clamp(
          0.0,
          1.0,
        );
    return (fraction * (widget.count - 1)).round().clamp(0, widget.count - 1);
  }

  @override
  Widget build(BuildContext context) {
    const color = FuncTokens.white;
    final previewPage = widget.dragging ? widget.value : _hoverPage;
    final thumbnail = previewPage == null
        ? null
        : widget.thumbnailUrl(previewPage);
    final horizontalFraction = previewPage == null || widget.count <= 1
        ? 0.5
        : previewPage / (widget.count - 1);
    return LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        onHover: (event) => _setHoverPage(
          _pageForOffset(event.localPosition.dx, constraints.maxWidth),
        ),
        onExit: (_) => _setHoverPage(null),
        child: SizedBox(
          height: _PageScrubber._trackHeight,
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
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: _PageScrubber._trackHorizontalInset,
                    ),
                  ),
                  // No label: the bubble above is the page indicator, so the
                  // slider's own value indicator would be a second one.
                  child: AppSlider.scrubber(
                    min: 0,
                    max: (widget.count - 1).toDouble(),
                    divisions: widget.count - 1,
                    value: widget.value.toDouble(),
                    onChanged: widget.onChanged,
                    onChangeEnd: widget.onChangeEnd,
                  ),
                ),
              ),
              // After the slider: appearing mid-drag/hover, it must not shift
              // the slider's slot, or the slider is rebuilt and the drag dies.
              // Above the track, over the artwork: display only, so it may
              // overflow the scrubber's own box.
              if (previewPage != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: _PageScrubber._trackHeight,
                  child: IgnorePointer(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FuncSpacing.sm,
                      ),
                      child: Align(
                        alignment: Alignment(horizontalFraction * 2 - 1, 1),
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
                                      dimension: _PageScrubber.thumbnailExtent,
                                      child: PixivImage.avatar(
                                        thumbnail,
                                        key: ValueKey(thumbnail),
                                        size: _PageScrubber.thumbnailExtent,
                                      ),
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: FuncSpacing.xs,
                                    vertical: FuncSpacing.xxs,
                                  ),
                                  child: Text(
                                    widget.pageLabel(previewPage),
                                    style: const TextStyle(
                                      color: color,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wide-layout docked info panel beside the viewer stage (`>= 840dp`).
class _ViewerInfoPanel extends StatelessWidget {
  const _ViewerInfoPanel({
    required this.entity,
    required this.onClose,
    required this.onSaveAll,
    required this.onOpenDetail,
    required this.onOpenAuthor,
    required this.onOpenTag,
  });

  static const double width = 320;

  final IllustEntity entity;
  final VoidCallback onClose;
  final VoidCallback onSaveAll;
  final VoidCallback onOpenDetail;
  final VoidCallback onOpenAuthor;
  final ValueChanged<String> onOpenTag;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final darkTheme = darkReplicaThemeOf(context);
    final createDate = DateTime.tryParse(entity.createDate ?? '');
    final dateText = createDate == null
        ? null
        : AppFormat.date(context, createDate);
    final plainCaption = captionPlainText(entity.caption);
    final metaParts = <String>[
      ?dateText,
      '#${entity.id}',
      l10n.illustPagesTotal(entity.pageCount),
      if (entity.width > 0 && entity.height > 0)
        '${entity.width} × ${entity.height}',
    ];

    return Theme(
      data: darkTheme,
      child: Builder(
        builder: (context) {
          final colorScheme = Theme.of(context).colorScheme;
          final textTheme = Theme.of(context).textTheme;
          final showCaptionDivider =
              DesktopChromeMetrics.maybeOf(context)?.showCustomButtons ?? false;
          return SizedBox(
            key: const Key('viewer-info-panel'),
            width: width,
            child: Material(
              color: colorScheme.surfaceContainerLow,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: colorScheme.outlineVariant),
                  ),
                ),
                child: SafeArea(
                  left: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showCaptionDivider)
                        Divider(
                          height: 1,
                          color: colorScheme.outlineVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          FuncSpacing.md,
                          FuncSpacing.sm,
                          FuncSpacing.xs,
                          FuncSpacing.xs,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.viewerInfo,
                                style: textTheme.titleSmall,
                              ),
                            ),
                            IconButton(
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).closeButtonTooltip,
                              onPressed: onClose,
                              icon: const Icon(UiIcons.chevronRight),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: SelectionArea(
                          child: ListView(
                            padding: const EdgeInsets.all(FuncSpacing.md),
                            children: [
                              Text(entity.title, style: textTheme.titleMedium),
                              const SizedBox(height: FuncSpacing.sm),
                              InkWell(
                                borderRadius: FuncShape.control,
                                onTap: entity.user.id > 0 ? onOpenAuthor : null,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: FuncSpacing.xs,
                                  ),
                                  child: Row(
                                    children: [
                                      SelectionContainer.disabled(
                                        child: PersonAvatar(
                                          imageUrl: entity.user.profileImageUrl,
                                          radius: 16,
                                        ),
                                      ),
                                      const SizedBox(width: FuncSpacing.sm),
                                      Expanded(
                                        child: Text(
                                          entity.user.name,
                                          style: textTheme.bodyMedium?.copyWith(
                                            color: colorScheme.primary,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: FuncSpacing.xs),
                              Text(
                                metaParts.join(' · '),
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (entity.tags.isNotEmpty) ...[
                                const SizedBox(height: FuncSpacing.md),
                                Wrap(
                                  spacing: FuncSpacing.xs,
                                  runSpacing: FuncSpacing.xs,
                                  children: [
                                    for (final tag in entity.tags)
                                      ActionChip(
                                        label: Text('#${tag.name}'),
                                        onPressed: () => onOpenTag(tag.name),
                                      ),
                                  ],
                                ),
                              ],
                              if (plainCaption.isNotEmpty) ...[
                                const SizedBox(height: FuncSpacing.md),
                                Text(plainCaption, style: textTheme.bodySmall),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      ViewerInfoPanelActions(
                        entity: entity,
                        onSaveAll: onSaveAll,
                        onOpenDetail: onOpenDetail,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
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
      child: ExcludeFocus(
        excluding: !widget.visible,
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
      ),
    );
  }
}

class _ViewerPageNavButton extends StatelessWidget {
  const _ViewerPageNavButton({
    super.key,
    required this.visible,
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final bool visible;
  final AlignmentGeometry alignment;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isStart = alignment == AlignmentDirectional.centerStart;
    return Positioned.directional(
      textDirection: Directionality.of(context),
      start: isStart ? FuncSpacing.md : null,
      end: isStart ? null : FuncSpacing.md,
      top: 0,
      bottom: 0,
      child: Center(
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: IgnorePointer(
              ignoring: !visible,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: MotionTokens.resolve(context, MotionTokens.chrome),
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    color: FuncTokens.white,
                    tooltip: tooltip,
                    onPressed: onPressed,
                    icon: Icon(icon),
                  ),
                ),
              ),
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
