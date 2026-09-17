import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../entity/json_read.dart';
import '../network/api_error.dart';
import '../network/http_client_providers.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'spotlight_models.dart';

/// One page of `/v1/spotlight/articles`.
class SpotlightArticlesPage {
  const SpotlightArticlesPage({required this.articles, required this.nextUrl});

  final List<SpotlightArticle> articles;
  final String? nextUrl;
}

/// pixivision spotlight API boundary. Owns response normalization and
/// next-page validation; controllers only receive typed pages.
///
/// Article HTML is fetched through [_webClient] (the shared third-party
/// client): www.pixivision.net is not the authenticated app-API host and
/// must not carry app-API credentials.
class PixivSpotlightRepository {
  PixivSpotlightRepository(this._client, this._webClient);

  final PixivHttpClient _client;
  final http.Client _webClient;

  static const _articlesPath = '/v1/spotlight/articles';
  static const _articleHost = 'www.pixivision.net';

  /// A desktop UA is required — pixivision serves a reduced document to the
  /// Android app identity.
  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// Article list for one [category], paged via `next_url` offset.
  Future<SpotlightArticlesPage> fetchArticles({
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

  /// Fetches one article page for in-app rendering. The URL comes from
  /// `article_url` (or the route's `?url=` override); only pixivision.net
  /// pages are fetched — anything else is rejected before any request.
  ///
  /// `package:http` has no cancellation, so [cancelToken] is honoured as a
  /// pre/post-request check rather than an in-flight abort.
  Future<String> fetchArticleHtml(
    String url, {
    String? languageTag,
    CancelToken? cancelToken,
  }) async {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      throw const ApiParseError('spotlight article url is malformed');
    }
    if (uri.scheme != 'https' || uri.host != _articleHost) {
      throw const ApiParseError(
        'spotlight article url must be a pixivision.net page',
      );
    }
    if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
    final response = await _webClient.get(
      uri,
      headers: {
        'User-Agent': _desktopUserAgent,
        'Referer': 'https://$_articleHost/',
        'Accept-Language': languageTag ?? 'zh-CN',
      },
    );
    if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
    if (response.statusCode != 200) {
      throw ApiHttpError(response.statusCode, 'spotlight article fetch failed');
    }
    return response.body;
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

  SpotlightArticlesPage _parseArticlesPage(Map<String, dynamic> json) {
    final raw = json['spotlight_articles'];
    if (raw is! List) {
      throw const ApiParseError(
        'spotlight_articles list is missing or malformed',
      );
    }
    try {
      return SpotlightArticlesPage(
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
  return PixivSpotlightRepository(
    ref.watch(pixivHttpClientProvider),
    ref.watch(thirdPartyHttpClientProvider),
  );
});
