import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_controller.dart';
import '../network/api_error.dart';
import 'article_parser.dart';
import 'spotlight_models.dart';
import 'spotlight_repository.dart';

/// Whether an article has passed pixivision's browser challenge in this
/// process. The clearance lives in the WebView cookie jar, bound to the
/// browser's fingerprint, so it is never copied into the HTTP client: once
/// set, later articles load through the challenge WebView directly instead of
/// failing over HTTP first.
final spotlightWebSessionProvider = NotifierProvider<SpotlightWebSession, bool>(
  SpotlightWebSession.new,
);

class SpotlightWebSession extends Notifier<bool> {
  @override
  bool build() => false;

  void markVerified() => state = true;
}

/// Fetches and parses one pixivision article body for in-app rendering.
/// The parsed body has no shared consumer, so it is not merged into the
/// SpotlightArticleStore — the store keeps the list entry (header data).
final spotlightArticleBodyProvider = FutureProvider.autoDispose
    .family<SpotlightArticleBody, ({int id, String url})>((ref, key) async {
      PixivSpotlightRepository.articleUri(key.url);
      // Read, not watched: marking the session verified must not rebuild the
      // article that is showing its WebView result.
      if (ref.read(spotlightWebSessionProvider)) {
        throw const ApiChallengeRequired();
      }
      final languageTag = ref.watch(settingsProvider).value?.languageTag;
      final html = await ref
          .read(spotlightRepositoryProvider)
          .fetchArticleHtml(key.url, languageTag: languageTag);
      return parseSpotlightArticle(html);
      // The page shows the error with its own retry button; Riverpod's
      // default retry would hold it in loading through the backoff.
    }, retry: (_, _) => null);
