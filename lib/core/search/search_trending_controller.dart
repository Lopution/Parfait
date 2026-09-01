import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_store.dart';
import '../network/pixiv_http_client.dart';
import 'search_repository.dart';

/// Trending tags for the search guide.
///
/// Deliberately not `autoDispose`: the list is a once-per-session discovery
/// surface, and disposing it on every pop meant re-requesting
/// `/v1/trending-tags/illust` each time the user opened search. Keeping the
/// provider alive also lets an in-flight request finish and land, so a second
/// visit renders immediately. It still rebuilds when the account changes.
final trendingTagsProvider = FutureProvider<List<TrendingTag>>((ref) async {
  ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
  final token = CancelToken();
  ref.onDispose(token.cancel);
  final tags = await ref
      .read(searchRepositoryProvider)
      .trendingTags(cancelToken: token);
  final representatives = [
    for (final tag in tags)
      if (tag.representative != null) tag.representative!,
  ];
  if (representatives.isNotEmpty) {
    final store = ref.read(illustStoreProvider);
    store.mergeAll(
      representatives,
      bookmarkSnapshotRevision: store.bookmarkRevisionNow(),
    );
  }
  return tags;
});
