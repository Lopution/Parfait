import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pixiv_image.dart';
import '../../app/replica_page_route.dart';
import '../../core/entity/illust_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import 'tag_search_repository.dart';

/// Minimal real tag-result grid (detail R5); the Search task will reuse
/// [TagSearchController] and this grid layout.
class TagSearchPage extends ConsumerWidget {
  const TagSearchPage({super.key, required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tagSearchControllerProvider(keyword));
    return Scaffold(
      appBar: AppBar(title: Text(keyword)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => _ErrorView(
          error: error,
          onRetry: () => ref
              .read(tagSearchControllerProvider(keyword).notifier)
              .retryInitial(),
        ),
        data: (PagedFeedState feed) {
          if (feed.showInitialError) {
            return _ErrorView(
              error: feed.initialError ?? '未知错误',
              onRetry: () => ref
                  .read(tagSearchControllerProvider(keyword).notifier)
                  .retryInitial(),
            );
          }
          final store = ref.watch(illustStoreProvider);
          final entities = store.getAll(feed.ids);
          return GridView.builder(
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
            ),
            itemCount: entities.length,
            itemBuilder: (context, index) => PixivImage(
              url: entities[index].imageUrls.squareMedium,
            ),
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

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
            const Text('标签搜索失败'),
            const SizedBox(height: 8),
            Text('$error', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

/// Convenience push helper with the Replica right-in rhythm.
void showTagSearch(BuildContext context, String keyword) {
  Navigator.of(context).push(
    ReplicaPageRoute<void>(
      builder: (_) => TagSearchPage(keyword: keyword),
    ),
  );
}
