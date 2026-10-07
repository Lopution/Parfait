import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/haptics/app_haptics.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/state_fade.dart';
import '../../app/pixiv_image.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/home_branch_stack.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/spotlight_article_card.dart';
import '../../app/widgets/skeleton/func_skeleton.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../app/navigation/routes.dart';
import '../../core/search/search_autocomplete_controller.dart';
import '../../core/search/search_history.dart';
import '../../core/search/search_models.dart';
import '../../core/search/search_repository.dart';
import '../../core/search/search_shortcut.dart';
import '../../core/search/search_trending_controller.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/spotlight/spotlight_feed_controller.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_store.dart';
import 'search_field_button.dart';
import 'search_filter_labels.dart';
import 'search_filter_sheet.dart';
import 'search_text.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/widgets/tag_chips.dart';
import '../../app/widgets/undo_snack_bar.dart';
import '../../app/theme/func_semantic_tokens.dart';

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

  void _prepareAdjacent(int index) {
    final neighbours = {
      for (final i in [index - 1, index + 1])
        if (i >= 0 && i < _types.length) _types[i],
    };
    if (_loaded.containsAll(neighbours)) return;
    setState(() => _loaded.addAll(neighbours));
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
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: AppTopBar(
        title: SearchFieldButton(
          // The input page body spells out what can be searched.
          text: l10n.searchBarHint,
          isHint: true,
          onTap: () => openSearchInput(context, type: _active),
        ),
        actions: [
          IconButton(
            tooltip: l10n.searchReverseImage,
            onPressed: () => openReverseImageSearch(context),
            icon: const Icon(Icons.photo_camera_outlined),
          ),
        ],
        bottom: AppTabBar(
          controller: _tabController,
          onTap: _onTabTap,
          labels: [
            for (final type in _types) searchText(context, type.labelKey),
          ],
        ),
      ),
      body: Builder(
        builder: (context) {
          _notificationContext = context;
          return TabSwipeSwitcher(
            tabController: _tabController,
            onPrepareAdjacent: _prepareAdjacent,
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
            child: _SectionHeader(title: context.l10n.searchTrending),
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

/// A section title on the search guide. With [onTap] the whole row is one
/// target (at least 48dp tall) ending in [action] and a chevron; a
/// [trailing] control instead sits at the row's end on its own.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.action,
    this.onTap,
    this.trailing,
  }) : assert(trailing == null || onTap == null);

  final String title;
  final String? action;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = this.action;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                // Two lines: large text and long locales next to an action.
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (action != null) ...[
              Text(
                action,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.primary),
            ],
            ?trailing,
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: FuncSpacing.sm),
      child: onTap == null
          ? Semantics(header: true, child: row)
          : MergeSemantics(
              child: Semantics(
                header: true,
                button: true,
                child: InkWell(onTap: onTap, child: row),
              ),
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
        _SectionHeader(
          title: l10n.spotlightTitle,
          action: l10n.spotlightSeeAll,
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
        padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
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
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = columnsFor(constraints.crossAxisExtent);
          final tileWidth =
              (constraints.crossAxisExtent - _spacing * (columns - 1)) /
              columns;
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

/// [_TrendingGrid] while the tags load: three rows of square tiles on the
/// same columns, spacing and padding.
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
            return Column(
              children: [
                for (var r = 0; r < _rows; r++) ...[
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
        color: representative == null
            ? scheme.onSurface
            : FuncTokens.lightBackground,
        fontWeight: FontWeight.w600,
      ),
    );
    return Semantics(
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
        // Long-pressing opens the work behind the tag, as pixez and Shaft
        // do. A tag without one offers no long press at all.
        onLongPress: representative == null
            ? null
            : () {
                AppHaptics.longPress();
                openIllust(
                  context,
                  representative.id,
                  initialEntity: representative,
                );
              },
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
    );
  }
}

/// Search input with the three beta56 result tabs and cancellable suggestions.
class SearchInputPage extends ConsumerStatefulWidget {
  const SearchInputPage({
    super.key,
    this.initialKeyword = '',
    this.initialType = SearchResultType.illust,
    this.onTypeChanged,
  });

  final String initialKeyword;
  final SearchResultType initialType;
  final void Function(String keyword, SearchResultType type)? onTypeChanged;

  @override
  ConsumerState<SearchInputPage> createState() => _SearchInputPageState();
}

class _SearchInputPageState extends ConsumerState<SearchInputPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final TextEditingController _textController;
  late final FocusNode _focusNode;
  late int _selectedIndex;
  Animation<double>? _routeAnimation;

  static const _types = SearchResultType.values;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _types.indexOf(widget.initialType);
    _tabController = TabController(
      length: _types.length,
      vsync: this,
      initialIndex: _selectedIndex,
    )..addListener(_onTabChanged);
    _textController = TextEditingController(text: widget.initialKeyword);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.initialKeyword.trim().isNotEmpty) {
        ref
            .read(searchAutocompleteProvider.notifier)
            .update(widget.initialKeyword);
      }
      // The page exists to type a query: focus the field on arrival so the
      // keyboard is up without a second tap (pre-go_router behaviour).
      // But not mid-transition: _RoutePopSnapshot freezes the page into a
      // fixed-size texture while the IME animates viewInsets, so a keyboard
      // that opens during the push would let the route fly in squeezed and
      // then snap when the snapshot releases. Waiting for the transition to
      // complete keeps both animations out of each other's way.
      final animation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.isCompleted) {
        _focusNode.requestFocus();
        return;
      }
      _routeAnimation = animation;
      animation.addStatusListener(_focusWhenRouteSettles);
    });
  }

  void _focusWhenRouteSettles(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _routeAnimation?.removeStatusListener(_focusWhenRouteSettles);
    _routeAnimation = null;
    if (mounted) _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_focusWhenRouteSettles);
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _selectedIndex ||
        _tabController.indexIsChanging) {
      return;
    }
    setState(() => _selectedIndex = _tabController.index);
    widget.onTypeChanged?.call(_textController.text, _types[_selectedIndex]);
  }

  void _submit() {
    final keyword = _textController.text.trim();
    if (keyword.isEmpty) {
      showAppSnackBar(context, context.l10n.searchInputEmpty);
      return;
    }
    _search(keyword);
  }

  /// Searches [keyword] with this page's filter drafts. An id or a pixiv
  /// link opens what it names instead (see [openSearchResults]) and stays
  /// out of the history.
  void _search(String keyword) {
    ref.read(searchAutocompleteProvider.notifier).cancel();
    if (searchShortcutFor(keyword, _types[_selectedIndex]) == null) {
      unawaited(ref.read(searchHistoryProvider.notifier).record(keyword));
    }
    unawaited(openSearchResults(context, _query(keyword)));
  }

  SearchQuery _query(String keyword) {
    return searchQueryForType(
      _types[_selectedIndex],
      keyword: keyword,
      illustFilters: _illustFilters,
      novelFilters: _novelFilters,
    );
  }

  /// Per-type filter drafts for this input session. Seeded from the
  /// persisted defaults on first access; edits stay on the page (this
  /// draft is what the submitted query carries — nothing else writes it).
  late IllustSearchFilters _illustFilters = ref.read(
    searchIllustFiltersProvider,
  );
  late NovelSearchFilters _novelFilters = ref.read(searchNovelFiltersProvider);

  SearchFilters get _filters => _types[_selectedIndex] == SearchResultType.novel
      ? _novelFilters
      : _illustFilters;

  Future<void> _editFilters() async {
    final result = await showSearchFilterSheet(context, initial: _filters);
    if (!mounted || result == null) return;
    // The draft belongs to this input session only — persisting it is the
    // result page's "设为默认" job, not the apply button's.
    setState(() {
      switch (result.filters) {
        case final IllustSearchFilters f:
          _illustFilters = f;
        case final NovelSearchFilters f:
          _novelFilters = f;
      }
    });
  }

  void _onSearchChanged(String value) {
    final autocomplete = ref.read(searchAutocompleteProvider.notifier)
      ..update(value);
    // An id or a link opens directly; asking for tag suggestions for it
    // would only fill the list with noise.
    if (searchShortcutFor(value, _types[_selectedIndex]) != null) {
      autocomplete.cancel();
    }
  }

  /// Puts [keyword] in the field to edit it further.
  void _fill(String keyword) {
    _textController.value = TextEditingValue(
      text: keyword,
      selection: TextSelection.collapsed(offset: keyword.length),
    );
    _onSearchChanged(keyword);
    _focusNode.requestFocus();
  }

  void _clear() {
    _textController.clear();
    ref.read(searchAutocompleteProvider.notifier).update('');
    _focusNode.requestFocus();
  }

  Widget _clearSearchAction() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _textController,
      builder: (context, value, _) {
        if (value.text.isEmpty) return const SizedBox.shrink();
        return IconButton(
          tooltip: context.l10n.searchClear,
          onPressed: _clear,
          icon: const Icon(Icons.clear),
        );
      },
    );
  }

  /// M3 SearchBar look, inline behaviour: no SearchAnchor view. The type
  /// tabs and the filter button must stay visible while typing, and the
  /// suggestions render in the page body exactly like the pre-M3 page did.
  Widget _buildSearchBar(BuildContext context) {
    return SearchBar(
      controller: _textController,
      focusNode: _focusNode,
      // Flat, with the icon and text where [SearchFieldButton] draws them
      // on the guide and the result page: the field reads as one across
      // both pushes.
      constraints: const BoxConstraints(minHeight: SearchFieldButton.height),
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(
        Theme.of(context).colorScheme.surfaceContainerHigh,
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
      ),
      hintText: context.l10n.searchBarHint,
      leading: const Icon(Icons.search),
      trailing: [
        _clearSearchAction(),
        IconButton(
          tooltip: context.l10n.searchSubmit,
          onPressed: _submit,
          icon: const Icon(Icons.search),
        ),
      ],
      onChanged: _onSearchChanged,
      onSubmitted: (_) => _submit(),
      textInputAction: TextInputAction.search,
    );
  }

  @override
  Widget build(BuildContext context) {
    final supportsFilters = _selectedIndex != 2;
    return Scaffold(
      // The keyboard overlays the page instead of squeezing the body into
      // the strip above it; the suggestion list below gets a viewInsets
      // bottom pad so its tail can still scroll clear of the IME.
      resizeToAvoidBottomInset: false,
      appBar: AppTopBar(
        leading: IconButton(
          tooltip: context.l10n.searchCancel,
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        titleSpacing: 0,
        title: _buildSearchBar(context),
        // The same slot as the result page's filter button, so the field
        // keeps its place across the push.
        actions: [
          if (supportsFilters)
            SearchFilterButton(filters: _filters, onPressed: _editFilters)
          else
            // Keeps the field off the screen edge.
            const SizedBox(width: FuncSpacing.lg),
        ],
        bottom: AppTabBar(
          controller: _tabController,
          labels: [
            for (final type in _types) searchText(context, type.labelKey),
          ],
        ),
      ),
      body: _SearchInputBody(
        type: _types[_selectedIndex],
        onSearch: _search,
        onFill: _fill,
      ),
    );
  }
}

