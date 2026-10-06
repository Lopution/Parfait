import 'dart:async';
import 'dart:collection';

/// Completes a queued image fetch whose turn came after everyone waiting
/// for it went away. The fetch never reached the network.
class ImageFetchDropped implements Exception {
  const ImageFetchDropped(this.url);

  final String url;

  @override
  String toString() => 'ImageFetchDropped: $url';
}

/// Lane an image fetch is admitted on.
enum ImageFetchPriority {
  /// Something on screen, or about to be because the user just asked for it.
  foreground,

  /// Warm-up work nobody is looking at yet.
  background,
}

/// One pending admission on a [LanePermitGate]. The completer resolves with
/// the owning gate once a slot is granted; the gate is carried so the holder
/// knows which lane to release — a promoted waiter's slot returns to the
/// foreground pool, not the one it queued on.
class LaneWaiter {
  LaneWaiter(this.url);

  final String url;
  final completer = Completer<LanePermitGate>();
}

/// A bounded FIFO permit gate for one image-fetch lane.
///
/// A permit is held for the whole transfer, not just the header wait, so a
/// lane's slot count is the number of bodies streaming at once. Releasing a
/// permit admits the next queued waiter whose [wants] check still passes —
/// a waiter nobody wants any more is completed with [ImageFetchDropped]
/// without ever touching the network.
class LanePermitGate {
  LanePermitGate(this._slots, [this._wants]);

  final int _slots;

  /// Asked when a queued waiter's turn comes; null admits every waiter.
  final bool Function(String url)? _wants;
  var _inFlight = 0;
  final _waiters = Queue<LaneWaiter>();

  /// Permits currently held by streaming transfers.
  int get inFlight => _inFlight;

  /// Requests still queued behind the slot limit.
  int get queued => _waiters.length;

  Future<LanePermitGate> acquire(String url) => admit(LaneWaiter(url));

  /// Grants [waiter] a slot now or queues it; the future completes with
  /// this gate once the slot is granted.
  Future<LanePermitGate> admit(LaneWaiter waiter) {
    if (_inFlight < _slots) {
      _inFlight++;
      waiter.completer.complete(this);
    } else {
      _waiters.add(waiter);
    }
    return waiter.completer.future;
  }

  /// Removes and returns the first queued waiter for [url], if any.
  LaneWaiter? take(String url) {
    for (final waiter in _waiters) {
      if (waiter.url == url) {
        _waiters.remove(waiter);
        return waiter;
      }
    }
    return null;
  }

  /// A waiter removed via [take] and re-queued on another gate never holds
  /// a slot of this gate; [drop] just fails its completer so the awaiting
  /// fetch unwinds instead of hanging forever.
  void drop(LaneWaiter waiter) =>
      waiter.completer.completeError(ImageFetchDropped(waiter.url));

  void release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      if (_wants?.call(next.url) ?? true) {
        // The slot passes to the waiter without dipping _inFlight.
        next.completer.complete(this);
        return;
      }
      drop(next);
    }
    _inFlight--;
  }
}
