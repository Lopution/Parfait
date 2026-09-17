import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/json_read.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'spotlight_models.dart';

/// One page of `/v1/spotlight/articles`.
class SpotlightArticlePage {
  const SpotlightArticlePage({required this.articles, required this.nextUrl});

  final List<SpotlightArticle> articles;
  final String? nextUrl;
}

/// pixivision spotlight API boundary. Owns response normalization and
/// next-page validation; controllers only receive typed pages.
class PixivSpotlightRepository {
  PixivSpotlightRepository(this._client);

  final PixivHttpClient _client;

  static const _articlesPath = '/v1/spotlight/articles';

  /// Article list for one [category], paged via `next_url` offset.
  Future<SpotlightArticlePage> fetchArticles({
    SpotlightCategory category = SpotlightCategory.all,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final expected = {'filter': 'for_android', 'category': category.name};
    final NextPageRequest request;
    try {
      request = cursor == null
          ? NextPageParser.firstPage(_articlesPath, expected)
          : NextPageParser.parse(cursor)!;
      _validateCursor(request, expected);
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseArticlesPage(json);
  }

  bool validateArticlesCursor(
    SpotlightCategory category, {
    required String cursor,
  }) {
    try {
      final request = NextPageParser.parse(cursor);
      if (request == null) return false;
      _validateCursor(request, {
        'filter': 'for_android',
        'category': category.name,
      });
      return true;
    } on NextPageParseError {
      return false;
    }
  }

  void _validateCursor(NextPageRequest request, Map<String, String> expected) {
    if (request.uri.path != _articlesPath) {
      throw NextPageParseError(
        'next_url endpoint does not match $_articlesPath: ${request.uri.path}',
      );
    }
    for (final entry in expected.entries) {
      if (request.query[entry.key] != entry.value) {
        throw NextPageParseError(
          'next_url ${entry.key} does not match the active spotlight feed',
        );
      }
    }
  }

  Uri _target(NextPageRequest request) {
    if (request.uri.hasScheme) return request.uri;
    return PixivClientIdentity.appApiBase.replace(
      path: request.uri.path,
      query: request.uri.query,
    );
  }

  SpotlightArticlePage _parseArticlesPage(Map<String, dynamic> json) {
    final raw = json['spotlight_articles'];
    if (raw is! List) {
      throw const ApiParseError(
        'spotlight_articles list is missing or malformed',
      );
    }
    try {
      return SpotlightArticlePage(
        articles: [
          for (final item in raw)
            if (item is Map<String, dynamic>)
              SpotlightArticle.fromJson(item)
            else
              throw const FormatException(
                'spotlight_articles has a non-object',
              ),
        ],
        nextUrl: readNextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }
}

final spotlightRepositoryProvider = Provider<PixivSpotlightRepository>((ref) {
  return PixivSpotlightRepository(ref.watch(pixivHttpClientProvider));
});
