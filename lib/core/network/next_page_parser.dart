/// Validates a `next_url` from a paginated Pixiv response into a request the
/// client is allowed to issue.
///
/// The URL must be HTTPS on the one Pixiv API host, so a response can never
/// redirect the client at an arbitrary origin. Its path and parameters are
/// Pixiv's own cursor state: each repository pins the endpoint and identity
/// parameters it expects, and anything else is passed through. Enumerating
/// Pixiv's parameters here only breaks paging the next time they add one.
class NextPageRequest {
  const NextPageRequest({required this.uri});

  /// The validated URI; the client re-derives scheme/host from the identity
  /// allowlist before issuing anything.
  final Uri uri;

  Map<String, String> get query => uri.queryParameters;
}

class NextPageParseError implements Exception {
  const NextPageParseError(this.reason);

  final String reason;

  @override
  String toString() => 'NextPageParseError($reason)';
}

/// First-page endpoint registry: path -> query parameter names this client
/// sends. It describes the requests we construct, not the cursors Pixiv
/// returns.
///
/// Features extend this registry when they introduce paginated endpoints.
const Map<String, Set<String>> kNextPageEndpoints = {
  '/v1/illust/recommended': {
    'content_type',
    'include_ranking_illusts',
    'filter',
    'min_bookmark_id_for_recent_illust',
    'max_bookmark_id_for_recommend',
    'include_privacy_policy',
    'offset',
  },
  '/v2/illust/follow': {'filter', 'restrict', 'offset'},
  '/v2/illust/mypixiv': {'filter', 'offset'},
  '/v1/illust/new': {'filter', 'content_type', 'offset'},
  '/v1/illust/ranking': {'filter', 'mode', 'date', 'offset'},
  '/v1/search/illust': {
    'word',
    'search_target',
    'sort',
    'duration',
    'start_date',
    'end_date',
    'filter',
    'offset',
  },
  '/v1/search/novel': {
    'word',
    'search_target',
    'sort',
    'duration',
    'start_date',
    'end_date',
    'filter',
    'offset',
  },
  '/v1/search/user': {'word', 'filter', 'offset'},
  '/v1/mypixiv/all': {'offset'},
  '/v1/user/bookmarks/illust': {'user_id', 'restrict', 'offset'},
  '/v1/user/bookmarks/novel': {'user_id', 'restrict', 'offset'},
  '/v1/user/illusts': {'filter', 'user_id', 'type', 'offset'},
  '/v1/user/novels': {'filter', 'user_id', 'offset'},
  '/v2/novel/series': {'filter', 'series_id', 'last_order'},
  '/v1/user/following': {'filter', 'user_id', 'restrict', 'offset'},
  '/v1/user/follower': {'filter', 'user_id', 'offset'},
  '/v1/user/mypixiv': {'filter', 'user_id', 'offset'},
  '/v1/novel/follow': {'filter', 'restrict', 'offset'},
  '/v1/novel/mypixiv': {'filter', 'offset'},
  '/v1/novel/new': {'filter', 'offset'},
  '/v3/illust/comments': {'illust_id', 'offset'},
  '/v2/illust/comment/replies': {'comment_id', 'offset'},
};

abstract final class NextPageParser {
  /// Parses [nextUrl]; `null` (no next page) passes through as `null`.
  ///
  /// Throws [NextPageParseError] when the URL does not point at the Pixiv API
  /// host over HTTPS.
  static NextPageRequest? parse(String? nextUrl) {
    if (nextUrl == null || nextUrl.isEmpty) return null;
    final Uri uri;
    try {
      uri = Uri.parse(nextUrl);
    } on FormatException catch (error) {
      throw NextPageParseError('unparsable next_url: ${error.message}');
    }
    if (uri.scheme != 'https') {
      throw NextPageParseError('next_url must be https');
    }
    if (uri.host != 'app-api.pixiv.net') {
      throw NextPageParseError('unknown next_url host: ${uri.host}');
    }
    if (uri.userInfo.isNotEmpty || (uri.hasPort && uri.port != 443)) {
      throw NextPageParseError(
        'next_url must use the default port without userinfo',
      );
    }
    return NextPageRequest(uri: uri);
  }

  /// Builds the first-page request for an endpoint with typed query values.
  static NextPageRequest firstPage(String path, Map<String, String> query) {
    if (!kNextPageEndpoints.containsKey(path)) {
      throw NextPageParseError('unknown endpoint: $path');
    }
    final allowedParams = kNextPageEndpoints[path]!;
    for (final name in query.keys) {
      if (!allowedParams.contains(name)) {
        throw NextPageParseError('unknown query parameter "$name" for $path');
      }
    }
    return NextPageRequest(
      uri: Uri(path: path, queryParameters: query),
    );
  }
}
