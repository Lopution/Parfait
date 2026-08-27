import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../user/user_entity.dart';

/// The canonical identity and thread relationship of one Pixiv comment.
///
/// Pixiv's comment payload does not always echo a parent ID on replies. The
/// repository therefore supplies [rootCommentId] while normalizing a reply;
/// the entity still keeps [parentCommentId] and [rootCommentId] separate so
/// an update can never accidentally target another comment with the same
/// local list position.
@immutable
class CommentEntity {
  const CommentEntity({
    required this.id,
    required this.illustId,
    required this.parentCommentId,
    required this.rootCommentId,
    required this.user,
    required this.content,
    required this.createdAt,
    this.stampId,
    this.stampUrl,
    this.hasReplies = false,
    this.replyCount = 0,
  }) : assert(id > 0),
       assert(illustId > 0),
       assert(rootCommentId > 0),
       assert(parentCommentId == null || parentCommentId > 0),
       assert(parentCommentId != id),
       assert(replyCount >= 0),
       assert(stampId == null || stampId > 0);

  final int id;
  final int illustId;

  /// Direct parent. Null means this is a root comment.
  final int? parentCommentId;

  /// Root comment ID for the whole thread. A root comment points to itself.
  final int rootCommentId;

  final UserEntity user;
  final String content;
  final DateTime createdAt;
  final int? stampId;
  final String? stampUrl;
  final bool hasReplies;
  final int replyCount;

  bool get isRoot => parentCommentId == null;

  /// Parses both `/v3/illust/comments` and `/v2/illust/comment/replies`
  /// entries. The replies endpoint supplies [rootCommentId] because its
  /// response model omits the parent field.
  factory CommentEntity.fromJson(
    Map<String, dynamic> json, {
    required int illustId,
    int? rootCommentId,
  }) {
    final id = _positiveInt(json['id'], 'comment.id');
    final parent = _optionalPositiveInt(
      json['parent_comment_id'],
      'comment.parent_comment_id',
    );
    final suppliedRoot =
        rootCommentId ??
        _optionalPositiveInt(
          json['root_comment_id'],
          'comment.root_comment_id',
        );
    final effectiveParent =
        parent ??
        (suppliedRoot != null && suppliedRoot != id ? suppliedRoot : null);
    final effectiveRoot = suppliedRoot ?? effectiveParent ?? id;
    if (effectiveRoot <= 0) {
      throw const FormatException('comment.root_comment_id must be positive');
    }
    if (effectiveParent == id) {
      throw const FormatException('comment.parent_comment_id cannot equal id');
    }
    if (effectiveParent == null && effectiveRoot != id) {
      throw const FormatException(
        'root comment must use its own id as root_comment_id',
      );
    }

    final userJson = json['user'];
    if (userJson is! Map<String, dynamic>) {
      throw const FormatException('comment.user is missing');
    }
    final stamp = _parseStamp(json['stamp']);
    final content = json['comment'];
    if (content != null && content is! String) {
      throw const FormatException('comment.comment must be a string');
    }
    final replyCount = _replyCount(json);
    final hasReplies = json['has_replies'] is bool
        ? json['has_replies'] as bool
        : replyCount > 0;
    return CommentEntity(
      id: id,
      illustId: _positiveInt(illustId, 'illustId'),
      parentCommentId: effectiveParent,
      rootCommentId: effectiveRoot,
      user: UserEntity.fromUserJson(userJson),
      content: content as String? ?? '',
      createdAt: _date(json['date'] ?? json['created_at']),
      stampId: stamp?.id,
      stampUrl: stamp?.url,
      hasReplies: hasReplies,
      replyCount: replyCount,
    );
  }

  CommentEntity copyWith({
    int? id,
    int? illustId,
    Object? parentCommentId = _unset,
    int? rootCommentId,
    UserEntity? user,
    String? content,
    DateTime? createdAt,
    Object? stampId = _unset,
    Object? stampUrl = _unset,
    bool? hasReplies,
    int? replyCount,
  }) {
    return CommentEntity(
      id: id ?? this.id,
      illustId: illustId ?? this.illustId,
      parentCommentId: identical(parentCommentId, _unset)
          ? this.parentCommentId
          : parentCommentId as int?,
      rootCommentId: rootCommentId ?? this.rootCommentId,
      user: user ?? this.user,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      stampId: identical(stampId, _unset) ? this.stampId : stampId as int?,
      stampUrl: identical(stampUrl, _unset)
          ? this.stampUrl
          : stampUrl as String?,
      hasReplies: hasReplies ?? this.hasReplies,
      replyCount: replyCount ?? this.replyCount,
    );
  }

  /// Merges a later payload into the single canonical entity copy.
  CommentEntity merge(CommentEntity incoming) {
    if (incoming.id != id || incoming.illustId != illustId) return this;
    final incomingReplyCount = incoming.replyCount > replyCount
        ? incoming.replyCount
        : replyCount;
    return copyWith(
      parentCommentId: incoming.parentCommentId,
      rootCommentId: incoming.rootCommentId,
      user: user.merge(incoming.user),
      content: incoming.content.isNotEmpty ? incoming.content : content,
      createdAt: incoming.createdAt,
      stampId: incoming.stampId ?? stampId,
      stampUrl: incoming.stampUrl ?? stampUrl,
      hasReplies: hasReplies || incoming.hasReplies,
      replyCount: incomingReplyCount,
    );
  }

  @override
  String toString() =>
      'CommentEntity(${jsonEncode({'id': id, 'illustId': illustId, 'parentCommentId': parentCommentId, 'rootCommentId': rootCommentId, 'userId': user.id})})';
}

const _unset = Object();

int _positiveInt(Object? value, String field) {
  final parsed = value is int ? value : int.tryParse('$value');
  if (parsed != null && parsed > 0) return parsed;
  throw FormatException('$field must be a positive integer');
}

int? _optionalPositiveInt(Object? value, String field) {
  if (value == null) return null;
  return _positiveInt(value, field);
}

DateTime _date(Object? value) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw const FormatException('comment.date must be an ISO date');
}

({int id, String? url})? _parseStamp(Object? value) {
  if (value == null) return null;
  if (value is! Map<String, dynamic>) {
    throw const FormatException('comment.stamp must be an object');
  }
  final id = _positiveInt(value['stamp_id'], 'comment.stamp.stamp_id');
  final url = value['stamp_url'];
  if (url != null && url is! String) {
    throw const FormatException('comment.stamp.stamp_url must be a string');
  }
  return (id: id, url: url as String?);
}

int _replyCount(Map<String, dynamic> json) {
  final value = json['reply_count'] ?? json['replies_count'];
  if (value == null) return 0;
  final parsed = value is int ? value : int.tryParse('$value');
  if (parsed != null && parsed >= 0) return parsed;
  throw const FormatException('comment.reply_count must be non-negative');
}
