import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/user/user_entity.dart';

import 'fake_account.dart' show jsonResponse;

/// How the App API answers one request.
typedef ApiRoute = FutureOr<http.Response> Function(http.Request request);

/// The pixiv App API at the transport, for [signedInApiContainer]: each
/// request is answered by the route for its path and recorded. A path with
/// no route, or a method its path does not take ([appApiTakes]), is
/// answered 404 or 405 and fails the test when it ends.
class PixivApi {
  PixivApi([Map<String, ApiRoute> routes = const {}]) : routes = {...routes} {
    addTearDown(
      () => expect(unrouted, isEmpty, reason: 'App API requests with no route'),
    );
  }

  final Map<String, ApiRoute> routes;
  final requests = <http.Request>[];
  final unrouted = <String>[];

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    final route = routes[request.url.path];
    if (route == null || !appApiTakes(request.method, request.url.path)) {
      unrouted.add('${request.method} ${request.url}');
      return http.Response('no route', route == null ? 404 : 405);
    }
    return route(request);
  });

  /// Requests to [path] whose query or form fields include [fields].
  List<http.Request> sent(
    String path, [
    Map<String, String> fields = const {},
  ]) => [
    for (final request in requests)
      if (request.url.path == path &&
          fields.entries.every(
            (field) => requestFields(request)[field.key] == field.value,
          ))
        request,
  ];
}

/// The App API paths the app writes to, by POST. Every other path is read
/// by GET; the restricted-mode setting is read and written on one path.
const _appApiWrites = {
  '/v2/illust/bookmark/add',
  '/v1/illust/bookmark/delete',
  '/v2/novel/bookmark/add',
  '/v1/novel/bookmark/delete',
  '/v1/user/follow/add',
  '/v1/user/follow/delete',
  '/v1/watchlist/manga/add',
  '/v1/watchlist/manga/delete',
  '/v1/watchlist/novel/add',
  '/v1/watchlist/novel/delete',
  '/v1/illust/comment/add',
  '/v1/illust/comment/delete',
  '/v1/novel/comment/add',
  '/v1/novel/comment/delete',
  '/v1/mute/edit',
  '/v1/user/ai-show-settings/edit',
  '/v1/user/restricted-mode-settings',
  '/v2/user/browsing-history/illust/add',
  '/v1/user/profile/edit',
};
const _appApiReadWrites = {'/v1/user/restricted-mode-settings'};

/// Whether the App API takes [method] on [path], as the server does: a
/// write sent as a read, or a read as a write, is refused.
bool appApiTakes(String method, String path) => switch (method) {
  'POST' => _appApiWrites.contains(path),
  'GET' => !_appApiWrites.contains(path) || _appApiReadWrites.contains(path),
  _ => false,
};

/// A request's query parameters and, for a form post, its fields.
Map<String, String> requestFields(http.Request request) => {
  ...request.url.queryParameters,
  if (request.method == 'POST' && request.body.isNotEmpty)
    ...Uri.splitQueryString(request.body),
};

/// A 200 JSON answer of [body].
ApiRoute answer(Object? body) =>
    (_) => jsonResponse(body);

/// The App API's error answer with HTTP [status]. A queued action replays
/// a 5xx later; a 4xx fails it where the user sees it.
ApiRoute failing(int status) =>
    (_) => jsonResponse({
      'error': {'user_message': '', 'message': 'status $status', 'reason': ''},
    }, status);

/// A transport failure: nothing reached the server.
Never offline(http.Request request) => throw http.ClientException('offline');

/// What signed-in pages read in the background: an empty mute list.
final Map<String, ApiRoute> backgroundRoutes = {
  '/v1/mute/list': answer(const {
    'muted_tags': <Object?>[],
    'muted_users': <Object?>[],
    'mute_limit_count': 500,
  }),
};

/// What the app shell's preloaded branches read: empty home feeds, no
/// Spotlight articles and no trending tags.
final Map<String, ApiRoute> shellRoutes = {
  for (final path in [
    '/v1/illust/recommended',
    '/v2/illust/follow',
    '/v1/illust/ranking',
  ])
    path: answer(pageJson('illusts', const [])),
  '/v1/spotlight/articles': answer(pageJson('spotlight_articles', const [])),
  '/v1/trending-tags/illust': answer(const {'trend_tags': <Object?>[]}),
};

/// A page of [key] items (`illusts`, `user_previews`, ...) with no next.
Map<String, dynamic> pageJson(String key, List<Object?> items) => {
  key: items,
  'next_url': null,
};

/// [request]'s page at [offset], as pixiv's `next_url` echoes it.
String nextUrl(http.Request request, int offset) => request.url
    .replace(
      queryParameters: {...request.url.queryParameters, 'offset': '$offset'},
    )
    .toString();

/// [user] as the App API's `user` object.
Map<String, dynamic> userJson(UserEntity user) => {
  'id': user.id,
  'name': user.name,
  'account': user.account,
  'profile_image_urls': {'medium': ?user.profileImageUrl},
  'comment': ?user.comment,
  'is_followed': ?user.isFollowed,
  'is_premium': ?user.isPremium,
  if (!user.visible) 'is_access_blocking_user': true,
};

/// [user] as a `user_previews` item.
Map<String, dynamic> userPreviewJson(UserEntity user) => {
  'user': userJson(user),
  'illusts': const <Object?>[],
  'novels': const <Object?>[],
  'is_muted': user.isMuted,
};

/// [user] as the `/v1/user/detail` envelope.
Map<String, dynamic> userDetailJson(UserEntity user) => {
  'user': userJson(user),
  'profile': {
    'webpage': user.webpage,
    'twitter_url': user.twitterUrl,
    'pawoo_url': user.pawooUrl,
    'background_image_url': user.backgroundImageUrl,
    'total_follow_users': user.totalFollowUsers,
    'total_mypixiv_users': user.totalMyPixivUsers,
    'total_illusts': user.totalIllusts,
    'total_manga': user.totalManga,
    'total_novels': user.totalNovels,
    'total_illust_bookmarks_public': user.totalIllustBookmarksPublic,
    'total_illust_series': user.totalIllustSeries,
    'total_novel_series': user.totalNovelSeries,
  },
};
