import 'package:meta/meta.dart';

export '../../image/lane_permit_gate.dart' show ImageFetchDropped;

/// How long a released URL still counts as wanted. Absorbs the brief
/// unmount/remount of a Hero flight or a list re-layout.
const releaseGrace = Duration(milliseconds: 500);

/// Bookkeeping entries kept before expired ones are pruned.
const _kPruneThreshold = 256;

/// Who is still waiting for an image URL. The file service consults it
/// when a queued fetch reaches its turn: nobody waiting means the fetch is
/// dropped before it costs a connection.
///
/// Keys are the request URLs as the widgets see them; mirror rewriting
/// happens later, inside the HTTP client.
class ImageDemand {
  ImageDemand({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Called when [url] gains an on-screen holder: its first [hold], or any
  /// [holdFor]. Wired to the file service's promotion.
  void Function(String url)? onHeld;

  /// Fired when a mutation may have left [url] unwanted — after a [release]
  /// whose last holder left, or when a prefetch window swap drops it. The
  /// listener re-evaluates [wants] under its own timing (the release path
  /// still counts as wanted during [releaseGrace]); the image worker's
  /// client uses it to decide when a worker request may be cancelled.
  void Function(String url)? onMaybeUnwanted;

  final _counts = <String, int>{};
  final _heldUntil = <String, DateTime>{};
  final _releasedAt = <String, DateTime>{};
  final _windows = <Object, Set<String>>{};

  /// An image widget shows [url]. Pair with [release].
  void hold(String url) {
    final count = _counts[url] ?? 0;
    _counts[url] = count + 1;
    _releasedAt.remove(url);
    if (count == 0) onHeld?.call(url);
  }

  void release(String url) {
    final count = _counts[url];
    assert(count != null, 'release without hold: $url');
    if (count == null) return;
    if (count > 1) {
      _counts[url] = count - 1;
      return;
    }
    _counts.remove(url);
    _releasedAt[url] = _clock();
    _pruneIfLarge();
    onMaybeUnwanted?.call(url);
  }

  /// Wants [url] for [ttl] without a widget, e.g. a preload the user just
  /// asked for whose page has not mounted yet.
  void holdFor(String url, Duration ttl) {
    final until = _clock().add(ttl);
    final current = _heldUntil[url];
    if (current == null || until.isAfter(current)) _heldUntil[url] = until;
    _pruneIfLarge();
    onHeld?.call(url);
  }

  /// Replaces the URLs [owner] is prefetching. URLs that fall out of the
  /// window stop being wanted unless something else holds them.
  void setPrefetchWindow(Object owner, Set<String> urls) {
    final removed = _windows[owner]?.difference(urls);
    _windows[owner] = Set.unmodifiable(urls);
    if (removed != null) {
      for (final url in removed) {
        onMaybeUnwanted?.call(url);
      }
    }
  }

  void clearPrefetchWindow(Object owner) {
    final removed = _windows.remove(owner);
    if (removed != null) {
      for (final url in removed) {
        onMaybeUnwanted?.call(url);
      }
    }
  }

  bool wants(String url) {
    if (_counts.containsKey(url)) return true;
    final now = _clock();
    final until = _heldUntil[url];
    if (until != null && now.isBefore(until)) return true;
    for (final window in _windows.values) {
      if (window.contains(url)) return true;
    }
    final releasedAt = _releasedAt[url];
    return releasedAt != null && now.difference(releasedAt) < releaseGrace;
  }

  /// Widgets currently holding [url].
  @visibleForTesting
  int debugHolds(String url) => _counts[url] ?? 0;

  /// Timed-hold and release entries currently kept.
  @visibleForTesting
  int get debugBookkeepingSize => _heldUntil.length + _releasedAt.length;

  void _pruneIfLarge() {
    if (_heldUntil.length + _releasedAt.length <= _kPruneThreshold) return;
    final now = _clock();
    _heldUntil.removeWhere((_, until) => !now.isBefore(until));
    _releasedAt.removeWhere(
      (_, releasedAt) => now.difference(releasedAt) >= releaseGrace,
    );
  }
}
