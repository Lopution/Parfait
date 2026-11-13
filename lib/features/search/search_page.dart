import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/haptics/app_haptics.dart';
import '../../app/layout/sliver_width_builder.dart';
import '../../app/motion/press_scale.dart';
import '../../app/motion/state_fade.dart';
import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/display_actions.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/spotlight_article_card.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/home_branch_stack.dart';
import '../../app/widgets/page_header.dart';
import '../../app/widgets/search_field_button.dart';
import '../../app/widgets/skeleton/func_skeleton.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../core/search/search_models.dart';
import '../../core/search/search_repository.dart';
import '../../core/search/search_trending_controller.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/spotlight/spotlight_feed_controller.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_store.dart';
import '../../l10n/context.dart';
import 'search_section_header.dart';
import 'search_text.dart';

export 'search_input_engine.dart';
export 'search_input_page.dart';

/// Search guide shown by the Home bottom-navigation entry: a search field
/// and the reverse-image camera in the app bar, then one tab per work kind
/// (illust & manga, novel) with that kind's trending tags. The illust tab
/// leads with the newest Spotlight articles.
///
/// Restoration tiers: the selected tab is session memory —
/// `trendingKindProvider` resets to illust after process death, and
/// `trendingTagsProvider` stays non-autoDispose on purpose so leaving the
/// branch does not re-request. Each tab's scroll offset rides its own
/// `PageStorageKey` + `restorationId`; the explicit scroll controllers
/// exist so the branch and tab re-tap can address the visible list (on
/// desktop `SmoothWheelScroll` would otherwise own a private controller
/// `PrimaryScrollController` cannot reach).
class SearchHomePage extends ConsumerStatefulWidget {
  const SearchHomePage({super.key});

  @override
  ConsumerState<SearchHomePage> createState() => _SearchHomePageState();
}

