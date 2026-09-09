import 'package:material_ui/material_ui.dart';

import '../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pull_to_refresh.dart';
import '../../app/widgets/novel_card.dart';
import '../../core/entity/illust_store.dart';
import '../../core/new/new_feed_controller.dart';
import '../../core/new/new_feed_models.dart';
import '../../core/network/api_error.dart';
import '../../core/novel/novel_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

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
          // Evenly distribute across the full width (same logic as the
          // bottom navigation row), instead of a start-aligned scrollable.
          isScrollable: false,
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
            duration: MotionTokens.fast,
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
                    child: _NewFeedBody(key: ValueKey(key), feedKey: key),
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
class _NewFeedBody extends ConsumerStatefulWidget {
  const _NewFeedBody({super.key, required this.feedKey});

  final NewFeedKey feedKey;

  @override
  ConsumerState<_NewFeedBody> createState() => _NewFeedBodyState();
}

class _NewFeedBodyState extends ConsumerState<_NewFeedBody> {
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
      loading: () => FeedEmpty(
        icon: Icons.fiber_new_outlined,
        title: context.l10n.newLoading,
      ),
      error: (error, _) => FeedError(
        title: context.l10n.newLoadFailed,
        error: error,
        retryLabel: context.l10n.newRetry,
        onRetry: () => ref.invalidate(newFeedProvider(widget.feedKey)),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.newLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.newRetry,
            onRetry: () => ref
                .read(newFeedProvider(widget.feedKey).notifier)
                .retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return FeedEmpty(
            icon: Icons.fiber_new_outlined,
            title: context.l10n.newLoading,
          );
        }
        if (feed.isEmptyAndReady) {
          return FeedEmpty(
            icon: Icons.inbox_outlined,
            title: context.l10n.newEmpty,
            retryLabel: context.l10n.newRetry,
            onRefresh: () =>
                ref.read(newFeedProvider(widget.feedKey).notifier).refresh(),
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
          child: Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(child: Text(context.l10n.newRefreshFailed)),
                TextButton(
                  onPressed: () => ref
                      .read(newFeedProvider(widget.feedKey).notifier)
                      .refresh(),
                  child: Text(context.l10n.newRetry),
                ),
              ],
            ),
          ),
        ),
      SliverToBoxAdapter(
        child: FeedTail(
          feed: feed,
          onRetry: () => ref
              .read(newFeedProvider(widget.feedKey).notifier)
              .retryLoadMore(),
          errorTitle: context.l10n.newLoadMoreFailed,
          retryLabel: context.l10n.newRetry,
        ),
      ),
    ];
    if (widget.feedKey.type == NewFeedType.illust) {
      final store = ref.watch(illustStoreProvider);
      final entities = store.getAll(feed.ids);
      return [
        IllustFeedGrid(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          mainAxisSpacing: 5,
          crossAxisSpacing: 10,
          itemCount: entities.length,
          itemBuilder: (context, index) => IllustCard(
            entity: entities[index],
            heroScope:
                'new:${widget.feedKey.scope.name}:${widget.feedKey.type.name}',
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

String _newText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);
