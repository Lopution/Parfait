/// Canonical account-scoped spotlight article entries shared by the feed
/// page and the article route's header.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'spotlight_models.dart';

/// Account-scoped spotlight article map. Article payloads are complete on
/// every fetch (list rows carry all display fields), so merges overwrite.
class SpotlightArticleStore extends Notifier<Map<int, SpotlightArticle>> {
  @override
  Map<int, SpotlightArticle> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return {};
  }

  SpotlightArticle? get(int id) => state[id];

  List<SpotlightArticle> getAll(Iterable<int> ids) => [
    for (final id in ids)
      if (state[id] != null) state[id]!,
  ];

  void mergeAll(Iterable<SpotlightArticle> incoming) {
    final next = Map<int, SpotlightArticle>.of(state);
    for (final article in incoming) {
      next[article.id] = article;
    }
    state = next;
  }

  void clear() => state = {};
}

final spotlightArticleStoreProvider =
    NotifierProvider<SpotlightArticleStore, Map<int, SpotlightArticle>>(
      SpotlightArticleStore.new,
    );
