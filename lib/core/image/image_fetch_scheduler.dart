import 'dart:async';

import '../network/compat/network_contracts.dart';
import 'lane_permit_gate.dart';

/// Schedules image fetches for the worker isolate: two lanes, same-URL
/// coalescing, lane promotion and a cancel grace window.
///
/// - The **foreground lane** streams [foregroundSlots] bodies at once, the
///   **background lane** [backgroundSlots]; a permit is held for the whole
///   transfer, so lane size == parallel transfers.
/// - Requests for a URL already queued or streaming **share the flight**:
///   each requester keeps its own id and its own completion, but the
///   network sees one transfer.
/// - A foreground request joining a *queued* background fetch **promotes**
///   it — the waiter moves lanes, inheriting the foreground slot when one
///   frees.
/// - [cancel] drops the caller's interest immediately (it completes with
///   [ImageFetchDropped]). A queued fetch left with zero interests is
///   dropped after [cancelGrace] — the grace absorbs the unmount/remount
///   of a Hero flight or a list re-layout without losing queue position.
/// - A transfer that already started runs to the end, so its bytes land
///   in the disk cache for the next visit, unless it is [abortable]: an
///   original whose last interest left stops at once, and a new request
///   for its URL starts a fresh flight. The caller's own release grace
///   (`ImageDemand`) has already passed by the time its cancel arrives.
///
/// The transport itself is injected via [execute] — the scheduler only owns
/// ordering and lifetimes, which keeps it testable without sockets.
class ImageFetchScheduler<T> {
  ImageFetchScheduler({
    required this.execute,
    this.abortable = _never,
    this.foregroundSlots = defaultForegroundSlots,
    this.backgroundSlots = defaultBackgroundSlots,
    this.cancelGrace = const Duration(milliseconds: 500),
  });

  static const defaultForegroundSlots = 8;
  static const defaultBackgroundSlots = 2;

  /// Runs one admitted fetch to completion (transport + disk write lives
  /// in the caller). Its result/error is fanned out to every interest.
  /// [cancel] fires when an [abortable] transfer loses its last interest.
  final Future<T> Function(String url, NetworkCancelSignal cancel) execute;

  /// Whether a streaming transfer for a URL stops when nobody wants it:
  /// megabytes the user has swiped past, whose bandwidth the page on screen
  /// needs.
  final bool Function(String url) abortable;

  static bool _never(String url) => false;

  final int foregroundSlots;
  final int backgroundSlots;

  /// How long a queued fetch stays queued after its last interest left.
  final Duration cancelGrace;

  final Map<String, _Fetch<T>> _fetches = {};
  final Map<int, _Fetch<T>> _interests = {};

  late final LanePermitGate _foreground = LanePermitGate(
    foregroundSlots,
    _wants,
  );
  late final LanePermitGate _background = LanePermitGate(
    backgroundSlots,
    _wants,
  );

  /// Streaming transfers across both lanes.
  int get inFlight => _foreground.inFlight + _background.inFlight;

  /// Requests queued behind the lane limits.
  int get queued => _foreground.queued + _background.queued;

  /// Submits [requestId] for [url]. Completes with the shared fetch result,
  /// an error from [execute], or [ImageFetchDropped] when the request was
  /// cancelled (or dropped from the queue) before it streamed.
  Future<T> submit(
    int requestId,
    String url, {
    required ImageFetchPriority priority,
  }) {
    final completer = Completer<T>();
    final fetch = _fetches.putIfAbsent(url, () => _Fetch<T>(url));
    fetch.dropTimer?.cancel();
    fetch.dropTimer = null;
    _interests[requestId] = fetch;
    fetch.interests[requestId] = (completer, priority);
    if (fetch.waiter == null) {
      // First interest on a fresh fetch: its lane decides admission.
      fetch.foreground = priority == ImageFetchPriority.foreground;
      fetch.waiter = LaneWaiter(url);
      unawaited(_run(fetch));
    } else if (priority == ImageFetchPriority.foreground) {
      _promote(fetch);
    }
    return completer.future;
  }

