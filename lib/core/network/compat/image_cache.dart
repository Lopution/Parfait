import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import '../../image/lane_permit_gate.dart';
import 'image_demand.dart';
import 'network_contracts.dart';
import 'segmented_fetch.dart';

export '../../image/lane_permit_gate.dart' show ImageFetchPriority;

class PixivImageCache {
  PixivImageCache({required this.httpClient, this.segmentBudget});

  final http.Client httpClient;

  /// Extra connections for originals fetched in parallel ranges; null
  /// fetches every image on one connection.
  final SegmentBudget? segmentBudget;

  /// Who waits for which image: image widgets and prefetchers register
  /// here, the file service reads it.
  final demand = ImageDemand();
  CacheManager? _manager;

  CacheManager get manager {
    return _manager ??= CacheManager(
      Config(
        'parfait_images',
        // The default 200-entry cap evicts a scrolled-past waterfall long
        // before its disk footprint matters; ~1500 previews stay around a
        // hundred MB, which is the point of having a disk cache.
        maxNrOfCacheObjects: 1500,
        fileService: _fileService(),
      ),
    );
  }

  PriorityFileService _fileService() {
    final service = PriorityFileService(
      httpClient: httpClient,
      demand: demand,
      segmentBudget: segmentBudget,
    );
    demand.onHeld = service.promote;
    return service;
  }

  Future<void> dispose() async {
    final cache = _manager;
    _manager = null;
    if (cache != null) {
      // flutter_cache_manager 3.4.x cannot close an as-yet-unopened JSON
      // repository. Opening it explicitly also makes provider-container
      // teardown deterministic in widget tests and during app shutdown.
      await cache.store.retrieveCacheData('parfait_lifecycle_probe');
      await cache.dispose();
    }
  }
}

/// [FileService.concurrentFetches] value that keeps `WebHelper` from
/// queueing anything itself.
const _kWebHelperAdmitAll = 1 << 20;

/// Splits fetch concurrency between on-screen loads and prefetch warmers on
/// the same disk store. The marker header is injected by `PixivImage.preload`
/// and stripped here before the request hits the wire; everything else takes
/// the foreground lane.
///
/// `WebHelper` has its own queue in front of this service, a single FIFO
/// gated on [FileService.concurrentFetches]. With any finite limit there, a
/// burst of prefetch fills it and a just-scrolled-into-view image waits
/// behind all of them before it even reaches the lanes. So `WebHelper`
/// admits everything and the two gates below decide what goes on the wire.
///
/// `WebHelper` also merges requests for the same URL: a visible image whose
/// URL is already queued as prefetch never reaches this service on its own.
/// [promote] moves that queued prefetch onto the foreground lane.
///
/// When a queued fetch reaches its turn and [ImageDemand] says nobody wants
/// its URL any more, it fails with [ImageFetchDropped] instead of taking
/// the slot. A transfer that already started is never interrupted: its
/// bytes are on the way and the file will serve the next visit.
///
/// A permit is held for the whole transfer, not just the header wait, so a
/// lane's slot count is the number of bodies streaming at once. `WebHelper`
/// may legitimately never listen to `content` (304/error paths), so a
/// generous [_holdLimit] releases a permit that the response stream did
/// not — bounded over-admission beats a lane leak.
///
/// Originals (`/img-original/`) with a [SegmentBudget] are fetched in
/// parallel byte ranges ([SegmentedFetch]) behind the same single permit;
/// `WebHelper` still sees one in-order 200 of the full length.
class PriorityFileService extends FileService {
  /// Without a [demand], queued fetches are never dropped. Without a
  /// [segmentBudget], originals use one connection like everything else.
  PriorityFileService({
    required http.Client httpClient,
    ImageDemand? demand,
    SegmentBudget? segmentBudget,
  }) : _httpClient = httpClient,
       _segmentBudget = segmentBudget,
       _service = HttpFileService(httpClient: httpClient),
       _foreground = LanePermitGate(foregroundSlots, demand?.wants),
       _background = LanePermitGate(backgroundSlots, demand?.wants) {
    concurrentFetches = _kWebHelperAdmitAll;
  }

  /// Header marking a fetch as prefetch traffic. Stripped in [get], so it
  /// is a scheduling hint only and never leaves the device.
  static const prefetchMarker = 'x-parfait-prefetch';

  static const foregroundSlots = 8;

  /// Kept small so prefetch never competes with visible images for the
  /// connection pool or bandwidth.
  static const backgroundSlots = 2;

  /// Upper bound on how long one transfer may hold a lane permit. It only
  /// fires when the body stream was abandoned — normal bodies release the
  /// permit on termination well before this.
  static const _holdLimit = Duration(seconds: 45);

  /// Path marker of full-size originals, the only images worth splitting.
  static const segmentedPath = '/img-original/';

