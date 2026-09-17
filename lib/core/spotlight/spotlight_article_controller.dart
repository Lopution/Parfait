import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_controller.dart';
import 'article_parser.dart';
import 'spotlight_models.dart';
import 'spotlight_repository.dart';

/// Fetches and parses one pixivision article body for in-app rendering.
/// The parsed body has no shared consumer, so it is not merged into the
/// SpotlightArticleStore — the store keeps the list entry (header data).
final spotlightArticleBodyProvider = FutureProvider.autoDispose
    .family<SpotlightArticleBody, ({int id, String url})>((ref, key) async {
      final languageTag = ref.watch(settingsProvider).value?.languageTag;
      final html = await ref
          .read(spotlightRepositoryProvider)
          .fetchArticleHtml(key.url, languageTag: languageTag);
      return parseSpotlightArticle(html);
    });
