import 'package:flutter/material.dart';

import '../../../app/widgets/feed/feed_grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_store.dart';
import '../../../app/widgets/feed/illust_card.dart';
import '../../../core/network/api_error.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../search/search_text.dart';
import 'related_illust_repository.dart';

export 'related_illust_repository.dart';

/// "関連作品" section slivers for the detail page, mirroring the official
/// Pixiv client: a two-column grid of related works (square cover + title +
/// author) below the caption/tags, paginated as the user scrolls. Each tile
/// pushes its own detail page.
class RelatedIllustsSlivers extends ConsumerWidget {
  const RelatedIllustsSlivers({super.key, required this.illustId});

  final int illustId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(relatedIllustControllerProvider(illustId));
    final state = async.asData?.value;
    final controller = ref.read(
      relatedIllustControllerProvider(illustId).notifier,
    );
    if (state == null) {
      if (async.hasError) {
        // Defensive branch: the controller normally folds errors into
        // state.initialError, but a provider-level failure must still show
        // a visible error instead of an endless spinner.
        final error = async.error;
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  searchText(context, 'relatedWorks'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: Text(_errorText(context, error))),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: controller.refresh,
                      child: Text(searchText(context, 'retry')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ),
      );
    }
    if (state.showInitialError) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                searchText(context, 'relatedWorks'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: Text(_errorText(context, state.initialError))),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: controller.refresh,
                    child: Text(searchText(context, 'retry')),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final store = ref.watch(illustStoreProvider);
    final illusts = store.getAll(state.ids);
    if (illusts.isEmpty) {
      // No related works: the official client shows nothing at all.
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
            child: Text(
              searchText(context, 'relatedWorks'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverToBoxAdapter(
            child: SizedBox.shrink(),
          ),
        ),
        IllustFeedGrid(
  padding: const EdgeInsets.symmetric(horizontal: 10),
  mainAxisSpacing: 10,
  crossAxisSpacing: 10,
  itemCount: illusts.length,
  itemBuilder: (context, index) => IllustCard(
              entity: illusts[index],
              // Same heroScope the detail page receives when a tile is
              // pushed: the flight lands on a card shaped exactly like the
              // artwork (adaptive ratio), so pop hands off without the
              // fixed-square crop flash.
              heroScope: 'related:$illustId:${illusts[index].id}',
            ),
),
        SliverToBoxAdapter(
          child: _LoadMoreFooter(state: state, onLoadMore: controller.loadMore),
        ),
      ],
    );
  }

  String _errorText(BuildContext context, Object? error) {
    final message = error is ApiError ? error.message : null;
    if (message != null && message.isNotEmpty) return message;
    if (error == null) return searchText(context, 'relatedLoadFailed');
    // Provider-level failures (parse/type errors) carry no ApiError
    // message: surface the runtime type + short description so a device
    // failure is diagnosable instead of a silent fallback.
    final detail = error.toString().replaceAll('\n', ' ').trim();
    final short = detail.length > 180 ? detail.substring(0, 180) : detail;
    return '${error.runtimeType}: $short';
  }
}

class _LoadMoreFooter extends ConsumerWidget {
  const _LoadMoreFooter({required this.state, required this.onLoadMore});

  final PagedFeedState state;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.loadMorePhase == FeedPhase.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (state.loadMorePhase == FeedPhase.error) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton(
            onPressed: () => onLoadMore(),
            child: Text(searchText(context, 'retry')),
          ),
        ),
      );
    }
    return const SizedBox(height: 6);
  }
}
