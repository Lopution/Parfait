import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../app/pull_to_refresh.dart';
import '../../core/entity/illust_store.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/new/new_feed_controller.dart';
import '../../core/new/new_feed_models.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../home/recommended/recommended_illust_page.dart';
import '../novel/novel_page.dart';

/// Beta56 New page: scope tabs are stable while the content type selector is
/// exposed by tapping the selected tab a second time.
class NewPage extends StatefulWidget {
  const NewPage({super.key});

  @override
  State<NewPage> createState() => _NewPageState();
}

class _NewPageState extends State<NewPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _loadedKeys = <NewFeedKey>{
    const NewFeedKey(scope: NewFeedScope.following, type: NewFeedType.illust),
  };
  int _selectedIndex = 0;
  NewFeedType _type = NewFeedType.illust;
  bool _selectorExpanded = false;

  static const _scopes = NewFeedScope.values;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _scopes.length, vsync: this)
      ..addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  NewFeedKey get _activeKey =>
      NewFeedKey(scope: _scopes[_selectedIndex], type: _type);

  void _onTabChanged() {
    if (_tabController.index == _selectedIndex) return;
    setState(() {
      _selectedIndex = _tabController.index;
      _selectorExpanded = false;
      _loadedKeys.add(_activeKey);
    });
  }

  void _onTabTap(int index) {
    if (index == _selectedIndex && !_tabController.indexIsChanging) {
      setState(() => _selectorExpanded = !_selectorExpanded);
    }
  }

  void _selectType(NewFeedType type) {
    setState(() {
      _type = type;
      _selectorExpanded = false;
      _loadedKeys.add(_activeKey);
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeKey = _activeKey;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorPadding: const EdgeInsets.only(bottom: 5),
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          onTap: _onTabTap,
          tabs: [
            for (final scope in _scopes)
              Tab(text: _newText(context, _scopeLabelKey(scope))),
          ],
        ),
      ),
      body: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: _selectorExpanded
                ? _NewTypeSelector(type: _type, onChanged: _selectType)
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final key in _loadedKeys)
                  Offstage(
                    offstage: key != activeKey,
                    child: NewFeedBody(key: ValueKey(key), feedKey: key),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _scopeLabelKey(NewFeedScope scope) => switch (scope) {
    NewFeedScope.following => 'newFollowing',
    NewFeedScope.everyone => 'newEveryone',
    NewFeedScope.myPixiv => 'newMyPixiv',
  };
}

class _NewTypeSelector extends StatelessWidget {
  const _NewTypeSelector({required this.type, required this.onChanged});

  final NewFeedType type;
  final ValueChanged<NewFeedType> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox(
        height: 64,
        child: Center(
          child: Wrap(
            spacing: 8,
            children: [
              for (final value in NewFeedType.values)
                ChoiceChip(
                  label: Text(
                    _newText(
                      context,
                      value == NewFeedType.illust ? 'newIllust' : 'newNovel',
                    ),
                  ),
                  selected: value == type,
                  onSelected: (_) => onChanged(value),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One keyed feed body. The state is kept alive by [NewPage]'s Offstage stack
/// so scroll/cursor/error state is not shared with another scope or type.
class NewFeedBody extends ConsumerStatefulWidget {
  const NewFeedBody({super.key, required this.feedKey});

  final NewFeedKey feedKey;

  @override
  ConsumerState<NewFeedBody> createState() => _NewFeedBodyState();
}

class _NewFeedBodyState extends ConsumerState<NewFeedBody> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(newFeedProvider(widget.feedKey));
    return feedAsync.when(
      loading: () => _NewStatus(
        icon: Icons.fiber_new_outlined,
        title: _newText(context, 'newLoading'),
      ),
      error: (error, _) => _NewError(
        error: error,
        onRetry: () => ref.invalidate(newFeedProvider(widget.feedKey)),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return _NewError(
            error: feed.initialError ?? const ApiParseError('unknown error'),
            onRetry: () => ref
                .read(newFeedProvider(widget.feedKey).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return _NewStatus(
            icon: Icons.fiber_new_outlined,
            title: _newText(context, 'newLoading'),
          );
        }
        if (feed.isEmptyAndReady) {
          return _NewStatus(
            icon: Icons.inbox_outlined,
            title: _newText(context, 'newEmpty'),
          );
        }

        final slivers = _buildSlivers(feed);
        return PullToRefresh(
          onRefresh: () =>
              ref.read(newFeedProvider(widget.feedKey).notifier).refresh(),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollEndNotification &&
                  notification.metrics.extentAfter < 400) {
                ref.read(newFeedProvider(widget.feedKey).notifier).loadMore();
              }
              return false;
            },
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: slivers,
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildSlivers(PagedFeedState feed) {
    final tail = <Widget>[
      if (feed.refreshPhase == FeedPhase.error)
        SliverToBoxAdapter(
          child: _NewRefreshError(
            onRetry: () =>
                ref.read(newFeedProvider(widget.feedKey).notifier).refresh(),
          ),
        ),
      SliverToBoxAdapter(
        child: _NewFeedTail(
          feed: feed,
          onRetry: () => ref
              .read(newFeedProvider(widget.feedKey).notifier)
              .retryLoadMore(),
        ),
      ),
    ];
    if (widget.feedKey.type == NewFeedType.illust) {
      final store = ref.watch(illustStoreProvider);
      final entities = store.getAll(feed.ids);
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          sliver: SliverMasonryGrid.count(
            crossAxisCount: 2,
            mainAxisSpacing: 5,
            crossAxisSpacing: 10,
            itemBuilder: (context, index) => IllustCard(
              entity: entities[index],
              heroScope:
                  'new:${widget.feedKey.scope.name}:${widget.feedKey.type.name}',
            ),
            childCount: entities.length,
          ),
        ),
        ...tail,
      ];
    }
    final storedNovels = ref.watch(novelStoreProvider);
    final entities = [
      for (final id in feed.ids)
        if (storedNovels[id] != null) storedNovels[id]!,
    ];
    return [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => NovelCard(entity: entities[index]),
          childCount: entities.length,
        ),
      ),
      ...tail,
    ];
  }
}

class _NewStatus extends StatelessWidget {
  const _NewStatus({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48),
          const SizedBox(height: 12),
          Text(title),
        ],
      ),
    );
  }
}

class _NewError extends StatelessWidget {
  const _NewError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text(_newText(context, 'newLoadFailed')),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onRetry,
              child: Text(_newText(context, 'newRetry')),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewRefreshError extends StatelessWidget {
  const _NewRefreshError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(_newText(context, 'newRefreshFailed'))),
          TextButton(
            onPressed: onRetry,
            child: Text(_newText(context, 'newRetry')),
          ),
        ],
      ),
    );
  }
}

class _NewFeedTail extends StatelessWidget {
  const _NewFeedTail({required this.feed, required this.onRetry});

  final PagedFeedState feed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (feed.showLoadMoreSpinner) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (feed.showLoadMoreError) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_newText(context, 'newLoadMoreFailed')),
            Text(
              '${feed.loadMoreError}',
              maxLines: 2,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton(
              onPressed: onRetry,
              child: Text(_newText(context, 'newRetry')),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

String _newText(BuildContext context, String key) => ReplicaStrings.fromTag(
  Localizations.localeOf(context).toLanguageTag(),
  key,
);
