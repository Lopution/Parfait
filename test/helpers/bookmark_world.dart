import 'dart:async';

import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_repository.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';

/// Records bookmark writes and serves scripted detail and tag pages.
class RecordingBookmarkRepository implements BookmarkRepository {
  final List<(int id, String restrict, List<String>? tags)> adds = [];
  final List<int> deletes = [];
  Object? addError;
  BookmarkDetail detail = const BookmarkDetail(
    isBookmarked: false,
    restrict: BookmarkRestrict.public,
    tags: [],
  );

  /// When set, `fetchDetail` waits on it — a still-in-flight detail load.
  Completer<BookmarkDetail>? detailGate;
  Object? detailError;
  UserBookmarkTagPage tagPage = const UserBookmarkTagPage(
    tags: [],
    nextUrl: null,
  );

  @override
  Future<void> addIllust(
    int id,
    BookmarkRestrict restrict, {
    List<String>? tags,
    CancelToken? cancelToken,
  }) async {
    final error = addError;
    if (error != null) throw error;
    adds.add((id, restrict.name, tags));
  }

  @override
  Future<void> deleteIllust(int id, {CancelToken? cancelToken}) async {
    deletes.add(id);
  }

  @override
  Future<void> addNovel(
    int id,
    BookmarkRestrict restrict, {
    List<String>? tags,
    CancelToken? cancelToken,
  }) async {
    final error = addError;
    if (error != null) throw error;
    adds.add((id, restrict.name, tags));
  }

  @override
  Future<void> deleteNovel(int id, {CancelToken? cancelToken}) async {
    deletes.add(id);
  }

  @override
  Future<BookmarkDetail> fetchDetail(
    BookmarkKey key, {
    CancelToken? cancelToken,
  }) async {
    final gate = detailGate;
    if (gate != null) await gate.future;
    final error = detailError;
    if (error != null) throw error;
    return detail;
  }

  @override
  Future<UserBookmarkTagPage> fetchUserTags(
    int userId, {
    required BookmarkEntityType entityType,
    required BookmarkRestrict restrict,
    String? cursor,
    CancelToken? cancelToken,
  }) async => tagPage;

  @override
  bool validateUserTagsCursor(
    int userId, {
    required BookmarkEntityType entityType,
    required BookmarkRestrict restrict,
    required String cursor,
  }) => false;
}
