part of 'illust_detail_page.dart';

/// A short first illustration on a narrow screen, alone or opening a set,
/// sits where centering it in this share of the viewport puts it: a very
/// wide image at the top was hard to see and to tap. Its slot ends with the
/// image, so the title follows right under it. Manga reads page after
/// page, so its first page keeps its natural height.
const _shortFirstImageSlotFactor = 0.7;

/// Where the first image sits in the detail scroll. The narrow layout
/// starts the artwork below the status bar, which the top bar keeps opaque;
/// it may run under the see-through toolbar, so overlays on it start below
/// the toolbar, and the bar draws in as it leaves.
class _FirstImageLayout {
  _FirstImageLayout._({
    required this.useTwoPane,
    required this.statusInset,
    required this.topChrome,
    required this.collapsible,
    required this.shownPages,
    required this.natural,
    required this.slots,
    required this.alone,
  });

  factory _FirstImageLayout.of(
    BuildContext context,
    IllustEntity entity, {
    required bool expanded,
  }) {
    final viewport = HomeShellChrome.contentSizeOf(context);
    final useTwoPane = AppBreakpoints.useTwoPaneDetailOf(context, viewport);
    // An illustration set opens on its first image; manga reads in full.
    final collapsible =
        entity.type == IllustType.illust && entity.pageCount > 1;
    final aspectRatio = entity.pageAspectRatioAt(0);
    final panoramaHeight = DetailPageImage.panoramaHeight(
      viewport,
      viewport.width,
      aspectRatio,
    );
    final natural = panoramaHeight ?? viewport.width / aspectRatio;
    // A panorama already has its own viewport; the reading slot is for an
    // ordinary short illustration on a phone held upright. On wider
    // single-column screens it only opens a gap above the image.
    final slots =
        !useTwoPane &&
        viewport.width < AppBreakpoints.medium &&
        entity.type == IllustType.illust &&
        !entity.isUgoira &&
        panoramaHeight == null;
    final band = slots
        ? math.max(
                0.0,
                viewport.height * _shortFirstImageSlotFactor - natural,
              ) /
              2
        : 0.0;
    return _FirstImageLayout._(
      useTwoPane: useTwoPane,
      statusInset: useTwoPane ? 0 : MediaQuery.paddingOf(context).top,
      topChrome: MediaQuery.paddingOf(context).top + kToolbarHeight,
      collapsible: collapsible,
      shownPages: collapsible && !expanded ? 1 : entity.pageCount,
      natural: natural,
      slots: slots,
      alone: band + natural,
    );
  }

  final bool useTwoPane;
  final double statusInset;
  final double topChrome;
  final bool collapsible;
  final int shownPages;

  /// The first image's height at the full width, or its panorama
  /// viewport's.
  final double natural;

  /// Whether the first image goes through the reading slot.
  final bool slots;

  /// The first image's extent when shown alone: the band above a short
  /// image, then the image.
  final double alone;

  /// The band only frames an image shown alone: an expanded set reads from
  /// the top, page after page.
  double get extent => shownPages == 1 ? alone : natural;

  /// The image's top in the scroll: at the end of its slot.
  double get top => statusInset + extent - natural;

  /// Whether the image starts under the toolbar, so the bar's controls
  /// need lifting off it.
  bool get artworkUnderBar => top < topChrome;

  /// How much of the image's top the toolbar covers.
  double get artworkUnderBarExtent => math.max(0.0, topChrome - top);

  /// Where the bar starts drawing in: over the last toolbar height before
  /// the image leaves the top, or, for an image below the bar, before it
  /// reaches the bar.
  double get immersionStart => math.max(
    0,
    (artworkUnderBar ? statusInset + extent : top) - topChrome - kToolbarHeight,
  );

  /// Where a collapsed set ends: page 1's bottom just under the top bar.
  double get firstPageEnd => math.max(0, statusInset + alone - topChrome);
}

