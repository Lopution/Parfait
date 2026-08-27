import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_entity.dart';
import '../network/api_error.dart';
import '../network/next_page_parser.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import '../novel/novel_entity.dart';
import 'new_feed_models.dart';

class NewIllustPage {
  const NewIllustPage({required this.illusts, required this.nextUrl});

  final List<IllustEntity> illusts;
  final String? nextUrl;
}

class NewNovelPage {
  const NewNovelPage({required this.novels, required this.nextUrl});

  final List<NovelEntity> novels;
  final String? nextUrl;
}

abstract interface class NewFeedRepository {
  Future<NewIllustPage> fetchIllust(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  });

  Future<NewNovelPage> fetchNovel(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  });

  bool validateIllustCursor(NewFeedKey key, {required String cursor});

  bool validateNovelCursor(NewFeedKey key, {required String cursor});
}

/// JSON adapters for the New sources. The endpoint/query mapping is typed and
/// explicit so each scope remains observable when Pixiv disables a source.
class PixivNewFeedRepository implements NewFeedRepository {
  PixivNewFeedRepository(this._client);

  final PixivHttpClient _client;

  @override
  Future<NewIllustPage> fetchIllust(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _request(key, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    try {
      final page = IllustEntity.parsePage(json);
      return NewIllustPage(illusts: page.illusts, nextUrl: page.nextUrl);
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  @override
  Future<NewNovelPage> fetchNovel(
    NewFeedKey key, {
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    final request = _request(key, cursor: cursor);
    final json = await _client.getJson(
      _target(request),
      cancelToken: cancelToken,
    );
    try {
      final raw = json['novels'];
      if (raw is! List) {
        throw const FormatException('novels list is missing or malformed');
      }
      return NewNovelPage(
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

  @override
  bool validateIllustCursor(NewFeedKey key, {required String cursor}) =>
      _validate(key, cursor: cursor, expectedType: NewFeedType.illust);

  @override
  bool validateNovelCursor(NewFeedKey key, {required String cursor}) =>
      _validate(key, cursor: cursor, expectedType: NewFeedType.novel);

  NextPageRequest _request(NewFeedKey key, {required String? cursor}) {
    final spec = _spec(key);
    try {
      final request = cursor == null
          ? NextPageParser.firstPage(spec.path, spec.query)
          : NextPageParser.parse(cursor);
      if (request == null) {
        throw const NextPageParseError('missing next page request');
      }
      if (request.uri.path != spec.path) {
        throw NextPageParseError(
          'next_url endpoint does not match ${spec.path}: ${request.uri.path}',
        );
      }
      for (final entry in spec.query.entries) {
        if (request.query[entry.key] != entry.value) {
          throw NextPageParseError(
            'next_url ${entry.key} does not match ${key.toString()}',
          );
        }
      }
      return request;
    } on NextPageParseError catch (error) {
      throw ApiParseError(error);
    }
  }

  bool _validate(
    NewFeedKey key, {
    required String cursor,
    required NewFeedType expectedType,
  }) {
    if (key.type != expectedType) return false;
    try {
      _request(key, cursor: cursor);
      return true;
    } on ApiParseError {
      return false;
    }
  }

  ({String path, Map<String, String> query}) _spec(NewFeedKey key) {
    if (key.type == NewFeedType.illust) {
      return switch (key.scope) {
        NewFeedScope.following => (
          path: '/v2/illust/follow',
          query: {'filter': 'for_android', 'restrict': 'all'},
        ),
        NewFeedScope.everyone => (
          path: '/v1/illust/new',
          query: {'filter': 'for_android', 'content_type': 'illust'},
        ),
        NewFeedScope.myPixiv => (
          path: '/v2/illust/mypixiv',
          query: {'filter': 'for_android'},
        ),
      };
    }
    return switch (key.scope) {
      NewFeedScope.following => (
        path: '/v1/novel/follow',
        query: {'filter': 'for_android', 'restrict': 'all'},
      ),
      NewFeedScope.everyone => (
        path: '/v1/novel/new',
        // This endpoint is used without query parameters by the existing
        // client; keep that contract instead of inventing a filter.
        query: const {},
      ),
      NewFeedScope.myPixiv => (
        path: '/v1/novel/mypixiv',
        query: {'filter': 'for_android'},
      ),
    };
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

final newFeedRepositoryProvider = Provider<NewFeedRepository>((ref) {
  return PixivNewFeedRepository(ref.watch(pixivHttpClientProvider));
});
