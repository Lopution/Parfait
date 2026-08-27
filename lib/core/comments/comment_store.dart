import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/comment_entity.dart';
import '../mutation/mutation_boundary.dart';
import '../mutation/mutation_models.dart';
import '../network/api_error.dart';
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
/// mutation ownership.
class CommentStore extends Notifier<CommentStoreState> {
  final MutationLedger _ledger = MutationLedger();
  MutationBoundary? _boundary;
  bool _built = false;
  bool _disposeRegistered = false;

  @override
  CommentStoreState build() {
    if (_ledger.isDisposed) {
      _ledger.reopen();
      _disposeRegistered = false;
    }
    ref.watch(
      accountStoreProvider.select((async) {
        final account = async.value;
        return (account?.usableCurrent?.id, account?.credentialRevision ?? 0);
      }),
    );
    final current = readMutationBoundary(ref);
    if (_boundary != null && !sameMutationBoundary(_boundary, current)) {
      _invalidateBoundary(current, settleState: false);
    }
    _boundary = current;
    if (!_disposeRegistered) {
      _disposeRegistered = true;
      ref.onDispose(() {
        _ledger.dispose();
        _built = false;
      });
    }
    _built = true;
    return CommentStoreState();
  }

  int revisionNow() => _ledger.revisionNow;

