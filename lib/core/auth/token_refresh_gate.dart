import 'dart:async';

/// Outcome of a single-flight token refresh.
sealed class RefreshOutcome {
  const RefreshOutcome();
}

/// The account's token was refreshed; [accessToken] is the new token.
class Refreshed extends RefreshOutcome {
  const Refreshed(this.accessToken);

  final String accessToken;
}

/// The request's token was already stale when the gate was consulted: another
/// caller refreshed it meanwhile. The caller should retry with the current
/// token without triggering another refresh.
class AlreadyRefreshed extends RefreshOutcome {
  const AlreadyRefreshed(this.accessToken);

  final String accessToken;
}

/// Refresh failed terminally; the account requires re-authentication.
class RefreshFailed extends RefreshOutcome {
  const RefreshFailed(this.error);

  final Object error;
}

/// Coordinates per-account single-flight token refreshes.
///
/// Concurrent callers for the same account share one [Future]; different
/// accounts refresh independently. The in-flight entry is removed by the
/// task that created it only (`_owner` check), so a stale completion can
/// never evict a newer refresh.
class TokenRefreshGate {
  final Map<String, _InFlight> _inFlight = {};

  /// Resolves the refresh outcome for [accountId].
  ///
  /// - [staleToken] is the token the caller used; [currentToken] is the
  ///   account's token right now. When they differ the token was already
  ///   refreshed and [AlreadyRefreshed] is returned without any network call.
  /// - Otherwise the caller joins (or starts) the account's single refresh
  ///   built by [perform].
  Future<RefreshOutcome> refresh({
    required String accountId,
    required String staleToken,
    required String? currentToken,
    required Future<RefreshOutcome> Function() perform,
  }) {
    if (currentToken != null && currentToken != staleToken) {
      return Future.value(AlreadyRefreshed(currentToken));
    }
    final existing = _inFlight[accountId];
    if (existing != null) {
      return existing.future;
    }
    final inFlight = _InFlight(perform());
    _inFlight[accountId] = inFlight;
    inFlight.future.whenComplete(() {
      // Only the creator removes the entry: a late cleanup must not delete a
      // refresh started after this one completed.
      if (identical(_inFlight[accountId], inFlight)) {
        _inFlight.remove(accountId);
      }
    });
    return inFlight.future;
  }

  /// Whether a refresh is currently running for [accountId] (test hook).
  bool get isRefreshing => _inFlight.isNotEmpty;
}

class _InFlight {
  _InFlight(this.future);

  final Future<RefreshOutcome> future;
}
