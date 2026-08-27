import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/comment_entity.dart';
import 'comment_models.dart';

/// Canonical comment state. Feeds contain only IDs; the entity payload and
/// thread indexes live here so root/reply pages observe one copy of a
/// comment.
@immutable
class CommentStoreState {
  CommentStoreState({
    Map<int, CommentEntity>? entities,
    Map<int, List<int>>? rootIdsByIllust,
    Map<int, List<int>>? replyIdsByRoot,
    Map<String, CommentMutation>? mutations,
  }) : entities = Map.unmodifiable(entities ?? const {}),
       rootIdsByIllust = _freezeIndex(rootIdsByIllust),
       replyIdsByRoot = _freezeIndex(replyIdsByRoot),
       mutations = Map.unmodifiable(mutations ?? const {});

  final Map<int, CommentEntity> entities;
  final Map<int, List<int>> rootIdsByIllust;
  final Map<int, List<int>> replyIdsByRoot;
  final Map<String, CommentMutation> mutations;

  CommentEntity? get(int commentId) => entities[commentId];

  List<CommentEntity> getAll(Iterable<int> ids) => [
    for (final id in ids)
      if (entities[id] != null) entities[id]!,
  ];

  List<int> idsFor(CommentFeedQuery query) => query.isReplies
      ? replyIdsByRoot[query.rootCommentId] ?? const []
      : rootIdsByIllust[query.illustId] ?? const [];

  static Map<int, List<int>> _freezeIndex(Map<int, List<int>>? source) {
    final input = source ?? const <int, List<int>>{};
    return Map.unmodifiable(<int, List<int>>{
      for (final entry in input.entries)
        entry.key: List<int>.unmodifiable(entry.value),
    });
  }
}

/// Account-scoped canonical store for comment entities, thread indexes and
/// mutation revisions.
class CommentStore extends Notifier<CommentStoreState> {
  int _revision = 0;