/// Where a freshly built narrow detail page draws [entity]'s first image:
/// its top in the scroll and its height (a panorama's viewport height). The
/// pager's stand-in for a page not built yet draws there, so a swipe lands
/// on the picture the page then builds instead of jumping into place.
({double top, double height}) detailFirstImageFrame(
  BuildContext context,
  IllustEntity entity,
) {
  final layout = _FirstImageLayout.of(context, entity, expanded: false);
  return (top: layout.top, height: layout.natural);
}

extension _IllustDetailContent on _IllustDetailPageState {
  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    IllustEntity entity, {
    bool detailReady = false,
  }) {
    // 三档质量之详情档: the detail-page hero follows the user's detail
    // quality once the detail payload is merged; before that it shows the
    // feed-provided hero URL so the Hero flight stays on one cache key.
    final detailQuality = ref.watch(detailQualityProvider);
    String? detailUrlFor(int index) =>
        detailReady ? entity.detailUrlAt(index, detailQuality) : null;

    // The media column and the metadata column are the same slivers in both
    // layouts; only their arrangement differs (single scroll vs two panes).
    final layout = _FirstImageLayout.of(
      context,
      entity,
      expanded: _pagesExpanded,
    );
    final collapsible = layout.collapsible;
    final shownPages = layout.shownPages;
    final statusInset = layout.statusInset;
    final topChrome = layout.topChrome;
    final slotsFirstImage = layout.slots;
    final firstImageExtent = layout.extent;
    final firstPageEnd = layout.firstPageEnd;
    final prevTopChromeExtent = _topChromeExtent;
    _topChromeExtent = layout.useTwoPane ? 0 : topChrome;
    _immersionStart = layout.immersionStart;
    // Layout changes move both without a scroll: expanding the set, pages
    // taking their real ratios.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateImmersion();
      _updatePagesToggleOnScreen();
    });

    final imageSlivers = <Widget>[
      if (statusInset > 0)
        SliverToBoxAdapter(child: SizedBox(height: statusInset)),
      if (entity.isUgoira)
        SliverToBoxAdapter(
          child: TickerPartition(
            child: UgoiraViewer(
              illustId: entity.id,
              // Same contract as DetailPageImage: the viewer keeps the
              // feed card's URL for the opening Hero flight and only
              // upgrades to the detail quality once the route settles —
              // without the guard a cached detail payload would swap
              // the cover mid-flight onto an undecoded entry (the
              // grey-shuttle regression).
              // Ugoira has no page selection: long-press does not enter the
              // download mode and the GIF export action stays always visible.
              previewUrl: entity.imageUrls.large,
              detailUrl: detailUrlFor(0),
              heroImageUrl: widget.heroImageUrl,
              heroTier: widget.heroImageUrl == null
                  ? null
                  : entity.imageTierOf(widget.heroImageUrl!),
              width: entity.width,
              height: entity.height,
              heroTag: illustHeroTag(widget.heroScope, entity.id),
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              heroDecodeWidth: widget.heroImageDecodeWidth,
              heroPopUrl: widget.heroImageUrl,
              heroPopDecodeWidth: widget.heroImageDecodeWidth,
              tier: entity.imageTierOf(
                detailUrlFor(0) ?? entity.imageUrls.large,
              ),
            ),
          ),
        )
      else
        // Single and multi-page works share this one sliver: a snapshot
        // whose page count differs from the detail payload (a restored
        // feed, a work edited since) would otherwise swap the sliver type
        // mid-flight and orphan the Hero's landing spot.
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => TickerPartition(
              // A switch back from the two-pane layout brings the list to
              // the image the pager was on (NAV-21).
              child: KeyedSubtree(
                key: _pageKeys.putIfAbsent(index, () => GlobalKey()),
                child: Padding(
                  padding: index == shownPages - 1
                      ? EdgeInsets.zero
                      : const EdgeInsets.only(bottom: FuncSpacing.sm),
                  child: VisibilityDetector(
                    key: ValueKey('illust-visibility-${entity.id}-$index'),
                    onVisibilityChanged: (info) =>
                        _onPageVisibility(index, info),
                    child: DetailPageImage(
                      key: ValueKey<Object?>('illust-page-${entity.id}-$index'),
                      entity: entity,
                      index: index,
                      heroTag: index == 0
                          ? illustHeroTag(widget.heroScope, entity.id)
                          : '${illustHeroTag(widget.heroScope, entity.id)}-$index',
                      heroScope: widget.heroScope,
                      heroImageUrl: index == 0 ? widget.heroImageUrl : null,
                      heroImageDecodeWidth: index == 0
                          ? widget.heroImageDecodeWidth
                          : null,
                      detailUrl: detailUrlFor(index),
                      downloadMode: _downloadMode,
                      selected: _selectedPages?.contains(index) ?? false,
                      onToggleSelect: () => _togglePageSelected(index),
                      onLongPress: _enterDownloadMode,
                      placeholderOnly: !detailReady && index > 0,
                      overlayTopInset: index == 0
                          ? layout.artworkUnderBarExtent
                          : 0,
                      imageSlotHeight: index == 0 && slotsFirstImage
                          ? firstImageExtent
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            // All pages appear immediately: before the detail payload the
            // non-first pages render as neutral placeholders (uniform
            // ratio), and the real images/proportions replace them when
            // the detail API payload is merged.
            childCount: shownPages,
          ),
        ),
      // Selecting keeps every page on screen: no folding mid-selection.
      if (collapsible && !(_pagesExpanded && _downloadMode))
        SliverToBoxAdapter(
          child: KeyedSubtree(
            key: _pagesToggleKey,
            child: _PagesToggleButton(
              count: entity.pageCount,
              expanded: _pagesExpanded,
              onPressed: _pagesExpanded
                  ? () => _collapsePages(firstPageEnd)
                  : _expandPages,
            ),
          ),
        ),
    ];
    // Each section a TickerPartition. The order is fixed: a conditional
    // entry among uniform wrappers would shift every section after it onto
    // a different child.
    final metaSlivers = [
      for (final (section, readable) in <(Widget, bool)>[
        // Official client behaviour: when the work belongs to an
        // illust series, the series card sits between the image pages
        // and the info block (name, 第 N 话, prev/next navigation).
        (
          IllustSeriesSection(
            illustId: widget.illustId,
            outsideSeries: entity.outsideSeries,
          ),
          false,
        ),
        // The ⋮ menu's artwork-info item scrolls to the anchor
        // (ensureVisible by context — no controller takeover, risks R9).
        // The caption reads in the article column on a wide single
        // scroll, like the comments below (R5).
        (
          InfoBlock(
            anchorKey: _infoAnchorKey,
            entity: entity,
            blockMode: _blockMode,
            onToggleBlockMode: _toggleBlockMode,
          ),
          true,
        ),
        // Comment preview and the author's other works; like related works,
        // each asks for its data only once it is on screen.
        (
          CommentsPreviewSlivers(
            illustId: widget.illustId,
            onCompose: _openComposer,
          ),
          true,
        ),
        (AuthorWorksSlivers(entity: entity), false),
        // Official client behaviour: "関連作品" below the caption/tags,
        // paginated as the user scrolls to the bottom of the page.
        (RelatedIllustsSlivers(illustId: widget.illustId), false),
      ])
        TickerPartition(
          child: readable ? _ArticleTextWidth(child: section) : section,
        ),
      // The page's end clears the floating action bar.
      SliverToBoxAdapter(
        child: SizedBox(height: DetailActionBar.restingExtent(context)),
      ),
    ];

    // Related works paginate as the user reaches the bottom of the page
    // (official client behaviour). loadMore is internally guarded against
    // re-entry / exhausted state.
    bool onScrollNotification(ScrollNotification notification) {
      _onBarScroll(notification);
      final metrics = notification.metrics;
      if (metrics.maxScrollExtent > 0 &&
          metrics.pixels >= metrics.maxScrollExtent - 500) {
        // The first page is requested by the related section once it is
        // on screen; this check must never be the first request, so it
        // only looks at a list that already exists. loadMore asserts an
        // AsyncData state (it calls requireValue), so it also waits for
        // the first page to land. A list the filters hid entirely loads on
        // only from its button (FEED-22).
        final related = relatedIllustControllerProvider(widget.illustId);
        if (ref.read(related.exists) &&
            ref.read(related).value?.isAllHidden == false) {
          unawaited(ref.read(related.notifier).loadMore());
        }
      }
      return false;
    }

    final metaScroll = NotificationListener<ScrollNotification>(
      onNotification: onScrollNotification,
      child: SmoothWheelScroll(
        controller: _metaScroll,
        // The first frame of a detail page is its push: only the
        // viewport builds there.
        builder: (context, controller, physics) => DeferredCacheScrollView(
          controller: controller,
          physics: physics,
          slivers: metaSlivers,
        ),
      ),
    );

    final contentSize = HomeShellChrome.contentSizeOf(context);
    final twoPane = AppBreakpoints.useTwoPaneDetailOf(context, contentSize);
    // Reduced motion turned on mid-fade lands the page at once (MOTION-02):
    // the preference only rebuilds, and the fade starts on a layout switch.
    if (_layoutFade.value < 1 &&
        MotionTokens.resolve(context, MotionTokens.branchSwitch) ==
            Duration.zero) {
      _layoutFade.value = 1;
    }
    // A switch between the layouts opens on the image the other one showed,
    // and carries the meta/comments scroll position across the breakpoint.
    final wasTwoPane = _lastTwoPane;
    _lastTwoPane = twoPane;
    if (wasTwoPane == true && !twoPane) {
      final metaOffset = _metaScroll.hasClients
          ? _metaScroll.offset
          : _lastMetaOffset;
      if (metaOffset > 0) {
        _scheduleNarrowMetaSync(metaOffset);
      } else {
        _scheduleNarrowReveal(entity);
      }
      _fadeLayoutIn(context);
    } else if (wasTwoPane == false && twoPane) {
      // Read the image on screen now, not the trackers' last report: they
      // run on their own timer and may not have reached this build yet.
      final index = _narrowTopImage(layout);
      if (index != null) _imageIndex = index;
      final metaOffset = _captureNarrowMetaOffset(prevTopChromeExtent);
      _lastMetaOffset = metaOffset;
      if (metaOffset > 0) _scheduleMetaSync(metaOffset);
      _fadeLayoutIn(context);
    }
    // Hidden, not removed, in the download mode: it slides out and back.
    // On a two-pane layout it sits inside the artwork pane, so the bar is
    // centred on the images rather than on the information column.
    final actionBar = PositionedDirectional(
      start: 0,
      end: 0,
      bottom: 0,
      // Out of the way of a flight over it.
      child: HeroChrome(
        child: DetailActionBar(
          entity: entity,
          visibility: _barVisibility,
          onDownload: () => unawaited(_downloadAll(entity)),
        ),
      ),
    );
    // Over the column the comments belong to: the whole narrow page, the
    // meta column of the two-pane one.
    final composerLayer = Positioned.fill(
      child: DetailCommentLayer(
        illustId: widget.illustId,
        composerKey: _composerKey,
        onClose: _closeComposer,
      ),
    );
    final content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_downloadMode) _exitDownloadMode();
      },
      child: twoPane
          ? AdaptiveTwoPane(
              // The stage tints the letterbox around the artwork, so the
              // page counter sits on the stage rather than on blank page:
              // the work's own ambient light (THEME-19), or a plain tier
              // while pages are being selected.
              primary: Stack(
                fit: StackFit.expand,
                children: [
                  if (!_downloadMode)
                    AmbientWash(
                      blur: 40,
                      image: PixivImage.providerFor(
                        context,
                        widget.heroImageUrl ?? entity.imageUrls.medium,
                        decodeWidth: 96,
                      ),
                    )
                  else
                    ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                    ),
                  DetailImagePager(
                    entity: entity,
                    detailUrlFor: detailUrlFor,
                    downloadMode: _downloadMode,
                    selectedPages: _selectedPages ?? const <int>{},
                    onToggleSelect: _togglePageSelected,
                    onLongPress: _enterDownloadMode,
                    heroTag: illustHeroTag(widget.heroScope, entity.id),
                    heroScope: widget.heroScope,
                    initialPage: _imageIndex,
                    onPageChanged: (page) => _imageIndex = page,
                    heroImageUrl: widget.heroImageUrl,
                    heroImageDecodeWidth: widget.heroImageDecodeWidth,
                  ),
                  actionBar,
                ],
              ),
              // The meta column owns the window's right edge, so its
              // scrollbar lands where the main scrollbar belongs. The
              // action bar centres on this column, clear of the artwork.
              secondary: Stack(
                fit: StackFit.expand,
                children: [
                  Scrollbar(
                    // Shown on touch too; the mouse one would be a second.
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: metaScroll,
                    ),
                  ),
                  if (_composing) composerLayer,
                ],
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: onScrollNotification,
                  child: SmoothWheelScroll(
                    controller: _narrowScroll,
                    builder: (context, controller, physics) =>
                        DeferredCacheScrollView(
                          controller: controller,
                          physics: physics,
                          slivers: [...imageSlivers, ...metaSlivers],
                        ),
                  ),
                ),
                // The shared page counter floats over the top-end of the
                // artwork while an image page is actually on screen and
                // fades out once the last page scrolls away. The
                // pill is IgnorePointer, so taps fall through to the
                // artwork below. Selection mode hides it: each page's
                // badge occupies the same top-end corner. Single-page
                // works get no pill.
                if (!entity.isUgoira && entity.pageCount > 1 && !_downloadMode)
                  Positioned.fill(
                    top: topChrome,
                    // Out of the way of a flight over it.
                    child: HeroChrome(
                      child: ListenableBuilder(
                        listenable: Listenable.merge([
                          _topVisiblePage,
                          _pagesToggleOnScreen,
                        ]),
                        builder: (context, _) => DetailPageCounter(
                          page: _topVisiblePage.value,
                          count: entity.pageCount,
                          onCollapse:
                              collapsible &&
                                  _pagesExpanded &&
                                  !_pagesToggleOnScreen.value
                              ? () => _collapsePages(firstPageEnd)
                              : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
    // The two layouts are different trees (the single column scrolls the
    // information under the images, the two-pane one gives it its own
    // column), so a switch fades the page in rather than swapping it in one
    // frame. Only the new tree is in the widget tree: both show the same
    // work and one route cannot hold the same hero tag twice.
    final page = FadeTransition(
      key: const ValueKey('detail-layout-fade'),
      opacity: _layoutFadeOpacity,
      child: twoPane
          ? content
          : Stack(
              fit: StackFit.expand,
              children: [content, actionBar, if (_composing) composerLayer],
            ),
    );
    final container = ProviderScope.containerOf(context, listen: false);
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return page;
    final pixivEnabled = ref.watch(pixivHistoryEnabledProvider);
    final localEnabled = ref.watch(localHistoryEnabledProvider);
    final repository = ref.watch(historyRepositoryProvider);
    final remote = pixivEnabled ? ref.watch(pixivHistoryRemoteProvider) : null;
    // A pager's prebuilt neighbour is not viewed. The Builder takes the
    // activity dependency, so a page change does not rebuild the page.
    return Builder(
      builder: (context) => HistoryVisibility(
        active: DetailPageActivity.of(context),
        accountId: accountId,
        contentType: HistoryContentType.illust,
        contentId: entity.id,
        snapshot: snapshotFromIllust(entity),
        localHistoryEnabled: localEnabled,
        pixivHistoryEnabled: pixivEnabled,
        repository: repository,
        remote: remote,
        isAccountCurrent: () =>
            container.read(historyAccountIdProvider) == accountId,
        child: page,
      ),
    );
  }
}

/// Centres a section's sliver at the article text width when the scroll is
/// wider than it. A single-column detail on a wide surface keeps its
/// caption and comments at a readable line length while the images stay
/// full width; a two-pane info column is already narrower, so nothing
/// changes there.
class _ArticleTextWidth extends StatelessWidget {
  const _ArticleTextWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SliverWidthBuilder(
    builder: (context, width) {
      final inset = (width - ContentWidths.article) / 2;
      return SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset > 0 ? inset : 0),
        sliver: child,
      );
    },
  );
}

