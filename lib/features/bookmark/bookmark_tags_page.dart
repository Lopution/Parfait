import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/route_facade.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/bookmark/bookmark_tags_controller.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/layout/content_widths.dart';
import '../../app/widgets/app_spinner.dart';
import '../../app/widgets/feed/load_more_listener.dart';
import '../../app/widgets/page_header.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../app/widgets/tab_swipe_switcher.dart';
import '../../app/icons/app_icons.dart';

/// The signed-in user's bookmark tag collection (`/v1/user/bookmark-tags/`)
/// of one [kind] in two tabs, public and private. Tapping a tag opens the
/// filtered bookmarks feed of that kind.
class BookmarkTagsPage extends StatefulWidget {
  const BookmarkTagsPage({
    super.key,
    this.kind = BookmarkEntityType.illust,
    this.initialRestrict = BookmarkRestrict.public,
  });

  final BookmarkEntityType kind;
  final BookmarkRestrict initialRestrict;

  @override
  State<BookmarkTagsPage> createState() => _BookmarkTagsPageState();
}

class _BookmarkTagsPageState extends State<BookmarkTagsPage>
    with SingleTickerProviderStateMixin {
  static const _restricts = [BookmarkRestrict.public, BookmarkRestrict.private];

  late final TabController _tabController;
  final _scrollControllers = <BookmarkRestrict, ScrollController>{};
  BuildContext? _notificationContext;
  int _selectedIndex = 0;

  BookmarkRestrict get _active => _restricts[_selectedIndex];

  ScrollController _scrollControllerFor(BookmarkRestrict restrict) =>
      _scrollControllers.putIfAbsent(
        restrict,
        () => ScrollController(
          onAttach: (_) {
            final ctx = _notificationContext;
            if (ctx != null && restrict == _active) {
              announceTabScroll(ctx, _scrollControllers[restrict]!);
            }
          },
        ),
      );

  void _onTabChanged() {
    if (_tabController.index != _selectedIndex) {
      setState(() => _selectedIndex = _tabController.index);
    }
    final ctx = _notificationContext;
    if (ctx != null) {
      announceTabScroll(ctx, _scrollControllerFor(_active));
    }
  }

  @override
  void initState() {
    super.initState();
    _selectedIndex = _restricts.indexOf(widget.initialRestrict);
    _tabController = TabController(
      length: _restricts.length,
      vsync: this,
      initialIndex: _selectedIndex,
    )..addListener(_onTabChanged);
  }

  @override
  void didUpdateWidget(covariant BookmarkTagsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRestrict != widget.initialRestrict) {
      _selectedIndex = _restricts.indexOf(widget.initialRestrict);
      _tabController.index = _selectedIndex;
    }
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return bindPrimaryScroll(
      controller: _scrollControllerFor(_active),
      child: Scaffold(
        appBar: AppTopBar(
          contentWidth: ContentWidths.management,
          title: Text(l10n.bookmarkTags),
          tabsBesideTitle: PageHeader.isWide(context),
          // The lists sit inside the TabBarView's page view.
          notificationPredicate: (notification) => notification.depth == 1,
          bottom: AppTabBar(
            controller: _tabController,
            labels: [l10n.restrictPublic, l10n.restrictPrivate],
          ),
        ),
        body: Builder(
          builder: (context) {
            _notificationContext = context;
            return TabBarView(
              controller: _tabController,
              children: [
                for (final restrict in _restricts)
                  ContentWidthCap(
                    maxWidth: ContentWidths.management,
                    child: _RestrictTags(
                      kind: widget.kind,
                      restrict: restrict,
                      scrollController: _scrollControllerFor(restrict),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One visibility's tags, refreshable and paged. Kept alive in the tab
/// view: its list goes with the page, not when the other tab shows.
class _RestrictTags extends ConsumerStatefulWidget {
  const _RestrictTags({
    required this.kind,
    required this.restrict,
    required this.scrollController,
  });

  final BookmarkEntityType kind;
  final BookmarkRestrict restrict;
  final ScrollController scrollController;

  @override
  ConsumerState<_RestrictTags> createState() => _RestrictTagsState();
}

class _RestrictTagsState extends ConsumerState<_RestrictTags>
    with AutomaticKeepAliveClientMixin<_RestrictTags> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = context.l10n;
    final restrict = widget.restrict;
    final BookmarkTagQuery query = (widget.kind, restrict);
    final async = ref.watch(userBookmarkTagsProvider(query));
    return PullToRefresh(
      scrollController: widget.scrollController,
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
        data: (state) => _TagList(
          query: query,
          state: state,
          restrict: restrict,
          scrollController: widget.scrollController,
        ),
      ),
    );
  }
}

class _TagList extends ConsumerWidget {
  const _TagList({
    required this.query,
    required this.state,
    required this.restrict,
    required this.scrollController,
  });

  final BookmarkTagQuery query;
  final UserBookmarkTagsState state;
  final BookmarkRestrict restrict;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (state.tags.isEmpty) {
      return CustomScrollView(
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: FeedEmpty(icon: AppIcons.tag, title: l10n.bookmarkTagsEmpty),
          ),
        ],
      );
    }
    return LoadMoreListener(
      itemCount: state.tags.length,
      onLoadMore: () =>
          ref.read(userBookmarkTagsProvider(query).notifier).loadMore(),
      child: SmoothWheelScroll(
        controller: scrollController,
        basePhysics: const AlwaysScrollableScrollPhysics(),
        builder: (context, controller, physics) => ListView.builder(
          controller: controller,
          physics: physics,
          itemCount: state.tags.length + 1,
          itemBuilder: (context, index) {
            if (index >= state.tags.length) {
              if (state.loadingMore) {
                return const Padding(
                  padding: EdgeInsets.all(FuncSpacing.lg),
                  child: Center(child: AppSpinner(size: 24, strokeWidth: 2)),
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
              leading: const Icon(AppIcons.tag),
              title: Text(tag.name),
              trailing: Text('${tag.count}'),
              onTap: () => openBookmarkTagFeed(
                context,
                tag: tag.name,
                kind: query.$1,
                restrict: restrict,
              ),
            );
          },
        ),
      ),
    );
  }
}