  /// Drops [requestId]'s interest; the requester completes with
  /// [ImageFetchDropped]. A queued fetch with no interests left arms the
  /// cancel-grace timer; a streaming one runs on unless [abortable].
  void cancel(int requestId) {
    final fetch = _interests.remove(requestId);
    if (fetch == null) return;
    final interest = fetch.interests.remove(requestId);
    interest?.$1.completeError(ImageFetchDropped(fetch.url));
    if (fetch.interests.isNotEmpty) return;
    if (!fetch.streaming) {
      fetch.dropTimer ??= Timer(cancelGrace, () => _drop(fetch));
    } else if (abortable(fetch.url)) {
      // Off the books first: a request for the URL from now on must not
      // join a transfer that is ending.
      if (identical(_fetches[fetch.url], fetch)) _fetches.remove(fetch.url);
      fetch.abort.cancel();
    }
  }

  /// Moves the queued background fetch for [url] onto the foreground lane.
  /// A no-op when no such fetch exists (streaming or absent) — the caller
  /// sends this when a widget starts waiting on a URL it may share with a
  /// warm-up flight.
  void promoteUrl(String url) {
    final fetch = _fetches[url];
    if (fetch != null) _promote(fetch);
  }

  /// Whether the queued fetch for [url] still has someone to serve — asked
  /// by the lane gates when a slot frees. A cancelled fetch inside its
  /// grace window is *not* wanted: the grace only protects its queue
  /// position until a slot opens, not its right to start streaming.
  bool _wants(String url) {
    final fetch = _fetches[url];
    if (fetch == null) return false;
    return fetch.interests.isNotEmpty || fetch.streaming;
  }

  /// A foreground interest on a queued background fetch moves the waiter
  /// to the foreground lane.
  void _promote(_Fetch<T> fetch) {
    if (fetch.streaming || fetch.foreground) return;
    final waiter = _background.take(fetch.url);
    if (waiter == null) return;
    fetch.foreground = true;
    unawaited(_foreground.admit(waiter));
  }

  /// Removes a dead queued fetch: its lane admit future fails with
  /// [ImageFetchDropped], which unwinds [_run] without holding a permit.
  void _drop(_Fetch<T> fetch) {
    if (fetch.streaming || fetch.interests.isNotEmpty) return;
    final gate = fetch.foreground ? _foreground : _background;
    final waiter = gate.take(fetch.url);
    if (waiter != null) gate.drop(waiter);
  }

  Future<void> _run(_Fetch<T> fetch) async {
    final lane = fetch.foreground ? _foreground : _background;
    LanePermitGate? gate;
    try {
      gate = await lane.admit(fetch.waiter!);
      fetch.streaming = true;
      fetch.dropTimer?.cancel();
      fetch.dropTimer = null;
      final result = await execute(fetch.url, fetch.abort);
      for (final completer in _settle(fetch)) {
        completer.complete(result);
      }
    } on Object catch (error, stackTrace) {
      for (final completer in _settle(fetch)) {
        completer.completeError(error, stackTrace);
      }
    } finally {
      gate?.release();
      fetch.dropTimer?.cancel();
      if (identical(_fetches[fetch.url], fetch)) _fetches.remove(fetch.url);
    }
  }

  /// Detaches every interest still on [fetch] and returns their completers:
  /// a settled request id leaves the books, so a cancel that arrives after
  /// the result is a no-op instead of a second completion.
  List<Completer<T>> _settle(_Fetch<T> fetch) {
    final completers = [
      for (final (completer, _) in fetch.interests.values) completer,
    ];
    fetch.interests.keys.forEach(_interests.remove);
    fetch.interests.clear();
    return completers;
  }
}

class _Fetch<T> {
  _Fetch(this.url);

  final String url;

  /// Request ids waiting on this flight, each with its own completer so a
  /// cancel fails only the caller that left.
  final Map<int, (Completer<T>, ImageFetchPriority)> interests = {};
  LaneWaiter? waiter;
  Timer? dropTimer;
  var streaming = false;
  var foreground = false;
  final abort = _Abort();
}

class _Abort implements NetworkCancelSignal {
  final _cancelled = Completer<void>();

  @override
  bool get isCancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancel => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