/// Under the first image of a collapsed illustration set: shows the rest.
/// Once expanded it follows the last page and folds the set back.
class _PagesToggleButton extends StatelessWidget {
  const _PagesToggleButton({
    required this.count,
    required this.expanded,
    required this.onPressed,
  });

  final int count;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // One node: the button announces whether the set is expanded.
    return MergeSemantics(
      child: Semantics(
        expanded: expanded,
        child: TextButton.icon(
          key: Key(expanded ? 'illust-collapse-pages' : 'illust-expand-pages'),
          style: TextButton.styleFrom(
            minimumSize: const Size.fromHeight(kMinInteractiveDimension),
          ),
          onPressed: onPressed,
          icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          iconAlignment: IconAlignment.end,
          label: Text(
            expanded
                ? context.l10n.detailCollapsePages
                : context.l10n.detailExpandPages(count),
          ),
        ),
      ),
    );
  }
}

/// The detail page's own ⋮ actions: share, the bookmark sheet (the
/// heart's long-press), the page-selection entry (multi-page works only)
/// and the artwork-info jump.
enum _DetailMenuAction { share, editBookmark, selectPages, info }

/// The ⋮ menu holding the less-frequent detail actions. Every entry
/// carries an icon plus its localized text label — nothing here depends
/// on a long-press to be discoverable (R3). Besides the page's own
/// actions it carries the feed card's long-press actions for this work,
/// which run as they do from a card.
class _DetailMoreMenu extends ConsumerWidget {
  const _DetailMoreMenu({
    required this.entity,
    required this.actions,
    required this.onSelected,
  });

