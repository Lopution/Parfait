import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pixiv_image.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/branch_slide_stack.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/root_swipe_switcher.dart';
import '../../app/navigation/routes.dart';
import '../../core/search/search_autocomplete_controller.dart';
import '../../core/search/search_models.dart';
import '../../core/search/search_repository.dart';
import '../../core/search/search_trending_controller.dart';
import '../../core/settings/settings_controller.dart';
import 'search_filter_sheet.dart';
import 'search_text.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';

/// Search guide shown by the Home bottom-navigation entry.
///
/// Restoration tiers (design.md §二 matrix): the trending kind is
/// session memory — `trendingKindProvider` resets to illust after process
/// death, and `trendingTagsProvider` stays non-autoDispose on purpose so
/// leaving the branch does not re-request. Scroll offset rides
/// `PageStorageKey('search-home')` + `restorationId` as before; the
/// explicit [_scrollController] only exists so the branch re-tap channel
/// can address this scrollable (on desktop `SmoothWheelScroll` would
/// otherwise own a private controller `PrimaryScrollController` cannot
/// reach).
class SearchHomePage extends ConsumerStatefulWidget {
  const SearchHomePage({super.key});

  @override
  ConsumerState<SearchHomePage> createState() => _SearchHomePageState();
}

class _SearchHomePageState extends ConsumerState<SearchHomePage> {
  final _scrollController = ScrollController();
  ReTapChannel? _reTapChannel;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final channel = BranchSlideStack.maybeOf(context)?.reTapEvents;
    if (identical(channel, _reTapChannel)) return;
    _reTapChannel?.removeListener(_onBranchReTap);
    _reTapChannel = channel;
    _reTapChannel?.addListener(_onBranchReTap);
  }

  @override
  void dispose() {
    _reTapChannel?.removeListener(_onBranchReTap);
    _scrollController.dispose();
    super.dispose();
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
      reTapScrollToTop(context, _scrollController);
    });
  }

  @override
  Widget build(BuildContext context) {
    final trendingType = ref.watch(trendingKindProvider);
    final trending = ref.watch(trendingTagsProvider);
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: Text(context.l10n.searchTitle)),
      body: RootSwipeSwitcher(
        child: SmoothWheelScroll(
          controller: _scrollController,
          builder: (context, controller, physics) => CustomScrollView(
            key: const PageStorageKey('search-home'),
            restorationId: 'search-home',
            controller: controller,
            physics: physics,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                sliver: SliverToBoxAdapter(
                  child: _SearchGuideBox(onTap: () => openSearchInput(context)),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                      ),
                      onPressed: () => openReverseImageSearch(context),
                      icon: const Icon(Icons.image_search_outlined),
                      label: Text(context.l10n.searchReverseImage),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: () => openSpotlight(context),
                      icon: const Icon(Icons.newspaper_outlined),
                      label: Text(context.l10n.spotlightTitle),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 10),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.searchTrending,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      SegmentedButton<SearchResultType>(
                        segments: [
                          for (final type in const [
                            SearchResultType.illust,
                            SearchResultType.novel,
                          ])
                            ButtonSegment(
                              value: type,
                              label: Text(searchText(context, type.labelKey)),
                            ),
                        ],
                        selected: {trendingType},
                        showSelectedIcon: false,
                        onSelectionChanged: (selected) => ref
                            .read(trendingKindProvider.notifier)
                            .select(selected.first),
                      ),
                    ],
                  ),
                ),
              ),
              trending.when(
                loading: () => const SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: FeedError(
                    title: context.l10n.searchTrendingFailed,
                    error: error,
                    retryLabel: context.l10n.searchRetry,
                    onRetry: () => ref.invalidate(trendingTagsProvider),
                    scrollable: false,
                  ),
                ),
                data: (tags) {
                  if (tags.isEmpty) {
                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Center(
                          child: Text(context.l10n.searchNoTrending),
                        ),
                      ),
                    );
                  }
                  return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                    sliver: SliverGrid.builder(
                      // Adaptive: width decides the column count (≈160dp
                      // tiles) so wide form factors no longer stretch
                      // three columns and every tag is rendered — no
                      // partial-row truncation.
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 160,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                      itemCount: tags.length,
                      itemBuilder: (context, index) => _TrendingTagTile(
                        tag: tags[index],
                        type: trendingType,
                      ),
                    ),
                  );
                },
              ),
              const SliverToBoxAdapter(child: FuncNavBarSpacer()),
            ],
          ),
        ),
      ),
    );
  }
}

/// Short compatibility name for callers that treat the Home search guide as
/// the feature's root page.
class SearchPage extends SearchHomePage {
  const SearchPage({super.key});
}

class _SearchGuideBox extends StatelessWidget {
  const _SearchGuideBox({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SearchBar(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      hintText: context.l10n.searchHint,
      leading: const Icon(Icons.search),
      trailing: const [Icon(Icons.chevron_right)],
      onTap: onTap,
      readOnly: true,
    );
  }
}

class _TrendingTagTile extends StatelessWidget {
  const _TrendingTagTile({required this.tag, required this.type});

  final TrendingTag tag;
  final SearchResultType type;

