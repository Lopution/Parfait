/// Feed-snapshot codec for [NovelEntity]. Novels carry a parsed body that
/// never round-trips to the API JSON shape, so the codec owns a
/// snapshot-specific schema: the list-visible fields plus the fields a card
/// needs. Restored entities are previews (`contentAvailable: false`) — the
/// same shape a list response yields — and [NovelStore.mergeAll] keeps any
/// body the reader already loaded.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../paging/feed_snapshot_codec.dart';
import '../user/user_entity.dart';
import 'novel_entity.dart';
import 'novel_store.dart';

final class NovelSnapshotCodec extends FeedSnapshotCodec {
  const NovelSnapshotCodec();

  @override
  String get entityType => 'novel';

  @override
  Map<String, Object?> encodeEntities(Ref ref, List<int> ids) {
    final novels = ref.read(novelStoreProvider);
    return {
      for (final id in ids)
        if (novels[id] case final entity?) '$id': _encode(entity),
    };
  }

  @override
  List<int> restoreEntities(
    Ref ref,
    List<int> ids,
    Map<String, Object?> entitiesJson,
  ) {
    final decoded = <NovelEntity>[];
    final restored = <int>[];
    for (final id in ids) {
      final payload = entitiesJson['$id'];
      if (payload is! Map<String, dynamic>) continue;
      final entity = _decode(payload);
      if (entity == null) continue;
      decoded.add(entity);
      restored.add(id);
    }
    if (decoded.isNotEmpty) {
      ref.read(novelStoreProvider.notifier).mergeAll(decoded);
    }
    return restored;
  }

  static Map<String, Object?> _encode(NovelEntity entity) => {
    'id': entity.id,
    'title': entity.title,
    'caption': entity.caption,
    'text_length': entity.textLength,
    'user': {
      'id': entity.user.id,
      'name': entity.user.name,
      'account': entity.user.account,
      'profile_image_url': entity.user.profileImageUrl,
      'is_followed': entity.user.isFollowed,
      'is_muted': entity.user.isMuted,
      'visible': entity.user.visible,
    },
    'tags': [
      for (final tag in entity.tags)
        {'name': tag.name, 'translated_name': tag.translatedName},
    ],
    'series_id': entity.seriesId,
    'series_title': entity.seriesTitle,
    'cover_image_url': entity.coverImageUrl,
    'restrict': entity.restrict,
    'x_restrict': entity.xRestrict,
    'is_original': entity.isOriginal,
    'is_bookmarked': entity.isBookmarked,
    'total_bookmarks': entity.totalBookmarks,
    'total_view': entity.totalView,
    'total_comments': entity.totalComments,
    'visible': entity.visible,
    'is_muted': entity.isMuted,
    'is_mypixiv_only': entity.isMyPixivOnly,
    'is_x_restricted': entity.isXRestricted,
    'novel_ai_type': entity.novelAiType,
    'create_date': entity.createDate,
  };

  static NovelEntity? _decode(Map<String, dynamic> json) {
    try {
      final id = json['id'];
      final title = json['title'];
      final userJson = json['user'];
      if (id is! int || title is! String || userJson is! Map<String, dynamic>) {
        return null;
      }
      final userId = userJson['id'];
      final userName = userJson['name'];
      if (userId is! int || userName is! String) return null;
      final textLength = json['text_length'];
      final length = textLength is int ? textLength : 0;
      final tags = <NovelTag>[
        if (json['tags'] case final List<dynamic> list)
          for (final tag in list)
            if (tag is Map<String, dynamic> && tag['name'] is String)
              NovelTag(
                name: tag['name'] as String,
                translatedName: tag['translated_name'] as String?,
              ),
      ];
      return NovelEntity(
        id: id,
        title: title,
        caption: json['caption'] as String? ?? '',
        user: UserEntity(
          id: userId,
          name: userName,
          account: userJson['account'] as String? ?? '',
          profileImageUrl: userJson['profile_image_url'] as String?,
          isFollowed: userJson['is_followed'] as bool?,
          isMuted: userJson['is_muted'] as bool? ?? false,
          visible: userJson['visible'] as bool? ?? true,
        ),
        tags: List.unmodifiable(tags),
        textLength: length,
        // Same derivation NovelEntity.fromJson uses for metadata payloads,
        // so a restored preview is indistinguishable from a fresh one.
        contentVersion: sha256
            .convert(utf8.encode('metadata:$id:$length'))
            .toString(),
        paragraphs: const [],
        seriesId: json['series_id'] as int?,
        seriesTitle: json['series_title'] as String?,
        coverImageUrl: json['cover_image_url'] as String?,
        restrict: json['restrict'] as int? ?? 0,
        xRestrict: json['x_restrict'] as int? ?? 0,
        isOriginal: json['is_original'] == true,
        isBookmarked: json['is_bookmarked'] == true,
        totalBookmarks: json['total_bookmarks'] as int? ?? 0,
        totalView: json['total_view'] as int? ?? 0,
        totalComments: json['total_comments'] as int? ?? 0,
        visible: json['visible'] is! bool || json['visible'] == true,
        isMuted: json['is_muted'] == true,
        isMyPixivOnly: json['is_mypixiv_only'] == true,
        isXRestricted: json['is_x_restricted'] == true,
        novelAiType: json['novel_ai_type'] as int? ?? 0,
        createDate: json['create_date'] as String?,
      );
    } on Object {
      return null;
    }
  }
}
