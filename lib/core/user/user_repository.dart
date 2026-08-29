import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'user_entity.dart';

enum UserWorkType { illust, manga, novel }

String userWorkTypeWire(UserWorkType type) {
  switch (type) {
    case UserWorkType.illust:
      return 'illust';
    case UserWorkType.manga:
      return 'manga';
    case UserWorkType.novel:
      return 'novel';
  }
}

enum UserRelation { following, fans, myPixiv }

class UserRelationPage {
  const UserRelationPage({required this.users, required this.nextUrl});

  final List<UserEntity> users;
  final String? nextUrl;
}

class UserIllustPage {
  const UserIllustPage({required this.illusts, required this.nextUrl});

  final List<IllustEntity> illusts;
  final String? nextUrl;
}

abstract interface class UserRepository {
  Future<UserEntity> fetchDetail(int userId, {CancelToken? cancelToken});

  /// Recommended users (`/v1/user/recommended`), paged via `next_url`.
  Future<UserRelationPage> fetchRecommended({
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateRecommendedCursor({required String cursor});


  Future<UserIllustPage> fetchWorks(
    int userId, {
    required UserWorkType type,
    String? cursor,
    CancelToken? cancelToken,
  });

  Future<UserIllustPage> fetchBookmarks(
    int userId, {
    required UserRestrict restrict,
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateWorksCursor(
    int userId, {
    required UserWorkType type,
    required String cursor,
  });

  bool validateBookmarksCursor(
    int userId, {
    required UserRestrict restrict,
    required String cursor,
  });

  Future<UserRelationPage> fetchRelation(
    int userId, {
    required UserRelation relation,
    UserRestrict restrict = UserRestrict.public,
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateRelationCursor(
    int userId, {
    required UserRelation relation,
    required UserRestrict restrict,
    required String cursor,
  });
}

/// Read-only user/profile API boundary. It owns response normalization and
/// next-page validation; controllers only receive typed pages.
class PixivUserRepository implements UserRepository {
  PixivUserRepository(this._client);

  final PixivHttpClient _client;

  static const _detailPath = '/v1/user/detail';

  @override
  Future<UserEntity> fetchDetail(int userId, {CancelToken? cancelToken}) async {
    try {
      final json = await _client.getJson(
        PixivClientIdentity.appApiBase.replace(
          path: _detailPath,
          queryParameters: {'filter': 'for_android', 'user_id': '$userId'},
        ),
        cancelToken: cancelToken,
      );
      return UserEntity.fromDetailJson(json);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  @override
  Future<UserRelationPage> fetchRecommended({
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _pageRequest(
      path: '/v1/user/recommended',
      query: {'filter': 'for_ios'},
      cursor: cursor,
    );
    final json = await _client.getJson(_target(request), cancelToken: cancelToken);
    return _parseUserPage(json);
  }

  @override
  bool validateRecommendedCursor({required String cursor}) {
    return _validCursor(
      path: '/v1/user/recommended',
      query: {'filter': 'for_ios'},
      cursor: cursor,
    );
  }


  @override
  Future<UserIllustPage> fetchWorks(
    int userId, {
    required UserWorkType type,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    if (type == UserWorkType.novel) {
      throw const ApiParseError(
        'novel profile feeds are provided by the novel-reader task',
      );
    }
    final path = '/v1/user/illusts';
    final query = {
      'filter': 'for_android',
      'user_id': '$userId',
      'type': userWorkTypeWire(type),
    };
    final request = _pageRequest(path: path, query: query, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseIllustPage(json);
  }

  @override
  Future<UserIllustPage> fetchBookmarks(
    int userId, {
    required UserRestrict restrict,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final path = '/v1/user/bookmarks/illust';
    final query = {'user_id': '$userId', 'restrict': restrict.wireValue};
    final request = _pageRequest(path: path, query: query, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseIllustPage(json);
  }

  @override
  bool validateWorksCursor(
    int userId, {
    required UserWorkType type,
    required String cursor,
  }) {
    if (type == UserWorkType.novel) return false;
    return _validCursor(
      path: '/v1/user/illusts',
      query: {
        'filter': 'for_android',
        'user_id': '$userId',
        'type': userWorkTypeWire(type),
      },
      cursor: cursor,
    );
  }

  @override
  bool validateBookmarksCursor(
    int userId, {
    required UserRestrict restrict,
    required String cursor,
  }) {
    return _validCursor(
      path: '/v1/user/bookmarks/illust',
      query: {'user_id': '$userId', 'restrict': restrict.wireValue},
      cursor: cursor,
    );
  }

  @override
  Future<UserRelationPage> fetchRelation(
    int userId, {
    required UserRelation relation,
    UserRestrict restrict = UserRestrict.public,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final path = switch (relation) {
      UserRelation.following => '/v1/user/following',
      UserRelation.fans => '/v1/user/follower',
      UserRelation.myPixiv => '/v1/user/mypixiv',
    };
    final query = <String, String>{
      'filter': 'for_android',
      'user_id': '$userId',
      if (relation == UserRelation.following) 'restrict': restrict.wireValue,
    };
    final request = _pageRequest(path: path, query: query, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseUserPage(json);
  }

  @override
  bool validateRelationCursor(
    int userId, {
    required UserRelation relation,
    required UserRestrict restrict,
    required String cursor,
  }) {
    final path = switch (relation) {
      UserRelation.following => '/v1/user/following',
      UserRelation.fans => '/v1/user/follower',
      UserRelation.myPixiv => '/v1/user/mypixiv',
    };
    return _validCursor(
      path: path,
      query: {
        'filter': 'for_android',
        'user_id': '$userId',
        if (relation == UserRelation.following) 'restrict': restrict.wireValue,
      },
      cursor: cursor,
    );
  }

  NextPageRequest _pageRequest({
    required String path,
    required Map<String, String> query,
    required String? cursor,
  }) {
    try {
      final request = cursor == null
          ? NextPageParser.firstPage(path, query)
          : NextPageParser.parse(cursor);
      if (request == null) {
        throw const NextPageParseError('missing next page request');
      }
      _validateCursor(request, path, query);
      return request;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
  }

  bool _validCursor({
    required String path,
    required Map<String, String> query,
    required String cursor,
  }) {
    try {
      _pageRequest(path: path, query: query, cursor: cursor);
      return true;
    } on ApiParseError {
      return false;
    }
  }

  void _validateCursor(
    NextPageRequest request,
    String path,
    Map<String, String> expected,
  ) {
    if (request.uri.path != path) {
      throw NextPageParseError(
        'next_url endpoint does not match $path: ${request.uri.path}',
      );
    }
    for (final entry in expected.entries) {
      if (request.query[entry.key] != entry.value) {
        throw NextPageParseError(
          'next_url ${entry.key} does not match the active profile feed',
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

  UserIllustPage _parseIllustPage(Map<String, dynamic> json) {
    try {
      final page = IllustEntity.parsePage(json);
      return UserIllustPage(illusts: page.illusts, nextUrl: page.nextUrl);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  UserRelationPage _parseUserPage(Map<String, dynamic> json) {
    final raw = json['user_previews'];
    if (raw is! List) {
      throw const ApiParseError('user_previews is missing or malformed');
    }
    try {
      final users = <UserEntity>[];
      for (final item in raw) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('user_previews contains a non-object');
        }
        users.add(UserEntity.fromPreviewJson(item));
      }
      return UserRelationPage(
        users: users,
        nextUrl: _nextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  String? _nextUrl(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

enum UserRestrict { public, private }

extension UserRestrictWire on UserRestrict {
  String get wireValue => this == UserRestrict.private ? 'private' : 'public';
}

final userRepositoryProvider = Provider<UserRepository>((ref) {
  return PixivUserRepository(ref.watch(pixivHttpClientProvider));
});
