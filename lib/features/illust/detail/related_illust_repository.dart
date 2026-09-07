import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/next_page_parser.dart';
import '../../../core/network/pixiv_client_identity.dart';
import '../../../core/network/pixiv_http_client.dart';
import '../../../core/paging/paged_feed_controller.dart';

/// One page of related illustrations.
class RelatedIllustPage {
  const RelatedIllustPage({required this.illusts, required this.nextUrl});

  final List<IllustEntity> illusts;
  final String? nextUrl;
}

/// Data source for the detail-page "関連作品" section:
/// `GET /v1/illust/related?illust_id=` (app-api).
///
/// Mirrors the official Pixiv client behaviour: a paginated list of
/// illustrations related to the currently viewed work, rendered below the
/// caption/tags, each tile opening its own detail page.
class PixivRelatedIllustRepository {
  PixivRelatedIllustRepository(this._client);

  static const _path = '/v2/illust/related';

  final PixivHttpClient _client;

  Future<RelatedIllustPage> fetchPage(
    int illustId, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final NextPageRequest request;
    try {
      request = cursor == null
          ? NextPageParser.firstPage(_path, {
              'illust_id': '$illustId',
              'filter': 'for_android',
            })
          : NextPageParser.parse(cursor)!;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
    // Relative next_page requests bind to the verified API base; absolute
    // (already validated) requests pass through unchanged. Without this the
    // policy layer rejects the host-less destination with
    // PixivDestinationException.
    final target = request.uri.hasScheme
        ? request.uri
        : PixivClientIdentity.appApiBase.replace(
            path: request.uri.path,
            query: request.uri.query,
          );
    final json = await _client.getJson(target, cancelToken: cancelToken);
    final rawIllusts = json['illusts'];
    if (rawIllusts is! List) {
      throw const ApiParseError('related illusts envelope is malformed');
    }
    final illusts = <IllustEntity>[];
    for (final raw in rawIllusts) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        illusts.add(IllustEntity.fromJson(raw));
      } on Object {
        // One malformed entry must not fail the whole related section
        // (the official client shows what it can parse).
      }
    }
    final nextUrl = json['next_url'];
    return RelatedIllustPage(illusts: illusts, nextUrl: nextUrl as String?);
  }
}

/// Paginated related-illustrations state, one per source work.
///
/// Uses the same PagedFeedController machinery as the feed pages: the ids
/// live in this controller, the payloads merge into the shared illust store
/// through the generation commit.
class RelatedIllustController extends PagedFeedController {
  RelatedIllustController(this.illustId);

  final int illustId;

  @override
  String get feedKey => 'related:$illustId';

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await ref
        .read(relatedIllustRepositoryProvider)
        .fetchPage(illustId, cursor: context.cursor, cancelToken: context.cancelToken);
    return FeedPage(
      ids: [for (final illust in page.illusts) illust.id],
      nextCursor: page.nextUrl,
      incomingIllusts: {for (final illust in page.illusts) illust.id: illust},
      commit: (_) => store.mergeAll(
        page.illusts,
        bookmarkSnapshotRevision: bookmarkRevision,
      ),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    try {
      NextPageParser.parse(rawCursor);
      return rawCursor;
    } on NextPageParseError {
      return null;
    }
  }
}

final relatedIllustControllerProvider = AsyncNotifierProvider.family<
  RelatedIllustController,
  PagedFeedState,
  int
>(RelatedIllustController.new);

/// Overridable in tests; the default wired through the shared client.
final relatedIllustRepositoryProvider = Provider<PixivRelatedIllustRepository>(
  (ref) => PixivRelatedIllustRepository(ref.watch(pixivHttpClientProvider)),
);
