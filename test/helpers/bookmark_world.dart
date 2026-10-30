import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';

import 'api_responses.dart';
import 'fake_account.dart';

/// The App API's bookmark endpoints: records adds and deletes from the
/// wire and answers [detail] and [tagPage].
class BookmarkApi {
  final List<(int id, String restrict, List<String>? tags)> adds = [];
  final List<int> deletes = [];

  /// Answers adds instead of success.
  ApiRoute? addFailure;

  /// When set, add answers wait on it — a still-in-flight add.
  Completer<void>? addGate;
  BookmarkDetail detail = const BookmarkDetail(
    isBookmarked: false,
    restrict: BookmarkRestrict.public,
    tags: [],
  );

  /// When set, detail answers wait on it — a still-in-flight detail load.
  Completer<void>? detailGate;
  ApiRoute? detailFailure;
  UserBookmarkTagPage tagPage = const UserBookmarkTagPage(
    tags: [],
    nextUrl: null,
  );

  /// Tag list reads from the wire: `tags:<user>:<restrict>`, `:next` for a
  /// later page, which [tagsNextFailure] answers when set.
  final tagRequests = <String>[];
  ApiRoute? tagsNextFailure;

  Future<http.Response> _add(http.Request request, String idField) async {
    final fields = requestFields(request);
    adds.add((
      int.parse(fields[idField]!),
      fields['restrict']!,
      fields['tags[]']?.split(' '),
    ));
    await addGate?.future;
    if (addFailure case final fail?) return fail(request);
    return jsonResponse(const <String, Object?>{});
  }

  ApiRoute _delete(String idField) => (request) {
    deletes.add(int.parse(requestFields(request)[idField]!));
    return jsonResponse(const <String, Object?>{});
  };

  Future<http.Response> _detail(http.Request request) async {
    await detailGate?.future;
    if (detailFailure case final fail?) return fail(request);
    return jsonResponse({
      'bookmark_detail': {
        'is_bookmarked': detail.isBookmarked,
        'restrict': ?detail.restrict?.name,
        'tags': [
          for (final tag in detail.tags)
            {'name': tag.name, 'is_registered': tag.isRegistered},
        ],
      },
    });
  }

  Future<http.Response> _tags(http.Request request) async {
    final query = request.url.queryParameters;
    final next = query.containsKey('offset');
    tagRequests.add(
      'tags:${query['user_id']}:${query['restrict']}${next ? ':next' : ''}',
    );
    if (tagsNextFailure case final fail? when next) return fail(request);
    return jsonResponse({
      'bookmark_tags': [
        for (final tag in tagPage.tags) {'name': tag.name, 'count': tag.count},
      ],
      'next_url': tagPage.nextUrl,
    });
  }

  Map<String, ApiRoute> get routes => {
    '/v2/illust/bookmark/add': (request) => _add(request, 'illust_id'),
    '/v2/novel/bookmark/add': (request) => _add(request, 'novel_id'),
    '/v1/illust/bookmark/delete': _delete('illust_id'),
    '/v1/novel/bookmark/delete': _delete('novel_id'),
    '/v2/illust/bookmark/detail': _detail,
    '/v2/novel/bookmark/detail': _detail,
    '/v1/user/bookmark-tags/illust': _tags,
    '/v1/user/bookmark-tags/novel': _tags,
  };
}

/// Signed in as [testerAccount] (and [others]) over [PixivApi] with
/// [bookmarks]' routes and [routes].
Future<ProviderContainer> bookmarkWorld(
  BookmarkApi bookmarks, {
  List<Account> others = const [],
  Map<String, ApiRoute> routes = const {},
}) => signedInApiContainer(
  PixivApi({...backgroundRoutes, ...bookmarks.routes, ...routes}).client,
  others: others,
);