  @override
  CommentStoreState build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    _revision = 0;
    return CommentStoreState();
  }

  int revisionNow() => _revision;

  CommentEntity? get(int commentId) => state.get(commentId);

  List<int> idsFor(CommentFeedQuery query) => state.idsFor(query);

  CommentMutation? mutationFor(String key) => state.mutations[key];

  /// Merges a remote page into the selected root/reply index. Duplicate IDs
  /// are ignored in the ordered index while payloads are merged canonically.
  void mergePage(CommentFeedQuery query, Iterable<CommentEntity> comments) {
    final entities = Map<int, CommentEntity>.of(state.entities);
    final roots = _copyIndex(state.rootIdsByIllust);
    final replies = _copyIndex(state.replyIdsByRoot);
    for (final incoming in comments) {
      if (!_belongsToQuery(query, incoming)) continue;
      final existing = entities[incoming.id];
      entities[incoming.id] = existing == null
          ? incoming
          : existing.merge(incoming);
      _addId(query, incoming.id, roots, replies);
    }
    state = CommentStoreState(
      entities: entities,
      rootIdsByIllust: roots,
      replyIdsByRoot: replies,
      mutations: state.mutations,
    );
  }

  /// Inserts a confirmed comment at the front of its correct thread.
  void prepend(CommentFeedQuery query, CommentEntity comment) {
    if (!_belongsToQuery(query, comment)) return;
    final entities = Map<int, CommentEntity>.of(state.entities)
      ..update(
        comment.id,
        (existing) => existing.merge(comment),
        ifAbsent: () => comment,
      );
    final roots = _copyIndex(state.rootIdsByIllust);
    final replies = _copyIndex(state.replyIdsByRoot);
    final ids = query.isReplies
        ? (replies[query.rootCommentId!] ??= <int>[])
        : (roots[query.illustId] ??= <int>[]);
    ids.remove(comment.id);
    ids.insert(0, comment.id);
    state = CommentStoreState(
      entities: entities,
      rootIdsByIllust: roots,
      replyIdsByRoot: replies,
      mutations: state.mutations,
    );
  }

  /// Starts a send operation. One pending send is allowed per exact parent
  /// key, so a repeated tap cannot create duplicate server requests.
  CommentSendOperation? beginSend({
    required int illustId,
    int? parentCommentId,
    int? rootCommentId,
  }) {
    _requirePositive(illustId, 'illustId');
    _optionalPositive(parentCommentId, 'parentCommentId');
    _optionalPositive(rootCommentId, 'rootCommentId');
    if (rootCommentId == null && parentCommentId != null) {
      throw const FormatException('root send cannot have a parent id');
    }
    final key = 'send:$illustId:${parentCommentId ?? 'root'}';
    if (state.mutations[key]?.pending == true) return null;
    final operation = CommentSendOperation(
      illustId: illustId,
      parentCommentId: parentCommentId,
      rootCommentId: rootCommentId,
      revision: ++_revision,
    );
    state = CommentStoreState(
      entities: state.entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: {
        ...state.mutations,
        operation.key: CommentMutation(
          kind: CommentMutationKind.send,
          revision: operation.revision,
        ),
      },
    );
    return operation;
  }

  void commitSend(CommentSendOperation operation, CommentEntity comment) {
    final mutation = state.mutations[operation.key];
    if (mutation?.revision != operation.revision ||
        mutation?.kind != CommentMutationKind.send) {
      return;
    }
    final normalized = comment.copyWith(
      illustId: operation.illustId,
      parentCommentId: operation.parentCommentId,
      rootCommentId: operation.rootCommentId ?? comment.id,
    );
    final nextMutations = Map<String, CommentMutation>.of(state.mutations)
      ..remove(operation.key);
    state = CommentStoreState(
      entities: state.entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: nextMutations,
    );
    final query = operation.rootCommentId == null
        ? CommentFeedQuery.root(illustId: operation.illustId)
        : CommentFeedQuery.replies(
            illustId: operation.illustId,
            rootCommentId: operation.rootCommentId!,
          );
    prepend(query, normalized);
    if (operation.rootCommentId != null) {
      updateReplyCount(operation.rootCommentId!, delta: 1);
    }
  }

  void failSend(CommentSendOperation operation, Object error) {
    final mutation = state.mutations[operation.key];
    if (mutation?.revision != operation.revision ||
        mutation?.kind != CommentMutationKind.send) {
      return;
    }
    state = CommentStoreState(
      entities: state.entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: _withMutation(
        operation.key,
        CommentMutation(
          kind: CommentMutationKind.send,
          revision: operation.revision,
          error: error,
        ),
      ),
    );
  }

  /// Starts a delete operation keyed by the server comment ID.
  CommentDeleteOperation? beginDelete(int commentId) {
    _requirePositive(commentId, 'commentId');
    final key = 'delete:$commentId';
    if (state.mutations[key]?.pending == true) return null;
    final operation = CommentDeleteOperation(
      commentId: commentId,
      revision: ++_revision,
    );
    state = CommentStoreState(
      entities: state.entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: _withMutation(
        operation.key,
        CommentMutation(
          kind: CommentMutationKind.delete,
          revision: operation.revision,
        ),
      ),
    );
    return operation;
  }

  void commitDelete(CommentDeleteOperation operation) {
    final mutation = state.mutations[operation.key];
    if (mutation?.revision != operation.revision ||
        mutation?.kind != CommentMutationKind.delete) {
      return;
    }
    final target = state.entities[operation.commentId];
    final nextMutations = Map<String, CommentMutation>.of(state.mutations)
      ..remove(operation.key);
    state = CommentStoreState(
      entities: state.entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: nextMutations,
    );
    if (target == null) return;
    _removeEntity(target);
  }

  void failDelete(CommentDeleteOperation operation, Object error) {
    final mutation = state.mutations[operation.key];
    if (mutation?.revision != operation.revision ||
        mutation?.kind != CommentMutationKind.delete) {
      return;
    }
    state = CommentStoreState(
      entities: state.entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: _withMutation(
        operation.key,
        CommentMutation(
          kind: CommentMutationKind.delete,
          revision: operation.revision,
          error: error,
        ),
      ),
    );
  }

  /// Removes a confirmed entity and, for a root, every reply in the same
  /// thread. The reply count is changed only for a reply deletion.
  void remove(CommentEntity comment) => _removeEntity(comment);

  void updateReplyCount(int rootCommentId, {required int delta}) {
    _requirePositive(rootCommentId, 'rootCommentId');
    final root = state.entities[rootCommentId];
    if (root == null || !root.isRoot) return;
    final nextCount = (root.replyCount + delta).clamp(0, 1 << 30);
    final entities = Map<int, CommentEntity>.of(state.entities)
      ..[rootCommentId] = root.copyWith(
        replyCount: nextCount,
        hasReplies: nextCount > 0,
      );
    state = CommentStoreState(
      entities: entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: state.mutations,
    );
  }

  Map<String, CommentMutation> _withMutation(
    String key,
    CommentMutation mutation,
  ) => {...state.mutations, key: mutation};

  void _removeEntity(CommentEntity target) {
    final removeIds = <int>{target.id};
    if (target.isRoot) {
      removeIds.addAll(
        state.entities.values
            .where((item) => item.rootCommentId == target.id)
            .map((item) => item.id),
      );
    }
    final entities = Map<int, CommentEntity>.of(state.entities)
      ..removeWhere((id, _) => removeIds.contains(id));
    final roots = _copyIndex(state.rootIdsByIllust)
      ..updateAll((_, ids) => ids..removeWhere(removeIds.contains));
    final replies = _copyIndex(state.replyIdsByRoot)
      ..removeWhere((rootId, ids) {
        ids.removeWhere(removeIds.contains);
        return removeIds.contains(rootId) || ids.isEmpty;
      });
    if (!target.isRoot) {
      final root = state.entities[target.rootCommentId];
      if (root != null && root.replyCount > 0) {
        entities[root.id] = root.copyWith(
          replyCount: root.replyCount - 1,
          hasReplies: root.replyCount > 1,
        );
      }
    }
    state = CommentStoreState(
      entities: entities,
      rootIdsByIllust: roots,
      replyIdsByRoot: replies,
      mutations: state.mutations,
    );
  }

  bool _belongsToQuery(CommentFeedQuery query, CommentEntity comment) {
    if (comment.illustId != query.illustId) return false;
    if (query.isReplies) {
      return !comment.isRoot && comment.rootCommentId == query.rootCommentId;
    }
    return comment.isRoot;
  }

  void _addId(
    CommentFeedQuery query,
    int id,
    Map<int, List<int>> roots,
    Map<int, List<int>> replies,
  ) {
    final ids = query.isReplies
        ? (replies[query.rootCommentId!] ??= <int>[])
        : (roots[query.illustId] ??= <int>[]);
    if (!ids.contains(id)) ids.add(id);
  }

  Map<int, List<int>> _copyIndex(Map<int, List<int>> source) => {
    for (final entry in source.entries) entry.key: List<int>.of(entry.value),
  };

  static void _requirePositive(int value, String field) {
    if (value <= 0) throw FormatException('$field must be positive');
  }

  static void _optionalPositive(int? value, String field) {
    if (value != null && value <= 0) {
      throw FormatException('$field must be positive');
    }
  }
}

final commentStoreProvider = NotifierProvider<CommentStore, CommentStoreState>(
  CommentStore.new,
);
