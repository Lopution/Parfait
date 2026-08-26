import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/next_page_parser.dart';
import '../../../core/network/pixiv_client_identity.dart';
import '../../../core/network/pixiv_http_client.dart';
import '../../../core/paging/paged_feed_controller.dart';

/// Fetches Recommended Illust pages and merges entities into [IllustStore].
class RecommendedIllustRepository {
  RecommendedIllustRepository(this._client, this._store);

  final PixivHttpClient _client;
  final IllustStore _store;

  /// Fetches one page. [cursor] is the validated next_url or `null` for the
  /// first page.
  Future<({List<int> ids, String? nextUrl})> fetchPage(String? cursor) async {
    final NextPageRequest request;
    try {
      request = cursor == null
          ? NextPageParser.firstPage('/v1/illust/recommended', {
              'content_type': 'illust',
              'include_ranking_illusts': 'true',
              'filter': 'for_ios',
            })
          : NextPageParser.parse(cursor)!;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
    // Relative next_page requests bind to the verified API base; absolute
    // (already validated) requests pass through unchanged.
    final target = request.uri.hasScheme
        ? request.uri
        : PixivClientIdentity.appApiBase.replace(
            path: request.uri.path,
            query: request.uri.query,
          );
    try {
      final json = await _client.getJson(target);
      final page = IllustEntity.parsePage(json);
      _store.mergeAll(page.illusts);
      return (ids: page.illusts.map((e) => e.id).toList(), nextUrl: page.nextUrl);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }
}

final recommendedIllustRepositoryProvider =
    Provider<RecommendedIllustRepository>((ref) {
  return RecommendedIllustRepository(
    ref.watch(pixivHttpClientProvider),
    ref.watch(illustStoreProvider),
  );
});

/// Controller for the Recommended Illust tab.
class RecommendedIllustController extends PagedFeedController {
  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(String? cursor) {
    return ref
        .read(recommendedIllustRepositoryProvider)
        .fetchPage(cursor)
        .then((page) => (ids: page.ids, nextCursor: page.nextUrl));
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    // Reject early via the allowlist; store the validated request URI.
    try {
      NextPageParser.parse(rawCursor);
      return rawCursor;
    } on NextPageParseError {
      return null;
    }
  }
}

final recommendedIllustControllerProvider =
    AsyncNotifierProvider<RecommendedIllustController, PagedFeedState>(
  RecommendedIllustController.new,
);
