import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/replica_page_route.dart';
import '../../core/search/search_autocomplete_controller.dart';
import '../../core/search/search_models.dart';
import '../../core/search/search_repository.dart';
import '../../core/search/search_trending_controller.dart';
import '../../core/network/api_error.dart';
import '../illust/detail/illust_detail_page.dart';
import 'search_filter_sheet.dart';
import 'search_router.dart';
import 'search_text.dart';
import 'reverse_image_search_page.dart';

/// Search guide shown by the Home bottom-navigation entry.
class SearchHomePage extends ConsumerWidget {
  const SearchHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trending = ref.watch(trendingTagsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(searchText(context, 'searchTitle'))),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
            sliver: SliverToBoxAdapter(
              child: _SearchGuideBox(onTap: () => showSearchInput(context)),
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
                  onPressed: () => showReverseImageSearch(context),
                  icon: const Icon(Icons.image_search_outlined),
                  label: Text(searchText(context, 'searchReverseImage')),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 10),
            sliver: SliverToBoxAdapter(
              child: Text(
                searchText(context, 'searchTrending'),
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
              child: _SearchInlineError(
                title: searchText(context, 'searchTrendingFailed'),
                error: error,
                onRetry: () => ref.invalidate(trendingTagsProvider),
              ),
            ),
            data: (tags) {
              if (tags.isEmpty) {
                return SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Center(
                      child: Text(searchText(context, 'searchNoTrending')),
                    ),
                  ),
                );
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 3.4,
                  ),
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
                  searchText(context, 'searchHint'),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () =>
          showSearchResults(context, IllustSearchQuery(keyword: tag.name)),
      onLongPress: () {
        final representative = tag.representative;
        if (representative == null) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(searchText(context, 'searchNoRepresentative')),
            ),
          );
          return;
        }
        Navigator.of(context).push<void>(
          ReplicaPageRoute<void>(
            builder: (_) => IllustDetailPage(illustId: representative.id),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: scheme.surfaceContainerHighest,
        ),
        child: Row(
          children: [
            Icon(Icons.local_offer_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                '#${tag.displayName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(searchText(context, 'searchInputEmpty'))),
      );
      return;
    }
    ref.read(searchAutocompleteProvider.notifier).cancel();
    showSearchResults(context, _query(keyword));
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
          tooltip: searchText(context, 'searchCancel'),
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
            hintText: searchText(context, 'searchHint'),
            border: InputBorder.none,
            suffixIcon: _textController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: searchText(context, 'searchClear'),
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
            tooltip: searchText(context, 'searchSubmit'),
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
                  label: Text(searchText(context, 'searchFilters')),
                ),
              ),
            ),
          Expanded(
            child: SearchAutocompletePanel(
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

class SearchAutocompletePanel extends ConsumerWidget {
  const SearchAutocompletePanel({super.key, required this.onSelected});

  final ValueChanged<SearchSuggestion> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(searchAutocompleteProvider);
    if (state.keyword.isEmpty) {
      return Center(
        child: Text(
          searchText(context, 'searchHint'),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _SearchInlineError(
        title: searchText(context, 'searchLoadFailed'),
        error: state.error!,
        onRetry: () =>
            ref.read(searchAutocompleteProvider.notifier).update(state.keyword),
      );
    }
    if (state.suggestions.isEmpty) {
      return Center(child: Text(searchText(context, 'searchNoSuggestions')));
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

class _SearchInlineError extends StatelessWidget {
  const _SearchInlineError({
    required this.title,
    required this.error,
    required this.onRetry,
  });

  final String title;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 42),
            const SizedBox(height: 10),
            Text(title),
            const SizedBox(height: 6),
            Text(
              error is ApiError ? error.toString() : '$error',
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: onRetry,
              child: Text(searchText(context, 'searchRetry')),
            ),
          ],
        ),
      ),
    );
  }
}
