import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import '../novel/novel_entity.dart';
import '../user/user_entity.dart';
import 'search_models.dart';

class SearchIllustPage {
  const SearchIllustPage({required this.illusts, required this.nextUrl});

  final List<IllustEntity> illusts;
  final String? nextUrl;
}

class SearchNovelPage {
  const SearchNovelPage({required this.novels, required this.nextUrl});

  final List<NovelEntity> novels;
  final String? nextUrl;
}

class SearchUserPage {
  const SearchUserPage({required this.users, required this.nextUrl});

  final List<UserEntity> users;
  final String? nextUrl;
}

@immutable
class SearchSuggestion {
  const SearchSuggestion({required this.keyword, this.translatedName});

  final String keyword;
  final String? translatedName;

  String get displayName => translatedName ?? keyword;
}

@immutable
class TrendingTag {
  const TrendingTag({
    required this.name,
    this.translatedName,
    this.representative,
  });

  final String name;
  final String? translatedName;
  final IllustEntity? representative;

  String get displayName => translatedName ?? name;
}

abstract interface class SearchRepository {
  Future<SearchIllustPage> searchIllust(
    IllustSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  });

  Future<SearchNovelPage> searchNovel(
    NovelSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  });

  Future<SearchUserPage> searchUsers(
    UserSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateCursor(SearchQuery query, {required String cursor});

  Future<List<SearchSuggestion>> autocomplete(
    String keyword, {
    CancelToken? cancelToken,
  });

  Future<List<TrendingTag>> trendingTags({CancelToken? cancelToken});
}

/// JSON-only Search API adapter. All raw response shapes are normalized here;
/// result pages only receive typed entities and a validated next URL.
class PixivSearchRepository implements SearchRepository {
  PixivSearchRepository(this._client);

  final PixivHttpClient _client;