  final IllustEntity entity;

  /// [_DetailMenuAction]s and [CardAction]s, in menu order.
  final List<Object> actions;

  /// Runs the page's own actions. Receives the ⋮ button's own context so
  /// share can anchor its popover to the button.
  final void Function(BuildContext buttonContext, _DetailMenuAction action)
  onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final container = ProviderScope.containerOf(context);
    final cardState = CardActionState.ofRef(ref);
    // Named as the sheet it opens is. The heart skips its sheet while a
    // request is in flight; so does the menu.
    final (bookmarked: bookmarked, unsettled: bookmarkUnsettled) = ref.watch(
      bookmarkStoreProvider.select((store) {
        final entry = store[BookmarkKey(BookmarkEntityType.illust, entity.id)];
        return (
          bookmarked: entry?.shown ?? false,
          unsettled: entry?.isUnsettled ?? false,
        );
      }),
    );
    AppMenuEntry<Object> entryOf(Object action) => switch (action) {
      _DetailMenuAction.share => AppMenuEntry(
        value: action,
        icon: Icons.share_outlined,
        label: l10n.cardActionShare,
      ),
      _DetailMenuAction.editBookmark => AppMenuEntry(
        value: action,
        icon: Icons.favorite_border,
        label: bookmarked ? l10n.bookmarkEditTitle : l10n.bookmarkIllust,
        enabled: !bookmarkUnsettled,
      ),
      _DetailMenuAction.selectPages => AppMenuEntry(
        value: action,
        icon: Icons.checklist_outlined,
        label: l10n.downloadSelectPages,
      ),
      _DetailMenuAction.info => AppMenuEntry(
        value: action,
        icon: Icons.info_outline,
        label: l10n.illustInfoJump,
      ),
      final CardAction card => AppMenuEntry(
        value: card,
        icon: card.iconFor(cardState, entity),
        label: card.labelFor(cardState, entity, l10n),
      ),
      _ => throw ArgumentError.value(action, 'action', 'not a menu action'),
    };
    return AppMenuButton<Object>(
      onSelected: (buttonContext, action) => switch (action) {
        final _DetailMenuAction own => onSelected(buttonContext, own),
        final CardAction card => unawaited(
          card.run(context, container, entity),
        ),
        _ => throw ArgumentError.value(action, 'action', 'not a menu action'),
      },
      entries: [for (final action in actions) entryOf(action)],
    );
  }
}
