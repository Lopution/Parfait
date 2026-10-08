import 'package:material_ui/material_ui.dart';

import '../../../app/widgets/feed/feed_grid.dart';
import '../../../app/widgets/feed/feed_states.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_store.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../app/widgets/feed/illust_card.dart';
import '../../../app/widgets/skeleton/illust_grid_skeleton.dart';
import '../../../core/errors/error_category.dart';
import '../../../core/paging/paged_feed_controller.dart';
import '../../../core/illust/related_illust_controller.dart';
import '../../../l10n/context.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import 'on_demand_sliver.dart';

export '../../../core/illust/related_illust_controller.dart';
export '../../../core/illust/related_illust_repository.dart';

/// "関連作品" section slivers for the detail page, mirroring the official
/// Pixiv client: a two-column grid of related works (square cover + title +
/// author) below the caption/tags, paginated as the user scrolls. Each tile
/// pushes its own detail page.
///
/// The first page is requested on demand ([OnDemandSliver]): only once the
/// section is on screen on the page the user is looking at. A work whose
/// related list already exists renders it straight away.
const _gridMainAxisSpacing = FuncSpacing.sm;

class RelatedIllustsSlivers extends ConsumerStatefulWidget {
  const RelatedIllustsSlivers({super.key, required this.illustId});

  final int illustId;

  @override
  ConsumerState<RelatedIllustsSlivers> createState() =>
      _RelatedIllustsSliversState();
}

class _RelatedIllustsSliversState extends ConsumerState<RelatedIllustsSlivers> {
  @override
  Widget build(BuildContext context) {
    final provider = relatedIllustControllerProvider(widget.illustId);
    return OnDemandSliver(
      id: 'related-${widget.illustId}',
      alreadyRequested: () => ref.exists(provider),
      // Same box as the loading spinner, so starting the request does not
      // shift anything.
      placeholder: _indicatorBox(null),
      sliver: _buildSection,
    );
  }

  static Widget _indicatorBox(Widget? indicator) => Padding(
    padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xxl),
    child: Center(child: SizedBox(width: 22, height: 22, child: indicator)),
  );

  Widget _buildSection(BuildContext context) {
    final provider = relatedIllustControllerProvider(widget.illustId);
    final async = ref.watch(provider);
    final state = async.asData?.value;
    // A retry after a failed first page is loading too, with no ids yet.
    final loading = state == null
        ? !async.hasError
        : state.showInitialSpinner && state.ids.isEmpty;
    final failed = !loading && (state == null || state.showInitialError);
    return AutoRetry(
      failed: failed,
      error: state == null ? async.error : state.initialError,
      onRetry: () => ref.read(provider.notifier).retryInitial(),
      // The skeleton gives way in place, as in Shaft: a section fading in
      // around images that fade in on their own stacks two fades.
      child: loading
          ? const _RelatedSkeleton()
          : _buildLoaded(context, async, state),
    );
  }

  Widget _buildLoaded(
    BuildContext context,
    AsyncValue<PagedFeedState> async,
    PagedFeedState? state,
  ) {
    final illustId = widget.illustId;
    final controller = ref.read(
      relatedIllustControllerProvider(illustId).notifier,
    );
    if (state == null || state.showInitialError) {
      // A null state that is not loading means the provider itself failed.
      // Defensive: the controller normally folds errors into
      // state.initialError, but that failure must still show a visible
      // error instead of an endless skeleton.
      final error = state == null ? async.error : state.initialError;
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.lg,
            FuncSpacing.lg,
            FuncSpacing.lg,
            FuncSpacing.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.relatedWorks,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: FuncSpacing.md),
              _errorRow(context, error, controller.refresh),
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
        const SliverToBoxAdapter(child: _RelatedHeader()),
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: FuncSpacing.md),
          sliver: SliverToBoxAdapter(child: SizedBox.shrink()),
        ),
        IllustFeedGrid(
          mainAxisSpacing: _gridMainAxisSpacing,
          itemIds: [for (final e in illusts) e.id],
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

  /// The one failure row shape this section uses: a localized category
  /// line plus the raw text behind [ErrorDetails], with retry beside it.
  /// A null error (defensive branch) still gets the localized headline.
  Widget _errorRow(BuildContext context, Object? error, VoidCallback onRetry) {
    return RetryOnNetworkRestore(
      error: error,
      onRetry: onRetry,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: error == null
                ? Text(context.l10n.relatedLoadFailed)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(errorCategoryText(context, categorizeError(error))),
                      ErrorDetails(error: error),
                    ],
                  ),
          ),
          const SizedBox(width: FuncSpacing.md),
          TextButton(onPressed: onRetry, child: Text(context.l10n.retry)),
        ],
      ),
    );
  }
}

/// The section title above the grid.
class _RelatedHeader extends StatelessWidget {
  const _RelatedHeader();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FuncSpacing.lg,
      FuncSpacing.lg,
      FuncSpacing.lg,
      FuncSpacing.sm,
    ),
    child: Text(
      context.l10n.relatedWorks,
      style: Theme.of(context).textTheme.titleMedium,
    ),
  );
}

/// The first page loading: the real title over a grid skeleton with the
/// grid's spacing, so the first cards land where their bones were.
class _RelatedSkeleton extends StatelessWidget {
  const _RelatedSkeleton();

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _RelatedHeader(),
        IllustGridSkeleton(
          label: context.l10n.contentLoading,
          mainAxisSpacing: _gridMainAxisSpacing,
        ),
      ],
    ),
  );
}

class _LoadMoreFooter extends ConsumerWidget {
  const _LoadMoreFooter({required this.state, required this.onLoadMore});

  final PagedFeedState state;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.loadMorePhase == FeedPhase.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: FuncSpacing.lg),
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
      return RetryOnNetworkRestore(
        error: state.loadMoreError,
        onRetry: onLoadMore,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
          child: Center(
            child: TextButton(
              onPressed: onLoadMore,
              child: Text(context.l10n.retry),
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: FuncSpacing.sm);
  }
}
