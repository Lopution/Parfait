import 'package:flutter/foundation.dart';

import '../network/pixiv_http_client.dart';

/// A request identity that must travel with every page response.
///
/// The identity is captured before the request is issued. A response may only
/// commit when its feed, account/credential boundary, generation and
/// cancellation handle still describe the active request.
@immutable
class FeedRequestContext {
  const FeedRequestContext({
    required this.feedKey,
    required this.accountId,
    required this.credentialRevision,
    required this.generation,
    required this.page,
    required this.cursor,
    required this.cancelToken,
  });

  final String feedKey;
  final String? accountId;
  final int credentialRevision;
  final int generation;
  final int page;
  final String? cursor;
  final CancelToken cancelToken;

  bool get isCancelled => cancelToken.isCancelled;
}

typedef FeedPageCommit = void Function(FeedRequestContext context);

/// Typed page data returned before the controller commits it.
///
/// [commit] is deliberately deferred. Repositories may parse and normalize a
/// response, but shared stores are written only after the controller's active
/// context gate accepts the complete page.
@immutable
class FeedPage {
  FeedPage({required List<int> ids, required this.nextCursor, this.commit})
    : ids = List.unmodifiable(ids);

  final List<int> ids;
  final String? nextCursor;
  final FeedPageCommit? commit;
}

enum FeedDiscardReason {
  cancelled,
  stale,
  accountChanged,
  credentialChanged,
  disposed,
}

/// Observable, bounded telemetry for responses that were intentionally not
/// committed. It contains request metadata only and no response payload.
@immutable
class FeedDiscardEvent {
  const FeedDiscardEvent({required this.context, required this.reason});

  final FeedRequestContext context;
  final FeedDiscardReason reason;
}

/// Shared generation/identity gate for paginated feed result commits.
///
/// The gate has no entity knowledge. It only decides whether one complete
/// page transaction is still allowed to run; callers perform entity merge,
/// cursor assignment and UI state assignment immediately after [commit]
/// returns true.
class FeedCommitGate {
  FeedCommitGate({this.maxDiscardEvents = 32}) : assert(maxDiscardEvents > 0);

  final int maxDiscardEvents;
  final List<FeedDiscardEvent> _discardEvents = [];
  FeedRequestContext? _active;
  int _generation = 0;

  int get generation => _generation;

  List<FeedDiscardEvent> get discardEvents => List.unmodifiable(_discardEvents);

  /// Starts a new generation, cancelling every request from the old one.
  int beginGeneration() {
    _cancelActive();
    _generation++;
    return _generation;
  }

  FeedRequestContext beginRequest({
    required String feedKey,
    required String? accountId,
    required int credentialRevision,
    required int generation,
    required int page,
    required String? cursor,
    required CancelToken cancelToken,
  }) {
    if (generation != _generation) {
      throw StateError('feed request uses an inactive generation');
    }
    _cancelActive();
    final context = FeedRequestContext(
      feedKey: feedKey,
      accountId: accountId,
      credentialRevision: credentialRevision,
      generation: generation,
      page: page,
      cursor: cursor,
      cancelToken: cancelToken,
    );
    _active = context;
    return context;
  }

  bool commit(
    FeedRequestContext context, {
    required String? accountId,
    required int credentialRevision,
    required void Function() action,
    bool disposed = false,
  }) {
    final reason = _reason(
      context,
      accountId: accountId,
      credentialRevision: credentialRevision,
      disposed: disposed,
    );
    if (reason != null) {
      _record(context, reason);
      return false;
    }
    action();
    return true;
  }

  bool isActive(
    FeedRequestContext context, {
    required String? accountId,
    required int credentialRevision,
    bool disposed = false,
  }) {
    return _reason(
          context,
          accountId: accountId,
          credentialRevision: credentialRevision,
          disposed: disposed,
        ) ==
        null;
  }

  /// Returns whether [context] still owns the gate, ignoring the mutable
  /// account and cancellation boundaries. Controllers use this only to clear
  /// the loading phase of a request that was rejected by one of those
  /// boundaries; a newer context must never be touched.
  bool isCurrent(FeedRequestContext context) =>
      context.generation == _generation && identical(_active, context);

  /// Records a cancelled/stale result that failed before it could reach the
  /// normal [commit] path.
  void discard(
    FeedRequestContext context, {
    required String? accountId,
    required int credentialRevision,
    bool disposed = false,
    FeedDiscardReason? reason,
  }) {
    _record(
      context,
      reason ??
          _reason(
            context,
            accountId: accountId,
            credentialRevision: credentialRevision,
            disposed: disposed,
          ) ??
          FeedDiscardReason.stale,
    );
  }

  void finish(FeedRequestContext context) {
    if (identical(_active, context)) _active = null;
  }

  void cancelActive() => _cancelActive();

  void dispose() {
    _cancelActive();
    _generation++;
  }

  FeedDiscardReason? _reason(
    FeedRequestContext context, {
    required String? accountId,
    required int credentialRevision,
    required bool disposed,
  }) {
    if (disposed) return FeedDiscardReason.disposed;
    if (context.isCancelled) return FeedDiscardReason.cancelled;
    if (context.generation != _generation || !identical(_active, context)) {
      return FeedDiscardReason.stale;
    }
    if (context.accountId != accountId) return FeedDiscardReason.accountChanged;
    if (context.credentialRevision != credentialRevision) {
      return FeedDiscardReason.credentialChanged;
    }
    return null;
  }

  void _cancelActive() {
    _active?.cancelToken.cancel();
    _active = null;
  }

  void _record(FeedRequestContext context, FeedDiscardReason reason) {
    if (_discardEvents.length == maxDiscardEvents) {
      _discardEvents.removeAt(0);
    }
    _discardEvents.add(FeedDiscardEvent(context: context, reason: reason));
  }
}