/// Below the input: where to start while the field is empty, the
/// suggestions for what is typed, or the work or user an id or a link
/// opens.
///
/// A suggestion, a recent search or a trending tag searches on tap; a
/// long press (or a suggestion's trailing button) puts it in the field to
/// edit instead.
class _SearchInputBody extends ConsumerWidget {
  const _SearchInputBody({
    required this.type,
    required this.onSearch,
    required this.onFill,
  });

  final SearchResultType type;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(searchAutocompleteProvider);
    if (state.keyword.isEmpty) {
      return _SearchStart(type: type, onSearch: onSearch, onFill: onFill);
    }
    final shortcut = searchShortcutFor(state.keyword, type);
    if (shortcut != null) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
        children: [
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: Text(_shortcutLabel(context, shortcut)),
            onTap: () => unawaited(openSearchShortcut(context, shortcut)),
          ),
        ],
      );
    }
    if (state.loading) {
      return const FeedLoading();
    }
    if (state.error != null) {
      return FeedError(
        title: context.l10n.searchLoadFailed,
        error: state.error!,
        retryLabel: context.l10n.searchRetry,
        onRetry: () =>
            ref.read(searchAutocompleteProvider.notifier).update(state.keyword),
        scrollable: false,
      );
    }
    if (state.suggestions.isEmpty) {
      return Center(child: Text(context.l10n.searchNoSuggestions));
    }
    return ListView.separated(
      padding: EdgeInsets.only(
        top: FuncSpacing.sm,
        bottom: FuncSpacing.sm + MediaQuery.viewInsetsOf(context).bottom,
      ),
      itemCount: state.suggestions.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final suggestion = state.suggestions[index];
        return Semantics(
          onLongPressHint: context.l10n.searchSuggestionFill,
          child: ListTile(
            leading: const Icon(Icons.search),
            title: Text(suggestion.displayName),
            subtitle: suggestion.translatedName == null
                ? null
                : Text(suggestion.keyword),
            onTap: () => onSearch(suggestion.keyword),
            onLongPress: () {
              AppHaptics.longPress();
              onFill(suggestion.keyword);
            },
            trailing: IconButton(
              tooltip: context.l10n.searchSuggestionFill,
              onPressed: () => onFill(suggestion.keyword),
              icon: const Icon(Icons.north_west),
            ),
          ),
        );
      },
    );
  }

  static String _shortcutLabel(BuildContext context, SearchShortcut shortcut) {
    final id = shortcut.id;
    return switch (shortcut.kind) {
      SearchShortcutKind.illust => context.l10n.searchOpenIllust(id),
      SearchShortcutKind.novel => context.l10n.searchOpenNovel(id),
      SearchShortcutKind.user => context.l10n.searchOpenUser(id),
    };
  }
}