  void _openRepresentative(BuildContext context) {
    final representative = tag.representative;
    if (representative == null) {
      showAppSnackBar(context, context.l10n.searchNoRepresentative);
      return;
    }
    openIllust(context, representative.id, initialEntity: representative);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final representative = tag.representative;
    return GestureDetector(
      // Tapping still means "search this tag" — the image is context, not a
      // new primary action. Opening the representative work stays secondary.
      onTap: () => openSearchResults(
        context,
        type == SearchResultType.novel
            ? NovelSearchQuery(keyword: tag.name)
            : IllustSearchQuery(keyword: tag.name),
      ),
      onLongPress: () => _openRepresentative(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: scheme.surfaceContainer,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (representative != null)
                PixivImage.feed(
                  representative.imageUrls.squareMedium,
                  layoutWidth: MediaQuery.sizeOf(context).width / 2,
                  fit: BoxFit.cover,
                ),
              if (representative != null)
                // Without a scrim the label is unreadable over a bright
                // thumbnail; without an image the scrim would darken the
                // plain card for no reason.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xB3000000)],
                    ),
                  ),
                ),
              Align(
                alignment: representative == null
                    ? Alignment.center
                    : Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Text(
                    '#${tag.displayName}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: representative == null
                        ? TextAlign.center
                        : TextAlign.start,
                    style: TextStyle(
                      color: representative == null
                          ? scheme.onSurface
                          : FuncTokens.lightBackground,
                      fontWeight: FontWeight.w600,
                      shadows: representative == null
                          ? null
                          : const [Shadow(blurRadius: 4)],
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
    ref.read(searchAutocompleteProvider.notifier).cancel();
    openSearchResults(context, _query(keyword));
  }

  SearchQuery _query(String keyword) {
    final filters = ref.read(searchFiltersProvider);
    return switch (_types[_selectedIndex]) {
      SearchResultType.illust => IllustSearchQuery(
        keyword: keyword,
        filters: filters,
      ),
      SearchResultType.novel => NovelSearchQuery(
        keyword: keyword,
        filters: filters,
      ),
      SearchResultType.user => UserSearchQuery(keyword: keyword),
    };
  }

  Future<void> _editFilters() async {
    final selected = await showSearchFilterSheet(
      context,
      initial: ref.read(searchFiltersProvider),
      type: _types[_selectedIndex],
    );
    if (!mounted || selected == null) return;
    await ref.read(settingsProvider.notifier).setSearchFilters(selected);
  }

  void _onSearchChanged(String value) {
    ref.read(searchAutocompleteProvider.notifier).update(value);
  }

  /// Row tap only fills the field — the same gesture that submits on the
  /// result page must not submit here, so the user keeps editing context.
  /// The trailing action is the explicit "search this now" affordance.
  void _fillSuggestion(SearchSuggestion suggestion) {
    _textController
      ..text = suggestion.keyword
      ..selection = TextSelection.collapsed(offset: suggestion.keyword.length);
    _focusNode.requestFocus();
  }

  void _searchSuggestion(SearchSuggestion suggestion) {
    _fillSuggestion(suggestion);
    _submit();
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
      constraints: const BoxConstraints(minHeight: 48),
      hintText: context.l10n.searchHint,
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
      appBar: AppBar(
        leading: IconButton(
          tooltip: context.l10n.searchCancel,
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        titleSpacing: 0,
        title: _buildSearchBar(context),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            for (final type in _types)
              Tab(text: searchText(context, type.labelKey)),
          ],
        ),
      ),
      body: Column(
        children: [
          if (supportsFilters)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12, top: 8),
                child: OutlinedButton.icon(
                  onPressed: _editFilters,
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(context.l10n.searchFilters),
                ),
              ),
            ),
          Expanded(
            child: _SearchAutocompletePanel(
              onFill: _fillSuggestion,
              onSearch: _searchSuggestion,
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchAutocompletePanel extends ConsumerWidget {
  const _SearchAutocompletePanel({
    required this.onFill,
    required this.onSearch,
  });

  /// Row tap: fill the text field only.
  final ValueChanged<SearchSuggestion> onFill;

  /// Trailing action: fill and submit immediately.
  final ValueChanged<SearchSuggestion> onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(searchAutocompleteProvider);
    if (state.keyword.isEmpty) {
      return Center(
        child: Text(
          context.l10n.searchHint,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
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
        top: 8,
        bottom: 8 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      itemCount: state.suggestions.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final suggestion = state.suggestions[index];
        return Semantics(
          // The row's tap fills the field; the trailing button submits.
          // Distinct labels keep the two actions apart for assistive tech.
          hint: context.l10n.searchSuggestionFill,
          child: ListTile(
            leading: const Icon(Icons.search),
            title: Text(suggestion.displayName),
            subtitle: suggestion.translatedName == null
                ? null
                : Text(suggestion.keyword),
            onTap: () => onFill(suggestion),
            trailing: IconButton(
              tooltip: context.l10n.searchSuggestionSearch,
              onPressed: () => onSearch(suggestion),
              icon: const Icon(Icons.search),
            ),
          ),
        );
      },
    );
  }
}