class _SearchHomePageState extends ConsumerState<SearchHomePage>
    with SingleTickerProviderStateMixin {
  static const _types = [SearchResultType.illust, SearchResultType.novel];

  late final TabController _tabController;
  final _scrollControllers = <SearchResultType, ScrollController>{};
  final _loaded = <SearchResultType>{};
  ReTapChannel? _reTapChannel;

  /// A context inside the Scaffold's notification scope (see
  /// [announceTabScroll]).
  late BuildContext _notificationContext;

  SearchResultType get _active => _types[_tabController.index];

  @override
  void initState() {
    super.initState();
    final initial = _types.indexOf(ref.read(trendingKindProvider));
    _tabController = TabController(
      length: _types.length,
      vsync: this,
      initialIndex: math.max(0, initial),
    )..addListener(_onTabChanged);
    _loaded.add(_active);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final channel = HomeBranchStack.reTapOf(context);
    if (identical(channel, _reTapChannel)) return;
    _reTapChannel?.removeListener(_onBranchReTap);
    _reTapChannel = channel;
    _reTapChannel?.addListener(_onBranchReTap);
  }

  @override
  void dispose() {
    _reTapChannel?.removeListener(_onBranchReTap);
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  ScrollController _scrollControllerFor(SearchResultType type) =>
      _scrollControllers.putIfAbsent(
        type,
        () => ScrollController(
          onAttach: (_) {
            // A first-visited tab mounts after the switch announcement.
            if (type == _active) {
              announceTabScroll(
                _notificationContext,
                _scrollControllers[type]!,
              );
            }
          },
        ),
      );

  void _onTabChanged() {
    final type = _active;
    if (ref.read(trendingKindProvider) == type) return;
    ref.read(trendingKindProvider.notifier).select(type);
    setState(() => _loaded.add(type));
    announceTabScroll(_notificationContext, _scrollControllerFor(type));
  }

  bool _prepareTab(int index) {
    final type = _types[index];
    if (_loaded.contains(type)) return false;
    setState(() => _loaded.add(type));
    return true;
  }

  void _onTabTap(int index) {
    if (index == _tabController.index && !_tabController.indexIsChanging) {
      reTapScrollToTop(context, _scrollControllerFor(_active));
    }
  }

  /// Branch-level re-tap (bottom bar same-destination tap): the channel
  /// fired after the branch stack popped, so the scroll lands post-frame
  /// on the now-visible root — a vetoed pop leaves a pushed route on top
  /// and `isCurrent` fails the scroll harmlessly.
  void _onBranchReTap() {
    if (_reTapChannel?.branch !=
        BranchRootScope.maybeOf(context)?.branchIndex) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      reTapScrollToTop(context, _scrollControllerFor(_active));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tabs = AppTabBar(
      controller: _tabController,
      onTap: _onTabTap,
      labels: [for (final type in _types) searchText(context, type.labelKey)],
    );
    final camera = IconButton(
      tooltip: l10n.searchReverseImage,
      onPressed: () => openReverseImageSearch(context),
      icon: const Icon(Icons.photo_camera_outlined),
    );
    // The wide header puts the kind tabs on the title row and the shared
    // search field next to the camera (R7); a phone keeps the field over
    // the tabs.
    final wide = PageHeader.isWide(context);
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: wide
          ? AppTopBar(
              titleSpacing: 0,
              title: tabs,
              actions: [
                camera,
                HeaderSearch(type: _active),
              ],
            )
          : AppTopBar(
              title: SearchFieldButton(
                // The input page body spells out what can be searched.
                text: l10n.searchBarHint,
                isHint: true,
                onTap: () => openSearchInput(context, type: _active),
              ),
              actions: [camera],
              bottom: tabs,
            ),
      body: Builder(
        builder: (context) {
          _notificationContext = context;
          return TabSwipeSwitcher(
            tabController: _tabController,
            prepareTab: _prepareTab,
            child: TabSlideStack(
              controller: _tabController,
              children: [
                for (final type in _types)
                  if (_loaded.contains(type))
                    _TrendingTab(
                      key: ValueKey(type),
                      type: type,
                      scrollController: _scrollControllerFor(type),
                    )
                  else
                    const SizedBox.shrink(),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Short compatibility name for callers that treat the Home search guide as
/// the feature's root page.
class SearchPage extends SearchHomePage {
  const SearchPage({super.key});
}

/// One tab of the search guide: the Spotlight section (illust tab only),
/// then the trending tags for [type].
class _TrendingTab extends ConsumerWidget {
  const _TrendingTab({
    super.key,
    required this.type,
    required this.scrollController,
  });

  final SearchResultType type;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trending = ref.watch(trendingTagsProvider(type));
    return SmoothWheelScroll(
      controller: scrollController,
      builder: (context, controller, physics) => CustomScrollView(
        key: PageStorageKey('search-home-${type.name}'),
        restorationId: 'search-home-${type.name}',
        controller: controller,
        physics: physics,
        slivers: [
          if (type == SearchResultType.illust)
            const SliverToBoxAdapter(child: _SpotlightSection()),
          SliverToBoxAdapter(
            child: SearchSectionHeader(title: context.l10n.searchTrending),
          ),
          StateFade.sliver(
            kind: trending.isLoading,
            sliver: trending.when(
              loading: () => const _TrendingGridSkeleton(),
              error: (error, _) => SliverToBoxAdapter(
                child: FeedError(
                  title: context.l10n.searchTrendingFailed,
                  error: error,
                  retryLabel: context.l10n.searchRetry,
                  onRetry: () => ref.invalidate(trendingTagsProvider(type)),
                  scrollable: false,
                ),
              ),
              data: (tags) => tags.isEmpty
                  ? SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(FuncSpacing.xxl),
                        child: Center(
                          child: Text(context.l10n.searchNoTrending),
                        ),
                      ),
                    )
                  : _TrendingGrid(tags: tags, type: type),
            ),
          ),
          const SliverToBoxAdapter(child: FuncNavBarSpacer()),
        ],
      ),
    );
  }
}

/// The newest Spotlight articles in a horizontal strip; the header opens
/// the full list. Shares the Spotlight list's first page ("all").
class _SpotlightSection extends ConsumerWidget {
  const _SpotlightSection();

  static const int maxArticles = 5;
  static const double cardWidth = 200;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(spotlightFeedProvider(SpotlightCategory.all));
    final store = ref.watch(spotlightArticleStoreProvider);
    final feed = async.value;
    final articles = [
      for (final id in feed?.ids ?? const <int>[])
        if (store[id] != null) store[id]!,
    ].take(maxArticles).toList();
    final failed = async.hasError || (feed?.showInitialError ?? false);
    final loading =
        articles.isEmpty &&
        !failed &&
        (feed == null || feed.showInitialSpinner);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchSectionHeader(
          title: l10n.spotlightTitle,
          action: l10n.detailViewAll,
          onTap: () => openSpotlight(context),
        ),
        StateFade(
          kind: loading,
          child: loading
              ? const _SpotlightStripSkeleton()
              : articles.isNotEmpty
              ? _strip(articles)
              : failed
              ? _failure(context, ref, async.error ?? feed?.initialError)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _strip(List<SpotlightArticle> articles) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
    // Equal card heights whatever the title length.
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, article) in articles.indexed) ...[
            if (index > 0) const SizedBox(width: FuncSpacing.sm),
            SizedBox(
              width: cardWidth,
              child: SpotlightArticleCard(
                article: article,
                imageWidth: cardWidth,
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _failure(BuildContext context, WidgetRef ref, Object? error) {
    final l10n = context.l10n;
    void retry() => ref
        .read(spotlightFeedProvider(SpotlightCategory.all).notifier)
        .retryInitial();
    return RetryOnNetworkRestore(
      error: error,
      onRetry: retry,
      child: Padding(
        // The retry label, not its padding, ends on the margin.
        padding: const EdgeInsetsDirectional.only(
          start: FuncSpacing.lg,
          end: FuncSpacing.lg - EdgeIconButtons.glyphInset,
        ),
        child: Row(
          children: [
            Expanded(child: Text(l10n.spotlightLoadFailed)),
            TextButton(onPressed: retry, child: Text(l10n.retry)),
          ],
        ),
      ),
    );
  }
}

/// [_SpotlightSection]'s strip while the first page loads: cards of the
/// same width, 16:9 image and two title lines plus the date.
class _SpotlightStripSkeleton extends StatelessWidget {
  const _SpotlightStripSkeleton();

  static const _cards = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FuncSkeleton(
      label: context.l10n.contentLoading,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _cards; i++) ...[
              if (i > 0) const SizedBox(width: FuncSpacing.sm),
              SizedBox(
                width: _SpotlightSection.cardWidth,
                child: Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const AspectRatio(
                        aspectRatio: SpotlightArticleCard.imageAspectRatio,
                        child: SkeletonBone(borderRadius: BorderRadius.zero),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(FuncSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SkeletonBone.text(
                              style: theme.textTheme.titleSmall,
                            ),
                            FractionallySizedBox(
                              widthFactor: 0.6,
                              child: SkeletonBone.text(
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            const SizedBox(height: FuncSpacing.xs),
                            FractionallySizedBox(
                              widthFactor: 0.4,
                              child: SkeletonBone.text(
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Trending tags, trimmed to whole rows so the last row is never a lone
/// tile.
class _TrendingGrid extends StatelessWidget {
  const _TrendingGrid({required this.tags, required this.type});

  static const double _spacing = 10;
  static const double _maxTileWidth = 160;
  static const int _minColumns = 3;

  final List<TrendingTag> tags;
  final SearchResultType type;

  /// Whole rows only; fewer tags than one row still show.
  static int shownCount(int count, int columns) =>
      count >= columns ? count - count % columns : count;

  static const padding = EdgeInsets.fromLTRB(
    FuncSpacing.lg,
    FuncSpacing.xs,
    FuncSpacing.lg,
    FuncSpacing.xxl,
  );

  /// The SliverGridDelegateWithMaxCrossAxisExtent formula, floored at three
  /// columns: narrow phones keep a readable three-column grid while wider
  /// surfaces still add columns as the width allows.
  static int columnsFor(double width) => math.max(
    _minColumns,
    ((width + _spacing) / (_maxTileWidth + _spacing)).ceil(),
  );

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: padding,
      sliver: SliverWidthBuilder(
        builder: (context, width) {
          final columns = columnsFor(width);
          final tileWidth = (width - _spacing * (columns - 1)) / columns;
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: _spacing,
              mainAxisSpacing: _spacing,
            ),
            itemCount: shownCount(tags.length, columns),
            itemBuilder: (context, index) => _TrendingTagTile(
              tag: tags[index],
              type: type,
              tileWidth: tileWidth,
            ),
          );
        },
      ),
    );
  }
}

/// [_TrendingGrid] while the tags load: square tiles on the same columns,
/// spacing and padding. Three rows, or, when the list opens scrolled (an
/// offset restored after process death), enough to reach a window's height
/// past it: the offset stays put until the tags land rather than springing
/// back to the third row. Counted when the skeleton lays out and when the
/// window resizes, not as the list scrolls.
class _TrendingGridSkeleton extends StatelessWidget {
  const _TrendingGridSkeleton();

  static const _rows = 3;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: FuncSkeleton(
      label: context.l10n.contentLoading,
      child: Padding(
        padding: _TrendingGrid.padding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = _TrendingGrid.columnsFor(constraints.maxWidth);
            final tile =
                (constraints.maxWidth -
                    _TrendingGrid._spacing * (columns - 1)) /
                columns;
            final position = Scrollable.of(context).position;
            final reach = position.pixels + MediaQuery.sizeOf(context).height;
            final rows = position.pixels > 0
                ? math.max(
                    _rows,
                    (reach / (tile + _TrendingGrid._spacing)).ceil(),
                  )
                : _rows;
            return Column(
              children: [
                for (var r = 0; r < rows; r++) ...[
                  if (r > 0) const SizedBox(height: _TrendingGrid._spacing),
                  Row(
                    children: [
                      for (var c = 0; c < columns; c++) ...[
                        if (c > 0)
                          const SizedBox(width: _TrendingGrid._spacing),
                        SkeletonBone(
                          width: tile,
                          height: tile,
                          borderRadius: FuncShape.card,
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _TrendingTagTile extends ConsumerWidget {
  const _TrendingTagTile({
    required this.tag,
    required this.type,
    required this.tileWidth,
  });

  /// The scrim covers the bottom of the image only, under the label.
  static const double _scrimFraction = 0.4;
  static const Color _scrimColor = Color(0x99000000);

  final TrendingTag tag;
  final SearchResultType type;

  /// The grid cell's actual width — the thumbnail decodes for the tile it
  /// lands in, not the half-screen two-column estimate.
  final double tileWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final representative = tag.representative;
    final label = Text(
      '#${tag.displayName}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: representative == null ? TextAlign.center : TextAlign.start,
      style: theme.textTheme.labelMedium?.copyWith(
        color: representative == null ? scheme.onSurface : FuncTokens.white,
        fontWeight: FontWeight.w600,
      ),
    );
    // Long-pressing opens the work behind the tag, as pixez and Shaft do.
    // A tag without one offers no long press at all.
    final openWork = representative == null
        ? null
        : () {
            AppHaptics.longPress();
            unawaited(
              openIllust(
                context,
                representative.id,
                initialEntity: representative,
              ),
            );
          };
    return PressScale(
      child: Semantics(
        button: true,
        child: GestureDetector(
          // Tapping searches the tag; the image is context. Every entry
          // starts from the type's persisted default filter set.
          onTap: () => openSearchResults(
            context,
            searchQueryForType(
              type,
              keyword: tag.name,
              illustFilters: ref.read(searchIllustFiltersProvider),
              novelFilters: ref.read(searchNovelFiltersProvider),
            ),
          ),
          onLongPress: openWork,
          onSecondaryTapUp: openWork == null
              ? null
              : (details) => unawaited(
                  showDisplayActions(
                    context,
                    position: details.globalPosition,
                    onLongPress: openWork,
                    actions: [
                      DisplayAction(
                        icon: Icons.open_in_new,
                        label: context.l10n.downloadOpenWork,
                        onSelected: openWork,
                      ),
                    ],
                  ),
                ),
          child: ClipRRect(
            borderRadius: FuncShape.card,
            child: ColoredBox(
              color: scheme.surfaceContainer,
              child: representative == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(FuncSpacing.sm),
                        child: label,
                      ),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        PixivImage.feed(
                          representative.imageUrls.squareMedium,
                          layoutWidth: tileWidth,
                          fit: BoxFit.cover,
                        ),
                        const Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            widthFactor: 1,
                            heightFactor: _scrimFraction,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Color(0x00000000), _scrimColor],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(FuncSpacing.sm),
                            child: label,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
