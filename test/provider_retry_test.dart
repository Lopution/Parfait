import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/bookmark/bookmark_tags_controller.dart';
import 'package:parfait/core/errors/no_retry.dart';
import 'package:parfait/core/localnovel/local_novel_store.dart';
import 'package:parfait/core/search/search_trending_controller.dart';
import 'package:parfait/core/settings/server_display_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/spotlight/spotlight_article_controller.dart';
import 'package:parfait/core/watchlater/watch_later_store.dart';
import 'package:parfait/core/watchlist/watchlist_feed_controller.dart';

void main() {
  // STORE-01: each backs a page with its own error state and retry button.
  // server_display_settings_test shows what the default retry did to one.
  test('providers behind an error state do not retry', () {
    final retries = {
      'settings': settingsProvider.retry,
      'serverDisplaySettings': serverDisplaySettingsProvider.retry,
      'trendingTags': trendingTagsProvider.retry,
      'watchlistFeed': watchlistFeedProvider.retry,
      'userBookmarkTags': userBookmarkTagsProvider.retry,
      'watchLaterStore': watchLaterStoreProvider.retry,
      'localNovelStore': localNovelStoreProvider.retry,
      'spotlightArticleBody': spotlightArticleBodyProvider.retry,
    };
    for (final MapEntry(:key, :value) in retries.entries) {
      expect(value, same(noRetry), reason: key);
    }
  });

  // STORE-16: a family keyed by what a page shows is autoDispose and goes
  // with its page. Only the home tabs, which keep their place across
  // visits, are kept for the session.
  test('only the home tab families outlive their pages', () {
    final family = RegExp(r'final\s+(\w+)\s*=\s*\w+Provider\s*\.\s*family\b');
    final kept = {
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File && file.path.endsWith('.dart'))
          for (final match in family.allMatches(file.readAsStringSync()))
            match[1],
    };
    expect(kept, {
      'recommendedFeedProvider',
      'rankingFeedControllerProvider',
      'novelRankingFeedProvider',
      'newFeedProvider',
      'watchlistFeedProvider',
      'spotlightFeedProvider',
      'trendingTagsProvider',
    });
  });
}