  /// Conditional headers belong to the first range only: a 304 for a
  /// later segment could not be stitched in.
  static const _conditionalHeaders = {'if-none-match', 'if-modified-since'};

  final http.Client _httpClient;
  final SegmentBudget? _segmentBudget;
  final HttpFileService _service;
  final LanePermitGate _foreground;
  final LanePermitGate _background;

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
    // A promoted request is admitted by the foreground gate and must give
    // its slot back there, so the response remembers the admitting gate.
    final gate = await (prefetch ? _background : _foreground).acquire(url);
    try {
      final response = await _fetch(url, outbound);
      return _GatedResponse(response, gate.release, _holdLimit);
    } on Object {
      gate.release();
      rethrow;
    }
  }

  Future<FileServiceResponse> _fetch(
    String url,
    Map<String, String>? headers,
  ) async {
    final budget = _segmentBudget;
    final uri = Uri.parse(url);
    if (budget == null || !uri.path.contains(segmentedPath)) {
      return _service.get(url, headers: headers);
    }
    final first = await _sendRange(
      uri,
      headers ?? const {},
      0,
      SegmentedFetch.defaultSegmentBytes - 1,
    );
    final range = parseContentRange(first.headers['content-range']);
    final total = range?.total;
    // A 200 (Range ignored), 304 or error goes to WebHelper unchanged.
    if (first.statusCode != 206 || range == null || total == null) {
      return HttpGetResponse(first);
    }
    final segmentHeaders = {
      for (final entry in (headers ?? const <String, String>{}).entries)
        if (!_conditionalHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
    final body = range.end + 1 >= total
        ? first.stream
        : SegmentedFetch(
            open: (start, end, {ifRange, required cancel}) async =>
                _rangeResponse(
                  await _sendRange(
                    uri,
                    segmentHeaders,
                    start,
                    end,
                    ifRange: ifRange,
                    cancel: cancel,
                  ),
                ),
            budget: budget,
          ).continueFrom(_rangeResponse(first));
    return HttpGetResponse(
      http.StreamedResponse(
        body,
        200,
        contentLength: total,
        request: first.request,
        headers: {
          for (final entry in first.headers.entries)
            if (entry.key != 'content-range') entry.key: entry.value,
          'content-length': '$total',
        },
      ),
    );
  }

  Future<http.StreamedResponse> _sendRange(
    Uri uri,
    Map<String, String> headers,
    int start,
    int end, {
    String? ifRange,
    NetworkCancelSignal? cancel,
  }) {
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: cancel?.whenCancel)
          ..headers.addAll(headers)
          ..headers['range'] = 'bytes=$start-$end';
    if (ifRange != null) request.headers['if-range'] = ifRange;
    return _httpClient.send(request);
  }

  static RangeResponse _rangeResponse(http.StreamedResponse response) =>
      RangeResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.stream,
        close: () async {
          try {
            // An unread body still holds the connection.
            await response.stream.listen(null).cancel();
          } on StateError {
            // Already listened to: its subscriber tears it down.
          }
        },
      );

  /// Moves a queued prefetch of [url] to the foreground lane: admitted at
  /// once when a foreground slot is free, otherwise queued behind the
  /// visible loads. A prefetch already streaming is left alone.
  void promote(String url) {
    final waiter = _background.take(url);
    if (waiter != null) _foreground.admit(waiter);
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
    final sub = _source.listen(onData, cancelOnError: cancelOnError);
    return _ReleasingSubscription(sub, _onEnd)
      ..onError(onError)
      ..onDone(onDone);
  }
}

/// Ending or cancelling the body (an abandoned prefetch, a disposed card)
/// frees the lane — the subscription is the last thing holding it. Handlers
/// set later through [onError]/[onDone] (as `drain` and `asFuture` do) keep
/// the release, too.
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
  void onError(Function? handleError) {
    _inner.onError((Object error, StackTrace stack) {
      _onEnd();
      if (handleError is void Function(Object, StackTrace)) {
        handleError(error, stack);
      } else if (handleError is void Function(Object)) {
        handleError(error);
      } else {
        // Same as a subscription without an error handler.
        Zone.current.handleUncaughtError(error, stack);
      }
    });
  }

  @override
  void onDone(void Function()? handleDone) {
    _inner.onDone(() {
      _onEnd();
      handleDone?.call();
    });
  }

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  /// Routed through [onDone]/[onError] above; delegating to the inner
  /// subscription's `asFuture` would replace the releasing handlers.
  @override
  Future<E> asFuture<E>([E? futureValue]) {
    final completer = Completer<E>();
    onDone(() => completer.complete(futureValue as E));
    onError((Object error, StackTrace stack) {
      unawaited(cancel());
      completer.completeError(error, stack);
    });
    return completer.future;
  }
}
