import 'package:material_ui/material_ui.dart';

import '../../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/pixiv_image.dart';
import '../../../app/pull_to_refresh.dart';
import '../../../app/navigation/routes.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/network/api_error.dart';
import '../../../core/novel/novel_entity.dart';
import '../../../core/novel/novel_store.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../../core/user/user_entity.dart';
import '../../../core/user/user_store.dart';
import '../../../core/illust/recommended_feed_controller.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/feed/illust_card.dart';
import '../../../app/widgets/author_summary.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../core/illust/recommended_repository.dart';
import '../../../l10n/context.dart';
import '../../../l10n/lookup.dart';
import '../../../app/widgets/smooth_wheel_scroll.dart';

String _recommendedText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

/// Home recommended tab with the beta56 content selector:
/// 插画 / 漫画 / 小说 / 用户. Each type keeps its own cursor/scroll state
/// via the Offstage stack, so switching back does not refetch.
class RecommendedHomePage extends StatefulWidget {
  const RecommendedHomePage({super.key});

  @override
  State<RecommendedHomePage> createState() => _RecommendedHomePageState();
}

class _RecommendedHomePageState extends State<RecommendedHomePage>
    with SingleTickerProviderStateMixin {
  static const _types = RecommendedContentType.values;

  late final TabController _tabController;
  RecommendedContentType _type = RecommendedContentType.illust;
  final Set<RecommendedContentType> _loaded = {RecommendedContentType.illust};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _types.length, vsync: this)
      ..addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _types.indexOf(_type)) return;
    setState(() {
      _type = _types[_tabController.index];
      _loaded.add(_type);
    });
  }

  void _selectType(RecommendedContentType type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      _loaded.add(type);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Same chrome as Ranking/New/Search: AppBar with an embedded TabBar.
    // Before this the selector was a bare TabBar pinned below the status
    // bar, which visually diverged from every other tab (no AppBar height,
    // no surface elevation) — the three tabs looked like three apps.
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _RecommendedTypeSelector(
          type: _type,
          onChanged: _selectType,
          controller: _tabController,
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          for (final type in _loaded)
            Offstage(
              offstage: type != _type,
              child: _RecommendedFeedView(key: ValueKey(type), type: type),
            ),
        ],
      ),
    );
  }
}

class _RecommendedTypeSelector extends StatelessWidget {
  const _RecommendedTypeSelector({
    required this.type,
    required this.onChanged,
    required this.controller,
  });

  final RecommendedContentType type;
  final ValueChanged<RecommendedContentType> onChanged;
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    // Same chrome as Ranking/New/Search: a bare TabBar inside the AppBar
    // title (no extra Material/SizedBox — the AppBar constrains height and
    // provides the surface).
    return TabBar(
      controller: controller,
      // Evenly distribute across the full width (same logic as the bottom
      // navigation row) instead of a start-aligned scrollable.
      isScrollable: false,
      indicatorSize: TabBarIndicatorSize.label,
      indicatorPadding: const EdgeInsets.only(bottom: 5),
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      onTap: (index) => onChanged(RecommendedContentType.values[index]),
      tabs: [
        for (final value in RecommendedContentType.values)
          Tab(text: _recommendedText(context, _labelKey(value))),
      ],
    );
  }

  static String _labelKey(RecommendedContentType type) => switch (type) {
    RecommendedContentType.illust => 'recommendedIllust',
    RecommendedContentType.manga => 'recommendedManga',
    RecommendedContentType.novel => 'recommendedNovel',
    RecommendedContentType.user => 'recommendedUser',
  };
}

/// One keyed recommended feed body. Watches [recommendedFeedProvider] and
/// renders the right card shape for the type.
class _RecommendedFeedView extends ConsumerWidget {
  const _RecommendedFeedView({super.key, required this.type});

  final RecommendedContentType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (type: type);
    final feedAsync = ref.watch(recommendedFeedProvider(key));

    return feedAsync.when(
      loading: () => const FeedLoading(),
      error: (error, _) => FeedError(
        title: context.l10n.recommendedLoadFailed,
        error: error,
        retryLabel: context.l10n.retry,
        onRetry: () => ref.invalidate(recommendedFeedProvider(key)),
      ),
      data: (feed) {
        if (feed.showInitialError) {
          return FeedError(
            title: context.l10n.recommendedLoadFailed,
            error: feed.initialError ?? const ApiParseError('unknown error'),
            retryLabel: context.l10n.retry,
            onRetry: () =>
                ref.read(recommendedFeedProvider(key).notifier).retryInitial(),
          );
        }
        if (feed.showInitialSpinner) {
          return const FeedLoading();
        }
        if (feed.isEmptyAndReady) {
          return FeedEmpty(
            title: context.l10n.recommendedEmpty,
            onRefresh: () =>
                ref.read(recommendedFeedProvider(key).notifier).refresh(),
          );
        }
        return _RecommendedFeedBody(
          type: type,
          feed: feed,
          onRefresh: () =>
              ref.read(recommendedFeedProvider(key).notifier).refresh(),
          onLoadMore: () =>
              ref.read(recommendedFeedProvider(key).notifier).loadMore(),
          onRetryLoadMore: () =>
              ref.read(recommendedFeedProvider(key).notifier).retryLoadMore(),
          onRetryRefresh: () =>
              ref.read(recommendedFeedProvider(key).notifier).refresh(),
        );
      },
    );
  }
}

