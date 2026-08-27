import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/next_page_parser.dart';
import '../../../core/network/pixiv_client_identity.dart';
import '../../../core/network/pixiv_http_client.dart';
import '../../../core/paging/paged_feed_controller.dart';

class RecommendedIllustPage {
  const RecommendedIllustPage({required this.illusts, required this.nextUrl});

  final List<IllustEntity> illusts;
  final String? nextUrl;
}

/// Fetches and normalizes Recommended Illust pages.
///
/// Entity writes belong to the feed controller's generation commit, not this
/// repository, so a late response cannot mutate shared state before the gate
/// checks its context.
class RecommendedIllustRepository {
  RecommendedIllustRepository(this._client);

  final PixivHttpClient _client;

  /// Fetches one page. [cursor] is the validated next_url or `null` for the
  /// first page.
  Future<RecommendedIllustPage> fetchPage(
    String? cursor, {
    CancelToken? cancelToken,
  }) async {
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
      final json = await _client.getJson(target, cancelToken: cancelToken);
      final page = IllustEntity.parsePage(json);
      return RecommendedIllustPage(
        illusts: page.illusts,
        nextUrl: page.nextUrl,
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }
}

final recommendedIllustRepositoryProvider =
    Provider<RecommendedIllustRepository>((ref) {
      return RecommendedIllustRepository(ref.watch(pixivHttpClientProvider));
    });

/// Controller for the Recommended Illust tab.
class RecommendedIllustController extends PagedFeedController {
  @override
  String get feedKey => 'recommended:illust';

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(
    String? cursor,
  ) async {
    final page = await ref
        .read(recommendedIllustRepositoryProvider)
        .fetchPage(cursor);
    return (
      ids: [for (final illust in page.illusts) illust.id],
      nextCursor: page.nextUrl,
    );
  }

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await ref
        .read(recommendedIllustRepositoryProvider)
        .fetchPage(context.cursor, cancelToken: context.cancelToken);
    return FeedPage(
      ids: [for (final illust in page.illusts) illust.id],
      nextCursor: page.nextUrl,
      commit: (_) => store.mergeAll(
        page.illusts,
        bookmarkSnapshotRevision: bookmarkRevision,
      ),
    );
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
