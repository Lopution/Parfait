import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'widget_channel.dart';
import 'widget_feed_loader.dart';

/// Foreground widget maintenance: runs one generation pass at startup and
/// after every account change, mirroring the outcome to the native side.
///
/// Failure semantics (PRD R6):
/// - written → notify widgets, re-key scheduled work;
/// - noAccount / authRequired → clear render state immediately;
/// - transientFailure → keep the same-account last-good and ask native for
///   one bounded one-shot retry.
class WidgetCoordinator {
  WidgetCoordinator(this._ref);

  final Ref _ref;
  ProviderSubscription<AsyncValue<AccountState>>? _accountSubscription;
  String? _lastAccountId;
  int _lastRevision = -1;
  Future<void> _passTail = Future<void>.value();
  int _stateEpoch = 0;
  bool _started = false;
  bool _disposed = false;

  /// Subscribes to account changes and runs the first pass. Safe to call
  /// once from the app bootstrap.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _accountSubscription = _ref.listen(
      accountStoreProvider,
      (_, next) => _onAccountState(next.value),
      fireImmediately: true,
    );
  }

  void _onAccountState(AccountState? state) {
    if (state == null) return;
    final account = state.usableCurrent;
    final id = account?.id;
    final revision = state.credentialRevision;
    if (id == _lastAccountId && revision == _lastRevision) return;
    final switched = _lastAccountId != null && id != _lastAccountId;
    _lastAccountId = id;
    _lastRevision = revision;
    final epoch = ++_stateEpoch;
    if (switched) {
      // Queue the clear behind any in-flight pass. This avoids a stale pass
      // republishing native state after the account switch, and the epoch
      // check prevents an intermediate account from starting another pass.
      _enqueue(() async {
        await WidgetChannel.clearSnapshot();
        if (_disposed || epoch != _stateEpoch) return;
        await _runPass();
      });
      return;
    }
    _enqueue(_runPass);
  }

  /// One generation pass plus native side effects.
  Future<void> runPass() => _enqueue(_runPass);

  Future<void> _runPass() async {
    if (_disposed) return;
    final WidgetFeedResult result;
    try {
      result = await _ref.read(widgetFeedLoaderProvider).load();
    } on Object catch (error) {
      // The loader classifies every expected failure; reaching here means
      // the load itself could not run, which is transient by definition.
      debugPrint(
        'WidgetCoordinator.runPass failed: ${error.runtimeType}: $error',
      );
      await WidgetChannel.requestRefresh();
      return;
    }
    if (_disposed) return;
    switch (result.outcome) {
      case WidgetFeedOutcome.written:
        await WidgetChannel.notifySnapshotChanged(
          result.snapshot?.accountRevision ?? 0,
        );
      case WidgetFeedOutcome.noAccount:
      case WidgetFeedOutcome.authRequired:
        await WidgetChannel.clearSnapshot();
      case WidgetFeedOutcome.transientFailure:
        await WidgetChannel.requestRefresh();
      case WidgetFeedOutcome.superseded:
        // A newer account/credential boundary owns the next pass.
        break;
    }
  }

  void dispose() {
    _disposed = true;
    _accountSubscription?.close();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _passTail.then((_) {
      if (_disposed) return Future<void>.value();
      return operation();
    });
    _passTail = next.catchError((Object error, StackTrace stackTrace) {
      debugPrint(
        'WidgetCoordinator queued pass failed: ${error.runtimeType}: $error',
      );
    });
    unawaited(next);
    return next;
  }
}

final widgetCoordinatorProvider = Provider<WidgetCoordinator>((ref) {
  final coordinator = WidgetCoordinator(ref);
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