  @override
  Future<SearchIllustPage> searchIllust(
    IllustSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _pageRequest(query, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseIllustPage(json);
  }

  @override
  Future<SearchNovelPage> searchNovel(
    NovelSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _pageRequest(query, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseNovelPage(json);
  }

  @override
  Future<SearchUserPage> searchUsers(
    UserSearchQuery query, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _pageRequest(query, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    return _parseUserPage(json);
  }

  @override
  bool validateCursor(SearchQuery query, {required String cursor}) {
    try {
      _pageRequest(query, cursor: cursor);
      return true;
    } on ApiParseError {
      return false;
    }
  }

  @override
  Future<List<SearchSuggestion>> autocomplete(
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    final normalized = keyword.trim();
    if (normalized.isEmpty) return const [];
    final json = await _client.getJson(
      PixivClientIdentity.appApiBase.replace(
        path: '/v1/search/autocomplete',
        queryParameters: {'word': normalized, 'filter': 'for_android'},
      ),
      cancelToken: cancelToken,
    );
    try {
      final raw = json['search_auto_complete_keywords'] ?? json['tags'];
      if (raw is! List) {
        throw const FormatException(
          'autocomplete keywords are missing or malformed',
        );
      }
      return [for (final item in raw) _parseSuggestion(item)];
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  @override
  Future<List<TrendingTag>> trendingTags({CancelToken? cancelToken}) async {
    final json = await _client.getJson(
      PixivClientIdentity.appApiBase.replace(
        path: '/v1/trending-tags/illust',
        queryParameters: {'filter': 'for_android'},
      ),
      cancelToken: cancelToken,
    );
    try {
      final raw = json['trend_tags'];
      if (raw is! List) {
        throw const FormatException('trend_tags is missing or malformed');
      }
      return [for (final item in raw) _parseTrendingTag(item)];
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  NextPageRequest _pageRequest(SearchQuery query, {required String? cursor}) {
    final spec = _spec(query);
    try {
      final request = cursor == null
          ? NextPageParser.firstPage(spec.path, query.toQuery())
          : NextPageParser.parse(cursor);
      if (request == null) {
        throw const NextPageParseError('missing next page request');
      }
      if (request.uri.path != spec.path) {
        throw NextPageParseError(
          'next_url endpoint does not match ${spec.path}: ${request.uri.path}',
        );
      }
      for (final entry in spec.requiredQuery.entries) {
        if (request.query[entry.key] != entry.value) {
          throw NextPageParseError(
            'next_url ${entry.key} does not match the active search',
          );
        }
      }
      return request;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  ({String path, Map<String, String> requiredQuery}) _spec(SearchQuery query) {
    return switch (query) {
      IllustSearchQuery() => (
        path: '/v1/search/illust',
        requiredQuery: query.toQuery(),
      ),
      NovelSearchQuery() => (
        path: '/v1/search/novel',
        requiredQuery: query.toQuery(),
      ),
      UserSearchQuery() => (
        path: '/v1/search/user',
        requiredQuery: query.toQuery(),
      ),
    };
  }

  SearchIllustPage _parseIllustPage(Map<String, dynamic> json) {
    try {
      final page = IllustEntity.parsePage(json);
      return SearchIllustPage(illusts: page.illusts, nextUrl: page.nextUrl);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  SearchNovelPage _parseNovelPage(Map<String, dynamic> json) {
    try {
      final raw = json['novels'];
      if (raw is! List) {
        throw const FormatException('novels list is missing or malformed');
      }
      return SearchNovelPage(
        novels: [
          for (final item in raw)
            if (item is Map<String, dynamic>)
              NovelEntity.fromJson(item)
            else
              throw const FormatException('novels contains a non-object'),
        ],
        nextUrl: _nextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  SearchUserPage _parseUserPage(Map<String, dynamic> json) {
    try {
      final raw = json['user_previews'];
      if (raw is! List) {
        throw const FormatException(
          'user_previews list is missing or malformed',
        );
      }
      return SearchUserPage(
        users: [
          for (final item in raw)
            if (item is Map<String, dynamic>)
              UserEntity.fromPreviewJson(item)
            else
              throw const FormatException(
                'user_previews contains a non-object',
              ),
        ],
        nextUrl: _nextUrl(json['next_url']),
      );
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  SearchSuggestion _parseSuggestion(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return SearchSuggestion(keyword: value.trim());
    }
    if (value is Map<String, dynamic>) {
      final keyword = _firstString(value, const ['word', 'tag', 'name']);
      if (keyword != null) {
        return SearchSuggestion(
          keyword: keyword,
          translatedName: _firstString(value, const [
            'translated_name',
            'translatedName',
          ]),
        );
      }
    }
    throw const FormatException('autocomplete item is malformed');
  }

  TrendingTag _parseTrendingTag(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('trend tag is not an object');
    }
    final name = _firstString(value, const ['tag', 'name']);
    if (name == null) throw const FormatException('trend tag name is missing');
    final translated = _firstString(value, const [
      'translated_name',
      'translatedName',
    ]);
    IllustEntity? representative;
    final rawIllust = value['illust'];
    if (rawIllust is Map<String, dynamic>) {
      try {
        representative = IllustEntity.fromJson(rawIllust);
      } on FormatException {
        // The tag itself remains useful, but long-press stays visibly
        // unavailable instead of opening a made-up representative work.
      }
    }
    return TrendingTag(
      name: name,
      translatedName: translated,
      representative: representative,
    );
  }

  Uri _target(NextPageRequest request) => request.uri.hasScheme
      ? request.uri
      : PixivClientIdentity.appApiBase.replace(
          path: request.uri.path,
          query: request.uri.query,
        );

  static String? _nextUrl(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

String? _firstString(Map<String, dynamic> value, List<String> keys) {
  for (final key in keys) {
    final item = value[key];
    if (item is String && item.trim().isNotEmpty) return item.trim();
  }
  return null;
}

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return PixivSearchRepository(ref.watch(pixivHttpClientProvider));
});