/// The empty input's start points: recent searches, then the selected
/// kind's trending tags (users have none).
class _SearchStart extends ConsumerWidget {
  const _SearchStart({
    required this.type,
    required this.onSearch,
    required this.onFill,
  });

  final SearchResultType type;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFill;

  /// Two or three rows of tags on a phone; the full grid is on the search
  /// tab.
  static const _trendingShown = 12;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final history = ref.watch(searchHistoryProvider);
    final trending = type == SearchResultType.user
        ? const <TrendingTag>[]
        : ref.watch(trendingTagsProvider(type)).value ?? const <TrendingTag>[];
    if (history.isEmpty && trending.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.xl),
          child: Text(
            l10n.searchHint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }
    void fillWithHaptic(String keyword) {
      AppHaptics.longPress();
      onFill(keyword);
    }

    return ListView(
      padding: EdgeInsets.only(
        bottom: FuncSpacing.xl + MediaQuery.viewInsetsOf(context).bottom,
      ),
      children: [
        if (history.isNotEmpty) ...[
          _SectionHeader(
            title: l10n.searchHistoryTitle,
            trailing: TextButton(
              onPressed: () => unawaited(_confirmClear(context, ref)),
              child: Text(l10n.searchHistoryClear),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
            child: Wrap(
              spacing: FuncSpacing.sm,
              runSpacing: FuncSpacing.sm,
              children: [
                for (final keyword in history)
                  _HistoryChip(
                    keyword: keyword,
                    onTap: () => onSearch(keyword),
                    onLongPress: () => fillWithHaptic(keyword),
                    onDeleted: () => unawaited(_remove(context, ref, keyword)),
                  ),
              ],
            ),
          ),
        ],
        if (trending.isNotEmpty) ...[
          _SectionHeader(title: l10n.searchTrending),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.md),
            child: TagChips(
              children: [
                for (final tag in trending.take(_trendingShown))
                  TagChip(
                    label: tag.name,
                    translated: tag.translatedName,
                    onTap: () => onSearch(tag.name),
                    onLongPress: () => fillWithHaptic(tag.name),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    String keyword,
  ) async {
    final index = await ref
        .read(searchHistoryProvider.notifier)
        .remove(keyword);
    if (index == null || !context.mounted) return;
    showUndoSnackBar(
      context,
      context.l10n.searchHistoryRemoved,
      onUndo: (container) => container
          .read(searchHistoryProvider.notifier)
          .restore(keyword, index),
    );
  }

  /// Clearing every entry has no undo, so it asks first.
  static Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l10n.searchHistoryClearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.searchHistoryClear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(searchHistoryProvider.notifier).clear();
  }
}

/// A recent search: tap searches it again, long press edits it, the
/// trailing cross removes it (with undo).
class _HistoryChip extends StatelessWidget {
  const _HistoryChip({
    required this.keyword,
    required this.onTap,
    required this.onLongPress,
    required this.onDeleted,
  });

  final String keyword;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) => Semantics(
    onLongPressHint: context.l10n.searchSuggestionFill,
    child: GestureDetector(
      onLongPress: onLongPress,
      child: InputChip(
        avatar: const Icon(Icons.history),
        label: Text(keyword),
        onPressed: onTap,
        onDeleted: onDeleted,
        deleteButtonTooltipMessage: context.l10n.searchHistoryRemove,
      ),
    ),
  );
}
