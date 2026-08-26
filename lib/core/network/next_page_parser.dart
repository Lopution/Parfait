/// Validates and degrades a `next_url` from a paginated Pixiv response into
/// a request the client is allowed to issue.
///
/// Only HTTPS, allowlisted Pixiv API hosts, known endpoints and known query
/// parameters are accepted. Arbitrary absolute URLs are never requested.
class NextPageRequest {
  const NextPageRequest({required this.uri});

  /// The validated URI; the client re-derives scheme/host from the identity
  /// allowlist before issuing anything.
  final Uri uri;

  Map<String, String> get query => uri.queryParameters;
}

class NextPageParseError implements Exception {
  NextPageParseError(this.reason);

  final String reason;

  @override
  String toString() => 'NextPageParseError($reason)';
}

/// Endpoint registry: path -> allowed query parameter names.
///
/// Features extend this registry when they introduce paginated endpoints.
const Map<String, Set<String>> kNextPageEndpoints = {
  '/v1/illust/recommended': {
    'content_type',
    'include_ranking_illusts',
    'filter',
    'min_bookmark_id_for_recent_illust',
    'offset',
  },
  '/v2/illust/follow': {'restrict', 'offset'},
  '/v1/illust/ranking': {'mode', 'date', 'offset'},
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
  '/v1/mypixiv/all': {'offset'},
  '/v1/user/bookmarks/illust': {'user_id', 'restrict', 'offset'},
};

abstract final class NextPageParser {
  /// Parses [nextUrl]; `null` (no next page) passes through as `null`.
  ///
  /// Throws [NextPageParseError] for anything not explicitly allowlisted.
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
    if (uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      throw NextPageParseError(
          'next_url must use the default port without userinfo');
    }
    if (!kNextPageEndpoints.containsKey(uri.path)) {
      throw NextPageParseError('unknown next_url endpoint: ${uri.path}');
    }
    final allowedParams = kNextPageEndpoints[uri.path]!;
    for (final name in uri.queryParameters.keys) {
      if (!allowedParams.contains(name)) {
        throw NextPageParseError(
          'unknown query parameter "$name" for ${uri.path}',
        );
      }
    }
    return NextPageRequest(uri: uri);
  }

  /// Builds the first-page request for an endpoint with typed query values.
  static NextPageRequest firstPage(
    String path,
    Map<String, String> query,
  ) {
    if (!kNextPageEndpoints.containsKey(path)) {
      throw NextPageParseError('unknown endpoint: $path');
    }
    final allowedParams = kNextPageEndpoints[path]!;
    for (final name in query.keys) {
      if (!allowedParams.contains(name)) {
        throw NextPageParseError('unknown query parameter "$name" for $path');
      }
    }
    return NextPageRequest(uri: Uri(path: path, queryParameters: query));
  }
}