class _RecommendedFeedBody extends ConsumerWidget {
  const _RecommendedFeedBody({
    required this.type,
    required this.feed,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onRetryLoadMore,
    required this.onRetryRefresh,
  });

  final RecommendedContentType type;
  final PagedFeedState feed;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final VoidCallback onRetryLoadMore;
  final VoidCallback onRetryRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tail = <Widget>[
      if (feed.refreshPhase == FeedPhase.error)
        SliverToBoxAdapter(
          child: FeedTail(
            feed: feed.copyWith(loadMorePhase: FeedPhase.error),
            onRetry: onRetryRefresh,
            retryLabel: context.l10n.retry,
          ),
        ),
      SliverToBoxAdapter(
        child: FeedTail(
          feed: feed,
          onRetry: onRetryLoadMore,
          endMessage: context.l10n.recommendedEnd,
          retryLabel: context.l10n.retry,
        ),
      ),
    ];

    final slivers = switch (type) {
      RecommendedContentType.illust ||
      RecommendedContentType.manga => _illustSlivers(context, ref, tail),
      RecommendedContentType.novel => _novelSlivers(context, ref, tail),
      RecommendedContentType.user => _userSlivers(context, ref, tail),
    };

    return PullToRefresh(
      onRefresh: onRefresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification &&
              notification.metrics.extentAfter < 400) {
            onLoadMore();
          }
          return false;
        },
        child: SmoothWheelScroll(
          basePhysics: const AlwaysScrollableScrollPhysics(),
          builder: (context, controller, physics) => CustomScrollView(
            key: PageStorageKey('recommended-${type.name}'),
            physics: physics,
            restorationId: 'recommended-${type.name}',
            controller: controller,
            slivers: slivers,
          ),
        ),
      ),
    );
  }

  List<Widget> _illustSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final store = ref.watch(illustStoreProvider);
    final entities = store.getAll(feed.ids);
    return [
      IllustFeedGrid(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
        mainAxisSpacing: 5,
        crossAxisSpacing: 10,
        itemCount: entities.length,
        itemBuilder: (context, index) => IllustCard(
          entity: entities[index],
          heroScope: 'recommended:${type.name}',
        ),
      ),
      ...tail,
    ];
  }

  List<Widget> _novelSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final storedNovels = ref.watch(novelStoreProvider);
    final novels = [
      for (final id in feed.ids)
        if (storedNovels[id] != null) storedNovels[id]!,
    ];
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: 8),
        sliver: SliverList.builder(
          itemCount: novels.length,
          itemBuilder: (context, index) => _NovelRow(entity: novels[index]),
        ),
      ),
      ...tail,
    ];
  }

  List<Widget> _userSlivers(
    BuildContext context,
    WidgetRef ref,
    List<Widget> tail,
  ) {
    final storedUsers = ref.watch(userStoreProvider);
    final users = [
      for (final id in feed.ids)
        if (storedUsers[id] != null) storedUsers[id]!,
    ];
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: 8),
        sliver: SliverList.builder(
          itemCount: users.length,
          itemBuilder: (context, index) => _UserRow(entity: users[index]),
        ),
      ),
      ...tail,
    ];
  }
}

class _NovelRow extends StatelessWidget {
  const _NovelRow({required this.entity});

  final NovelEntity entity;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: () => openNovel(context, entity.id),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _NovelCover(entity: entity),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entity.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      entity.user.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${entity.textLength} ${context.l10n.novelWords}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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

class _NovelCover extends StatelessWidget {
  const _NovelCover({required this.entity});

  final NovelEntity entity;

  @override
  Widget build(BuildContext context) {
    final url = entity.coverImageUrl;
    if (url == null) {
      return Container(
        width: 56,
        height: 72,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: const Icon(Icons.menu_book_outlined),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 56,
        height: 72,
        child: PixivImage.feed(
          url,
          layoutWidth: 56,
          fit: BoxFit.cover,
          placeholderColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({required this.entity});

  final UserEntity entity;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: () => openUser(context, entity.id),
        borderRadius: FuncShape.control,
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: AuthorSummary(
                  name: entity.name,
                  account: entity.account,
                  imageUrl: entity.profileImageUrl,
                  avatarRadius: 24,
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
