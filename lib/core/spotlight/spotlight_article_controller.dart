import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_controller.dart';
import '../network/api_error.dart';
import 'article_parser.dart';
import 'spotlight_models.dart';
import 'spotlight_repository.dart';

/// Process-scoped WebView cookie state. The browser cookie jar is deliberately
/// not copied into the HTTP client; after one successful challenge, later
/// articles go straight to the same WebView session instead.
class SpotlightWebSession {
  SpotlightWebSession._();

  static bool _verified = false;

  static bool get isVerified => _verified;

  static void markVerified() => _verified = true;

  @visibleForTesting
  static void resetForTesting() => _verified = false;
}

/// Fetches and parses one pixivision article body for in-app rendering.
/// The parsed body has no shared consumer, so it is not merged into the
/// SpotlightArticleStore — the store keeps the list entry (header data).
final spotlightArticleBodyProvider = FutureProvider.autoDispose
    .family<SpotlightArticleBody, ({int id, String url})>((ref, key) async {
      if (SpotlightWebSession.isVerified) {
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
