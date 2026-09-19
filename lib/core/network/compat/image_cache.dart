import 'dart:async';
import 'dart:collection';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

class PixivImageCache {
  PixivImageCache({required this.httpClient});

  final http.Client httpClient;
  CacheManager? _manager;

  CacheManager get manager {
    return _manager ??= CacheManager(
      Config(
        'pixiv_func_images',
        // The default 200-entry cap evicts a scrolled-past waterfall long
        // before its disk footprint matters; ~1500 previews stay around a
        // hundred MB, which is the point of having a disk cache.
        maxNrOfCacheObjects: 1500,
        fileService: PriorityFileService(httpClient: httpClient),
      ),
    );
  }

  Future<void> dispose() async {
    final cache = _manager;
    _manager = null;
    if (cache != null) {
      // flutter_cache_manager 3.4.x cannot close an as-yet-unopened JSON
      // repository. Opening it explicitly also makes provider-container
      // teardown deterministic in widget tests and during app shutdown.
      await cache.store.retrieveCacheData('pixiv_func_lifecycle_probe');
      await cache.dispose();
    }
  }
}

/// Splits fetch concurrency between on-screen loads and prefetch warmers on
/// the same disk store. `WebHelper` gates on [FileService.concurrentFetches]
/// — a single FIFO — so a full prefetch window could occupy every slot and
/// make a just-scrolled-into-view image queue behind warm work. The marker
/// header is injected by `PixivImage.preload` and stripped here before the
/// request hits the wire; everything else takes the foreground lane.
///
/// A permit is held for the whole transfer, not just the header wait:
/// WebHelper counts a call as in-flight until the response body has been
/// consumed, so releasing at headers would let prefetch bodies still fill
/// the shared queue. `WebHelper` may legitimately never listen to `content`
/// (304/error paths), so a generous [_holdLimit] releases a permit that the
/// response stream did not — bounded over-admission beats a lane leak.
class PriorityFileService extends FileService {
  PriorityFileService({required http.Client httpClient})
    : _service = HttpFileService(httpClient: httpClient) {
    // The outer WebHelper queue must admit both lanes' worth of work; the
    // gates below do the real prioritisation.
    concurrentFetches = foregroundSlots + backgroundSlots;
  }

  /// Header marking a fetch as prefetch traffic. Stripped in [get], so it
  /// is a scheduling hint only and never leaves the device.
  static const prefetchMarker = 'x-pixiv-func-prefetch';

  static const foregroundSlots = 8;
  static const backgroundSlots = 3;

  /// Upper bound on how long one transfer may hold a lane permit. It only
  /// fires when the body stream was abandoned — normal bodies release the
  /// permit on termination well before this.
  static const _holdLimit = Duration(seconds: 45);

  final HttpFileService _service;
  final _PermitGate _foreground = _PermitGate(foregroundSlots);
  final _PermitGate _background = _PermitGate(backgroundSlots);

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final prefetch = headers?[prefetchMarker] == '1';
    // Copy rather than `remove` on the caller's map — WebHelper reuses its
    // header map for queued retries.
    final outbound = prefetch
        ? (Map<String, String>.of(headers!)..remove(prefetchMarker))
        : headers;
    final gate = prefetch ? _background : _foreground;
    await gate.acquire();
    try {
      final response = await _service.get(url, headers: outbound);
      return _GatedResponse(response, gate.release, _holdLimit);
    } on Object {
      gate.release();
      rethrow;
    }
  }
}

class _PermitGate {
  _PermitGate(this._slots);

  final int _slots;
  var _inFlight = 0;
  final _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_inFlight < _slots) {
      _inFlight++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    final next = _waiters.isEmpty ? null : _waiters.removeFirst();
    if (next == null) {
      _inFlight--;
    } else {
      // The slot passes to the waiter without dipping _inFlight.
      next.complete();
    }
  }
}

/// Forwards a [FileServiceResponse], wrapping [content] so the lane permit
/// is released exactly once — on stream termination/cancel or when the
/// hold limit fires for a stream nobody consumed.
class _GatedResponse implements FileServiceResponse {
  _GatedResponse(this._inner, this._release, Duration holdLimit) {
    _holdTimer = Timer(holdLimit, _releaseOnce);
  }

  final FileServiceResponse _inner;
  final void Function() _release;
  late final Timer _holdTimer;
  var _released = false;

  void _releaseOnce() {
    if (_released) return;
    _released = true;
    _holdTimer.cancel();
    _release();
  }

  /// Forwards the source subscription directly rather than through a
  /// StreamController — controller-based wrappers never deliver under
  /// `testWidgets`' FakeAsync loop (same constraint as the image idle
  /// guard in `network_policy.dart`).
  @override
  Stream<List<int>> get content =>
      _ReleaseOnEndStream(_inner.content, _releaseOnce);

  @override
  int? get contentLength => _inner.contentLength;

  @override
  int get statusCode => _inner.statusCode;

  @override
  DateTime get validTill => _inner.validTill;

  @override
  String? get eTag => _inner.eTag;

  @override
  String get fileExtension => _inner.fileExtension;
}

class _ReleaseOnEndStream extends Stream<List<int>> {
  _ReleaseOnEndStream(this._source, this._onEnd);

  final Stream<List<int>> _source;
  final void Function() _onEnd;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    late StreamSubscription<List<int>> sub;
    sub = _source.listen(
      onData,
      onError: (Object error, StackTrace stack) {
        _onEnd();
        final handler = onError;
        if (handler is void Function(Object, StackTrace)) {
          handler(error, stack);
        } else if (handler is void Function(Object)) {
          handler(error);
        }
      },
      onDone: () {
        _onEnd();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
    return _ReleasingSubscription(sub, _onEnd);
  }
}

/// Cancelling the body (an abandoned prefetch, a disposed card) also frees
/// the lane — the subscription is the last thing holding it.
class _ReleasingSubscription implements StreamSubscription<List<int>> {
  _ReleasingSubscription(this._inner, this._onEnd);

  final StreamSubscription<List<int>> _inner;
  final void Function() _onEnd;

  @override
  Future<void> cancel() {
    _onEnd();
    return _inner.cancel();
  }

  @override
  void onData(void Function(List<int> event)? handleData) =>
      _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
}
