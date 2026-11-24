part of 'novel_reader_stage.dart';

extension _NovelReaderStageSheets on _NovelReaderStageState {
  /// Page-jump sheet: the slider only moves a local preview — the reader
  /// stays put until confirm, so a cancelled drag never rewinds the user.
  /// Chapter rows jump immediately on tap (D2/D4).
  void _showProgressSheet(BuildContext context) {
    final l10n = context.l10n;
    final pageCount = _pageCount;
    final chapters = _readerHandle.chapters?.call() ?? const [];
    var preview = _displayPage;
    _showReaderSideSheet(
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            // Same formula as the footer/bottom-bar readout — the sheet
            // and the bar must report the same percent for the same
            // page, not position-over-range.
            final percent = pageCount <= 1
                ? 100
                : ((preview + 1) / pageCount * 100).round();
            void jumpTo(int page) {
              Navigator.of(sheetContext).pop();
              _readerHandle.goToPage?.call(page, animate: false);
            }

            final desktop = useWideOverlay(context);
            return Padding(
              padding: MediaQuery.of(context).padding,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  FuncSpacing.xl,
                  desktop ? FuncSpacing.lg : 0,
                  FuncSpacing.xl,
                  FuncSpacing.xl,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ReaderSheetHeader(
                      title: l10n.novelReadingProgress,
                      showClose: desktop,
                      onClose: () => Navigator.of(sheetContext).pop(),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: AppSlider(
                            value: preview.toDouble().clamp(
                              0.0,
                              (pageCount - 1).toDouble(),
                            ),
                            min: 0,
                            max: (pageCount - 1).toDouble(),
                            onChanged: pageCount <= 1
                                ? null
                                : (v) =>
                                      setSheetState(() => preview = v.round()),
                          ),
                        ),
                        const SizedBox(width: FuncSpacing.sm),
                        Text(
                          '${preview + 1}/$pageCount · $percent%',
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: Text(l10n.cancel),
                        ),
                        const SizedBox(width: FuncSpacing.sm),
                        FilledButton(
                          onPressed: () => jumpTo(preview),
                          child: Text(l10n.confirm),
                        ),
                      ],
                    ),
                    // The slider and its buttons stay put; on a short
                    // window the bookmark and the chapters below them
                    // scroll inside what is left of the sheet.
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ?_markerSection(onJump: jumpTo),
                            // D4: the TOC section only exists when the
                            // document actually has chapters — local TXT
                            // files never do.
                            if (chapters.isNotEmpty) ...[
                              const SizedBox(height: FuncSpacing.sm),
                              const Divider(),
                              const SizedBox(height: FuncSpacing.sm),
                              Text(
                                l10n.novelChapters,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: FuncSpacing.xs),
                              _chapterList(context, chapters, onTap: jumpTo),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// The account's bookmark, for a Pixiv novel read with an account. It
  /// marks the Pixiv page of the reader's place: the paragraph its top
  /// line belongs to.
  Widget? _markerSection({required ValueChanged<int> onJump}) {
    final marker = widget.spec.marker;
    final document = widget.spec.novel.markup;
    if (marker == null || document == null) return null;
    final starts = document.pixivPageStarts;
    final anchor = _readerHandle.displayAnchor?.call() ?? _anchor;
    return _NovelMarkerSection(
      binding: marker,
      pixivPages: starts.length,
      current: switch (anchor) {
        final anchor? => document.pixivPageOf(anchor.paragraphId) ?? 1,
        null => 1,
      },
      screenPageOf: (page) => _readerHandle.layout?.call()?.pageIndexForAnchor(
        NovelAnchor(
          paragraphId: starts[math.min(page, starts.length) - 1],
          offset: 0,
        ),
      ),
      onJump: onJump,
    );
  }

  /// The chapters, the one the reader is in marked; up to half the
  /// screen tall, so a long table shows many at once. A short window
  /// (a turned phone) lowers the floor to two rows, so the table fits
  /// beside the controls instead of making the sheet scroll.
  Widget _chapterList(
    BuildContext context,
    List<({String title, int pageIndex})> chapters, {
    required ValueChanged<int> onTap,
  }) {
    final window = MediaQuery.sizeOf(context).height;
    final floor = window < AppBreakpoints.compactHeight
        ? 2 * _NovelChapterList.rowExtent
        : _chapterListMinHeight;
    return _NovelChapterList(
      chapters: chapters,
      current: chapters.lastIndexWhere(
        (chapter) => chapter.pageIndex <= _displayPage,
      ),
      height: math.min(
        chapters.length * _NovelChapterList.rowExtent,
        math.max(floor, window / 2),
      ),
      onTap: onTap,
    );
  }

  static const _chapterListMinHeight = 240.0;

  void _showReaderSettings(BuildContext anchorContext) {
    final l10n = anchorContext.l10n;
    _showReaderSettingsPopover(
      anchorContext: anchorContext,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void preview(NovelReaderSettings next) {
              if (next == _settings) return;
              setSheetState(() {});
              _previewSettings(next);
            }

            void apply(NovelReaderSettings next) {
              setSheetState(() {});
              _applySettings(next);
            }

            double quantizeLineHeight(double v) => (v * 10).round() / 10;

            // The sheet is at most 9/16 of the screen: on a turned phone
            // the settings scroll inside it.
            final desktop = useWideOverlay(context);
            final theme = Theme.of(context);
            final chipLabelStyle = theme.textTheme.labelLarge;
            return SingleChildScrollView(
              padding: MediaQuery.of(context).padding,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  FuncSpacing.lg,
                  desktop ? FuncSpacing.lg : 0,
                  FuncSpacing.lg,
                  FuncSpacing.xl,
                ),
                child: ChipTheme(
                  data: ChipTheme.of(context).copyWith(
                    labelStyle: chipLabelStyle,
                    secondaryLabelStyle: chipLabelStyle,
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.sm,
                      vertical: FuncSpacing.xs,
                    ),
                    labelPadding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.xxs,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (desktop) ...[
                        _ReaderSheetHeader(
                          title: l10n.novelReaderSettings,
                          onClose: () => Navigator.of(sheetContext).pop(),
                        ),
                        const SizedBox(height: FuncSpacing.xs),
                      ],
                      _SettingsSliderRow(
                        label: l10n.novelFontSize,
                        value: _settings.fontSize,
                        min: NovelReaderSettings.minFontSize,
                        max: NovelReaderSettings.maxFontSize,
                        divisions:
                            (NovelReaderSettings.maxFontSize -
                                    NovelReaderSettings.minFontSize)
                                .round(),
                        onChanged: (v) => preview(
                          _settings.copyWith(fontSize: v.roundToDouble()),
                        ),
                        onChangeEnd: (v) => apply(
                          _settings.copyWith(fontSize: v.roundToDouble()),
                        ),
                      ),
                      // Slider range == the model's clamp range (1.3–2.4):
                      // the old 1.1–2.2 span was a dead zone at the bottom
                      // and unreachable at the top.
                      _SettingsSliderRow(
                        label: l10n.novelLineHeight,
                        value: _settings.lineHeight,
                        min: NovelReaderSettings.minLineHeight,
                        max: NovelReaderSettings.maxLineHeight,
                        divisions: 11,
                        onChanged: (v) => preview(
                          _settings.copyWith(lineHeight: quantizeLineHeight(v)),
                        ),
                        onChangeEnd: (v) => apply(
                          _settings.copyWith(lineHeight: quantizeLineHeight(v)),
                        ),
                      ),
                      const SizedBox(height: FuncSpacing.md),
                      Wrap(
                        spacing: FuncSpacing.sm,
                        runSpacing: FuncSpacing.xs,
                        children: [
                          for (final (pageTurn, label) in [
                            (NovelPageTurn.scroll, l10n.novelPageTurnScroll),
                            (NovelPageTurn.pages, l10n.novelPageTurnPages),
                          ])
                            AppChoiceChip(
                              label: Text(label),
                              selected: _settings.pageTurn == pageTurn,
                              onSelected: () =>
                                  apply(_settings.copyWith(pageTurn: pageTurn)),
                            ),
                        ],
                      ),
                      const SizedBox(height: FuncSpacing.sm),
                      Text(
                        l10n.novelSpreadMode,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: FuncSpacing.xs),
                      Wrap(
                        spacing: FuncSpacing.sm,
                        runSpacing: FuncSpacing.xs,
                        children: [
                          for (final (mode, label) in [
                            (NovelSpreadMode.off, l10n.novelSpreadOff),
                            (NovelSpreadMode.auto, l10n.novelSpreadAuto),
                            (
                              NovelSpreadMode.landscape,
                              l10n.novelSpreadLandscape,
                            ),
                            (NovelSpreadMode.always, l10n.novelSpreadAlways),
                          ])
                            AppChoiceChip(
                              label: Text(label),
                              selected: _settings.spreadMode == mode,
                              onSelected: () => apply(
                                _settings.copyWith(
                                  spreadMode: mode,
                                  pageTurn:
                                      mode != NovelSpreadMode.off &&
                                          _settings.pageTurn ==
                                              NovelPageTurn.scroll
                                      ? NovelPageTurn.pages
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: FuncSpacing.sm),
                      Wrap(
                        spacing: FuncSpacing.sm,
                        runSpacing: FuncSpacing.xs,
                        children: [
                          for (final (themeOption, label) in [
                            (NovelReaderTheme.system, l10n.novelThemeSystem),
                            (NovelReaderTheme.paper, l10n.novelThemePaper),
                            (NovelReaderTheme.sepia, l10n.novelThemeSepia),
                            (NovelReaderTheme.night, l10n.novelThemeNight),
                          ])
                            AppChoiceChip(
                              label: Text(label),
                              selected: _settings.theme == themeOption,
                              onSelected: () =>
                                  apply(_settings.copyWith(theme: themeOption)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ReaderSheetHeader extends StatelessWidget {
  const _ReaderSheetHeader({
    required this.title,
    required this.onClose,
    this.showClose = true,
  });

  final String title;
  final VoidCallback onClose;
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    final titleWidget = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    );
    if (!showClose) return titleWidget;
    return Row(
      children: [
        Expanded(child: titleWidget),
        IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: onClose,
          visualDensity: VisualDensity.compact,
          icon: const Icon(UiIcons.close),
        ),
      ],
    );
  }
}

/// One labelled slider row inside the reader settings sheet: each
/// typography knob maps to a continuous slider.
class _SettingsSliderRow extends StatelessWidget {
  const _SettingsSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueText = value.toStringAsFixed(
      value == value.roundToDouble() ? 0 : 1,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            const SizedBox(width: FuncSpacing.sm),
            Text(
              valueText,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        AppSlider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }
}

enum _ChromeEdge { top, bottom }

/// One sliding chrome bar driven by the stage's controller. The bar stays
/// hittable until the hide animation fully completes — a tap landing
/// mid-slide still hits the button instead of leaking through to the
/// page-turn zone. Once dismissed it stays mounted offstage: no paint,
/// hits, semantics or focus.
class _ChromeBar extends StatelessWidget {
  const _ChromeBar({
    required this.animation,
    required this.edge,
    required this.shown,
    required this.child,
  });

  final Animation<double> animation;
  final _ChromeEdge edge;
  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isTop = edge == _ChromeEdge.top;
    // A tween chain, not a CurvedAnimation: this runs on every build and
    // holds nothing to dispose.
    final slide = Tween<Offset>(
      begin: Offset(0, isTop ? -1 : 1),
      end: Offset.zero,
    ).chain(CurveTween(curve: MotionTokens.chromeCurve)).animate(animation);
    // No SafeArea here: the bar surface must paint edge-to-edge so its
    // background covers the system inset. The inset padding lives inside
    // each bar's Material instead — the bar slides from the screen edge
    // while its controls stay clear of the gesture strip.
    final bar = SlideTransition(position: slide, child: child);
    return Positioned(
      top: isTop ? 0 : null,
      bottom: isTop ? null : 0,
      left: 0,
      right: 0,
      // RenderOpacity drops the child's semantics below full opacity;
      // the boundary flipping on each animation frame trips the
      // semantics attach assert during repeated hide/reveal cycles.
      // Pinning the boundary keeps one stable semantics parent — the
      // dismissed bar still leaves the semantics tree, offstage.
      child: Visibility(
        visible: shown,
        // Tickers stop while dismissed: a kept bar may hold a spinner
        // (series loading, page translating).
        maintainState: true,
        child: FadeTransition(
          opacity: animation,
          alwaysIncludeSemantics: true,
          child: bar,
        ),
      ),
    );
  }
}

/// The progress sheet's chapters, the [current] one marked and scrolled
/// a row below the top when the sheet opens. Rows are of one height, so
/// its offset is known before layout.
class _NovelChapterList extends StatefulWidget {
  const _NovelChapterList({
    required this.chapters,
    required this.current,
    required this.height,
    required this.onTap,
  });

  static const rowExtent = 48.0;

  final List<({String title, int pageIndex})> chapters;
  final int current;
  final double height;
  final ValueChanged<int> onTap;

  @override
  State<_NovelChapterList> createState() => _NovelChapterListState();
}

class _NovelChapterListState extends State<_NovelChapterList> {
  late final _controller = ScrollController(
    initialScrollOffset: ((widget.current - 1) * _NovelChapterList.rowExtent)
        .clamp(
          0.0,
          widget.chapters.length * _NovelChapterList.rowExtent - widget.height,
        ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ListView.builder(
        controller: _controller,
        primary: false,
        itemCount: widget.chapters.length,
        itemBuilder: (context, index) {
          final chapter = widget.chapters[index];
          return ListTile(
            minTileHeight: _NovelChapterList.rowExtent,
            selected: index == widget.current,
            contentPadding: EdgeInsets.zero,
            title: Text(
              chapter.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              '${chapter.pageIndex + 1}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: () => widget.onTap(chapter.pageIndex),
          );
        },
      ),
    );
  }
}

/// The progress sheet's bookmark row. Without a marker it offers to mark
/// the reader's Pixiv page; with one it names the screen page the marker
/// starts on (a tap goes there), offers to move it to the reader's Pixiv
/// page and to remove it. A single-page novel without a marker shows
/// nothing: a marker could only point at its start. A write on its way
/// disables the row; a failed one says so and changes nothing.
class _NovelMarkerSection extends ConsumerWidget {
  const _NovelMarkerSection({
    required this.binding,
    required this.pixivPages,
    required this.current,
    required this.screenPageOf,
    required this.onJump,
  });

  final NovelMarkerBinding binding;
  final int pixivPages;

  /// The Pixiv page (1-based) the reader is on.
  final int current;
  final int? Function(int pixivPage) screenPageOf;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final page = ref.watch(binding.page);
    final pending = ref.watch(binding.pending);
    if (page == null && pixivPages <= 1) return const SizedBox.shrink();
    Future<void> write(int? next) async {
      final failed = deferErrorSnackBar(
        context,
        action: l10n.novelMarkerFailed,
      );
      try {
        await binding.write(next);
      } on Object catch (error, stack) {
        failed(error, stack);
      }
    }

    const progress = AppSpinner(size: 18, strokeWidth: 2);
    final screenPage = page == null ? null : screenPageOf(page);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: FuncSpacing.sm),
        const Divider(),
        if (page == null)
          ListTile(
            enabled: !pending,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(AppIcons.watchLaterAdd),
            title: Text(l10n.novelMarkerAdd),
            trailing: pending ? progress : null,
            onTap: () => unawaited(write(current)),
          )
        else
          ListTile(
            enabled: !pending,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(AppIcons.watchLaterFilled),
            title: Text(l10n.novelMarker),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (page != current)
                  TextButton(
                    onPressed: pending ? null : () => unawaited(write(current)),
                    child: Text(l10n.novelMarkerMove),
                  ),
                if (screenPage != null)
                  Text(
                    '${screenPage + 1}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (pending)
                  const SizedBox.square(
                    dimension: kMinInteractiveDimension,
                    child: Center(child: progress),
                  )
                else
                  IconButton(
                    tooltip: l10n.novelMarkerDelete,
                    onPressed: () => unawaited(write(null)),
                    icon: const Icon(AppIcons.watchLaterRemove),
                  ),
              ],
            ),
            onTap: screenPage == null ? null : () => onJump(screenPage),
          ),
      ],
    );
  }
}
