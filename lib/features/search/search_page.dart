import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pixiv_image.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/navigation/routes.dart';
import '../../core/search/search_autocomplete_controller.dart';
import '../../core/search/search_models.dart';
import '../../core/search/search_repository.dart';
import '../../core/search/search_trending_controller.dart';
import 'search_filter_sheet.dart';
import 'search_text.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';

/// Search guide shown by the Home bottom-navigation entry.
class SearchHomePage extends ConsumerWidget {
  const SearchHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trending = ref.watch(trendingTagsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.searchTitle)),
      body: CustomScrollView(
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
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 10),
            sliver: SliverToBoxAdapter(
              child: Text(
                context.l10n.searchTrending,
                style: Theme.of(context).textTheme.titleLarge,
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
                    child: Center(child: Text(context.l10n.searchNoTrending)),
                  ),
                );
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  // Keep the final partial row: every server-provided tag is
                  // actionable, including the fourth or fifth result.
                  itemCount: tags.length,
                  itemBuilder: (context, index) =>
                      _TrendingTagTile(tag: tags[index]),
                ),
              );
            },
          ),
        ],
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
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              const Icon(Icons.search),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.l10n.searchHint,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrendingTagTile extends StatelessWidget {
  const _TrendingTagTile({required this.tag});

  final TrendingTag tag;

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
      onTap: () =>
          openSearchResults(context, IllustSearchQuery(keyword: tag.name)),
      onLongPress: () => _openRepresentative(context),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
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
  const SearchInputPage({super.key, this.initialKeyword = ''});

  final String initialKeyword;

  @override
  ConsumerState<SearchInputPage> createState() => _SearchInputPageState();
}

class _SearchInputPageState extends ConsumerState<SearchInputPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final TextEditingController _textController;
  late final FocusNode _focusNode;
  SearchFilters _filters = SearchFilters.defaults;
  int _selectedIndex = 0;

  static const _types = SearchResultType.values;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _types.length, vsync: this)
      ..addListener(_onTabChanged);
    _textController = TextEditingController(text: widget.initialKeyword);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.initialKeyword.trim().isNotEmpty) {
        ref
            .read(searchAutocompleteProvider.notifier)
            .update(widget.initialKeyword);
      }
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
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

  SearchQuery _query(String keyword) => switch (_types[_selectedIndex]) {
    SearchResultType.illust => IllustSearchQuery(
      keyword: keyword,
      filters: _filters,
    ),
    SearchResultType.novel => NovelSearchQuery(
      keyword: keyword,
      filters: _filters,
    ),
    SearchResultType.user => UserSearchQuery(keyword: keyword),
  };

  Future<void> _editFilters() async {
    final selected = await showSearchFilterSheet(context, initial: _filters);
    if (!mounted || selected == null) return;
    setState(() => _filters = selected);
  }

  @override
  Widget build(BuildContext context) {
    final supportsFilters = _selectedIndex != 2;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: context.l10n.searchCancel,
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _textController,
          focusNode: _focusNode,
          autofocus: widget.initialKeyword.isEmpty,
          textInputAction: TextInputAction.search,
          onChanged: (value) {
            setState(() {});
            ref.read(searchAutocompleteProvider.notifier).update(value);
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: context.l10n.searchHint,
            border: InputBorder.none,
            suffixIcon: _textController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: context.l10n.searchClear,
                    onPressed: () {
                      _textController.clear();
                      ref.read(searchAutocompleteProvider.notifier).update('');
                      setState(() {});
                    },
                    icon: const Icon(Icons.clear),
                  ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: context.l10n.searchSubmit,
            onPressed: _submit,
            icon: const Icon(Icons.search),
          ),
        ],
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
              onSelected: (suggestion) {
                _textController
                  ..text = suggestion.keyword
                  ..selection = TextSelection.collapsed(
                    offset: suggestion.keyword.length,
                  );
                _submit();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchAutocompletePanel extends ConsumerWidget {
  const _SearchAutocompletePanel({required this.onSelected});

  final ValueChanged<SearchSuggestion> onSelected;

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
      return const Center(child: CircularProgressIndicator());
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
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.suggestions.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final suggestion = state.suggestions[index];
        return ListTile(
          leading: const Icon(Icons.search),
          title: Text(suggestion.displayName),
          subtitle: suggestion.translatedName == null
              ? null
              : Text(suggestion.keyword),
          onTap: () => onSelected(suggestion),
        );
      },
    );
  }
}
