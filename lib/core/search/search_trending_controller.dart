import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_store.dart';
import '../network/pixiv_http_client.dart';
import 'search_repository.dart';

final trendingTagsProvider = FutureProvider.autoDispose<List<TrendingTag>>((
  ref,
) async {
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