  List<MutationDiscardEvent> get discardEvents => _ledger.discardEvents;

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
    final boundary = _requireBoundary();
    final envelope = _ledger.begin(
      boundary: boundary,
      entityType: 'comment',
      entityId: 'illust:$illustId:${parentCommentId ?? 'root'}',
      operation: 'comment.send',
      ownerId: 'comment-send:$illustId:${parentCommentId ?? 'root'}',
    );
    if (envelope == null) return null;
    final operation = CommentSendOperation(
      illustId: illustId,
      parentCommentId: parentCommentId,
      rootCommentId: rootCommentId,
      envelope: envelope,
    );
    _setMutation(
      operation.key,
      CommentMutation(kind: CommentMutationKind.send, envelope: envelope),
    );
    return operation;
  }

  void commitSend(CommentSendOperation operation, CommentEntity comment) {
    if (!_owns(
      operation.envelope,
      key: operation.key,
      kind: CommentMutationKind.send,
    )) {
      return;
    }
    final normalized = comment.copyWith(
      illustId: operation.illustId,
      parentCommentId: operation.parentCommentId,
      rootCommentId: operation.rootCommentId ?? comment.id,
    );
    _ledger.finish(operation.envelope);
    _setMutation(
      operation.key,
      CommentMutation(
        kind: CommentMutationKind.send,
        envelope: operation.envelope,
        status: MutationStatus.confirmed,
      ),
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
    if (!_owns(
      operation.envelope,
      key: operation.key,
      kind: CommentMutationKind.send,
    )) {
      return;
    }
    final cancelled =
        error is ApiCancelled || operation.cancelToken.isCancelled;
    if (cancelled) {
      _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    } else {
      _ledger.finish(operation.envelope);
    }
    _setMutation(
      operation.key,
      CommentMutation(
        kind: CommentMutationKind.send,
        envelope: operation.envelope,
        status: cancelled ? MutationStatus.cancelled : MutationStatus.failed,
        error: cancelled ? null : error,
      ),
    );
  }

  bool cancelSend(CommentSendOperation operation) {
    if (!_owns(
      operation.envelope,
      key: operation.key,
      kind: CommentMutationKind.send,
    )) {
      return false;
    }
    _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    _setMutation(
      operation.key,
      CommentMutation(
        kind: CommentMutationKind.send,
        envelope: operation.envelope,
        status: MutationStatus.cancelled,
      ),
    );
    return true;
  }

  /// Starts a delete operation keyed by the server comment ID.
  CommentDeleteOperation? beginDelete(int commentId) {
    _requirePositive(commentId, 'commentId');
    final boundary = _requireBoundary();
    final envelope = _ledger.begin(
      boundary: boundary,
      entityType: 'comment',
      entityId: '$commentId',
      operation: 'comment.delete',
      ownerId: 'comment-delete:$commentId',
    );
    if (envelope == null) return null;
    final operation = CommentDeleteOperation(
      commentId: commentId,
      envelope: envelope,
    );
    _setMutation(
      operation.key,
      CommentMutation(kind: CommentMutationKind.delete, envelope: envelope),
    );
    return operation;
  }

  void commitDelete(CommentDeleteOperation operation) {
    if (!_owns(
      operation.envelope,
      key: operation.key,
      kind: CommentMutationKind.delete,
    )) {
      return;
    }
    final target = state.entities[operation.commentId];
    _ledger.finish(operation.envelope);
    _setMutation(
      operation.key,
      CommentMutation(
        kind: CommentMutationKind.delete,
        envelope: operation.envelope,
        status: MutationStatus.confirmed,
      ),
    );
    if (target == null) return;
    _removeEntity(target);
  }

  void failDelete(CommentDeleteOperation operation, Object error) {
    if (!_owns(
      operation.envelope,
      key: operation.key,
      kind: CommentMutationKind.delete,
    )) {
      return;
    }
    final cancelled =
        error is ApiCancelled || operation.cancelToken.isCancelled;
    if (cancelled) {
      _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    } else {
      _ledger.finish(operation.envelope);
    }
    _setMutation(
      operation.key,
      CommentMutation(
        kind: CommentMutationKind.delete,
        envelope: operation.envelope,
        status: cancelled ? MutationStatus.cancelled : MutationStatus.failed,
        error: cancelled ? null : error,
      ),
    );
  }

  bool cancelDelete(CommentDeleteOperation operation) {
    if (!_owns(
      operation.envelope,
      key: operation.key,
      kind: CommentMutationKind.delete,
    )) {
      return false;
    }
    _ledger.discard(operation.envelope, MutationDiscardReason.cancelled);
    _setMutation(
      operation.key,
      CommentMutation(
        kind: CommentMutationKind.delete,
        envelope: operation.envelope,
        status: MutationStatus.cancelled,
      ),
    );
    return true;
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

  bool _owns(
    MutationEnvelope envelope, {
    required String key,
    required CommentMutationKind kind,
  }) {
    if (!_ledger.isActive(envelope)) return false;
    final current = readMutationBoundary(ref);
    _boundary = current;
    final reason = mutationBoundaryReason(envelope, current);
    if (reason != null) {
      _ledger.discard(envelope, reason);
      _setCancelledEnvelope(key, envelope, kind);
      return false;
    }
    final mutation = state.mutations[key];
    if (mutation == null ||
        mutation.envelope != envelope ||
        mutation.kind != kind ||
        !mutation.pending) {
      _ledger.discard(envelope, MutationDiscardReason.stale);
      return false;
    }
    return true;
  }

  MutationBoundary _requireBoundary() {
    final current = readMutationBoundary(ref);
    if (current == null) {
      throw const ApiUnauthorized('no signed-in account');
    }
    if (_boundary != null && !sameMutationBoundary(_boundary, current)) {
      _invalidateBoundary(current, settleState: _built);
    }
    _boundary = current;
    return current;
  }

  void _invalidateBoundary(
    MutationBoundary? current, {
    required bool settleState,
  }) {
    final reason = _boundary == null || current == null
        ? MutationDiscardReason.accountChanged
        : _boundary!.accountId != current.accountId
        ? MutationDiscardReason.accountChanged
        : _boundary!.credentialRevision != current.credentialRevision
        ? MutationDiscardReason.credentialChanged
        : MutationDiscardReason.networkChanged;
    _ledger.cancelAll(reason);
    if (!settleState) return;
    final next = <String, CommentMutation>{};
    for (final entry in state.mutations.entries) {
      final mutation = entry.value;
      next[entry.key] = mutation.pending
          ? CommentMutation(
              kind: mutation.kind,
              envelope: mutation.envelope,
              status: MutationStatus.cancelled,
            )
          : mutation;
    }
    state = CommentStoreState(
      entities: state.entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: next,
    );
  }

  void _setCancelledEnvelope(
    String key,
    MutationEnvelope envelope,
    CommentMutationKind kind,
  ) {
    final mutation = state.mutations[key];
    if (mutation?.envelope != envelope) return;
    _setMutation(
      key,
      CommentMutation(
        kind: kind,
        envelope: envelope,
        status: MutationStatus.cancelled,
      ),
    );
  }

  void _setMutation(String key, CommentMutation mutation) {
    state = CommentStoreState(
      entities: state.entities,
      rootIdsByIllust: state.rootIdsByIllust,
      replyIdsByRoot: state.replyIdsByRoot,
      mutations: {...state.mutations, key: mutation},
    );
  }

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
