import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/next_page_parser.dart';
import '../../../core/network/pixiv_http_client.dart';
import '../../../core/paging/paged_feed_controller.dart';

/// Minimal real tag-results feed (detail R5), designed for reuse by the
/// Search task: `/v1/search/illust?search_target=partial_match_for_tags`.
class TagSearchController extends PagedFeedController {
  TagSearchController(this.tag);

  final String tag;

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(
    String? cursor,
  ) async {
    final client = ref.watch(pixivHttpClientProvider);
    final NextPageRequest request;
    try {
      request = cursor == null
          ? NextPageParser.firstPage('/v1/search/illust', {
              'search_target': 'partial_match_for_tags',
              'word': tag,
              'sort': 'date_desc',
              'filter': 'for_ios',
            })
          : NextPageParser.parse(cursor)!;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
    final target = request.uri.hasScheme
        ? request.uri
        : Uri(
            scheme: 'https',
            host: 'app-api.pixiv.net',
            path: request.uri.path,
            query: request.uri.query,
          );
    try {
      final bookmarkRevision = ref
          .read(illustStoreProvider)
          .bookmarkRevisionNow();
      final json = await client.getJson(target);
      final page = IllustEntity.parsePage(json);
      ref
          .read(illustStoreProvider)
          .mergeAll(page.illusts, bookmarkSnapshotRevision: bookmarkRevision);
      return (
        ids: [for (final illust in page.illusts) illust.id],
        nextCursor: page.nextUrl,
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }
}

final tagSearchControllerProvider =
    AsyncNotifierProvider.family<TagSearchController, PagedFeedState, String>(
      TagSearchController.new,
    );
