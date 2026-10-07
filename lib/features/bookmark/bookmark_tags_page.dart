import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/routes.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/bookmark/bookmark_tags_controller.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_tab_bar.dart';

/// The signed-in user's bookmark tag collection (`/v1/user/bookmark-tags/`)
/// in two tabs, public and private. Tapping a tag opens the filtered
/// bookmarks feed. Illust-only for now — the novel twin endpoint is wired in
/// the repository but has no UI consumer yet.
class BookmarkTagsPage extends StatefulWidget {
  const BookmarkTagsPage({
    super.key,
    this.initialRestrict = BookmarkRestrict.public,
  });

  final BookmarkRestrict initialRestrict;

  @override
  State<BookmarkTagsPage> createState() => _BookmarkTagsPageState();
}

class _BookmarkTagsPageState extends State<BookmarkTagsPage>
    with SingleTickerProviderStateMixin {
  static const _restricts = [BookmarkRestrict.public, BookmarkRestrict.private];

  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _restricts.length,
      vsync: this,
      initialIndex: _restricts.indexOf(widget.initialRestrict),
    );
  }

  @override
  void didUpdateWidget(covariant BookmarkTagsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRestrict != widget.initialRestrict) {
      _tabController.index = _restricts.indexOf(widget.initialRestrict);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppTopBar(
        title: Text(l10n.bookmarkTags),
        // The lists sit inside the TabBarView's page view.
        notificationPredicate: (notification) => notification.depth == 1,
        bottom: AppTabBar(
          controller: _tabController,
          labels: [l10n.restrictPublic, l10n.restrictPrivate],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          for (final restrict in _restricts) _RestrictTags(restrict: restrict),
        ],
      ),
    );
  }
}

/// One visibility's tags, refreshable and paged.
class _RestrictTags extends ConsumerWidget {
  const _RestrictTags({required this.restrict});

  final BookmarkRestrict restrict;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final BookmarkTagQuery query = (BookmarkEntityType.illust, restrict);
    final async = ref.watch(userBookmarkTagsProvider(query));
    return PullToRefresh(
      onRefresh: () =>
          ref.read(userBookmarkTagsProvider(query).notifier).refresh(),
      child: async.when(
        loading: () => const Center(child: FeedLoading()),
        error: (error, _) => FeedError(
          title: l10n.bookmarkTagsLoadFailed,
          error: error,
          retryLabel: l10n.retry,
          onRetry: () =>
              ref.read(userBookmarkTagsProvider(query).notifier).refresh(),
        ),
        data: (state) =>
            _TagList(query: query, state: state, restrict: restrict),
      ),
    );
  }
}

class _TagList extends ConsumerWidget {
  const _TagList({
    required this.query,
    required this.state,
    required this.restrict,
  });

  final BookmarkTagQuery query;
  final UserBookmarkTagsState state;
  final BookmarkRestrict restrict;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (state.tags.isEmpty) {
      return FeedEmpty(
        icon: Icons.label_outline,
        title: l10n.bookmarkTagsEmpty,
        retryLabel: l10n.retry,
        onRefresh: () =>
            ref.read(userBookmarkTagsProvider(query).notifier).refresh(),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            notification is ScrollUpdateNotification &&
            notification.metrics.extentAfter <
                notification.metrics.viewportDimension) {
          ref.read(userBookmarkTagsProvider(query).notifier).loadMore();
        }
        return false;
      },
      child: ListView.builder(
        itemCount: state.tags.length + 1,
        itemBuilder: (context, index) {
          if (index >= state.tags.length) {
            if (state.loadingMore) {
              return const Padding(
                padding: EdgeInsets.all(FuncSpacing.lg),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (state.loadMoreError != null) {
              return ListTile(
                title: Text(l10n.profileLoadMoreFailed),
                trailing: TextButton(
                  onPressed: () => ref
                      .read(userBookmarkTagsProvider(query).notifier)
                      .loadMore(),
                  child: Text(l10n.profileRetry),
                ),
              );
            }
            if (!state.hasMore) {
              return Padding(
                padding: const EdgeInsets.all(FuncSpacing.lg),
                child: Center(
                  child: Text(
                    l10n.bookmarkTagsEnd,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              );
            }
            return const SizedBox.shrink();
          }
          final tag = state.tags[index];
          return ListTile(
            leading: const Icon(Icons.label_outline),
            title: Text(tag.name),
            trailing: Text('${tag.count}'),
            onTap: () =>
                openBookmarkTagFeed(context, tag: tag.name, restrict: restrict),
          );
        },
      ),
    );
  }
}
