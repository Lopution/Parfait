import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart';

import '../network/compat/network_contracts.dart';
import '../network/compat/network_policy.dart';
import '../network/compat/pixiv_network_factory.dart';
import '../network/compat/segmented_fetch.dart';
import '../network/pixiv_headers.dart';
import '../settings/image_mirror.dart';
import 'disk_image_cache.dart';
import 'image_fetch_scheduler.dart';
import 'image_worker_protocol.dart';
import 'lane_permit_gate.dart';
import 'worker_route_memory.dart';

/// A non-200 image response. The worker reports the status with its own
/// type and the client maps it onto `FetchFailure.statusCode`.
class ImageHttpStatus implements Exception {
  const ImageHttpStatus(this.statusCode, this.url);

  final int statusCode;
  final String url;

  @override
  String toString() => 'HTTP $statusCode for $url';
}

/// When a watched transfer's progress is worth a message: the first bytes
/// at once, then each further tenth of a known total, at most every
/// [interval]. Without a total only the first report goes out — the ring
/// can show no more than "loading" then. One instance per transfer.
class ImageProgressThrottle {
  ImageProgressThrottle({
    DateTime Function()? clock,
    this.interval = defaultInterval,
  }) : _clock = clock ?? DateTime.now;

  static const defaultInterval = Duration(milliseconds: 100);

  /// Reports per transfer at most: one per tenth (the screen reader reads
  /// the ring in tens).
  static const steps = 10;

  final DateTime Function() _clock;
  final Duration interval;
  DateTime? _lastAt;
  var _lastStep = 0;

  bool shouldReport(int received, int? total) {
    final now = _clock();
    final lastAt = _lastAt;
    final step = total == null || total <= 0 ? 0 : received * steps ~/ total;
    if (lastAt != null &&
        (step <= _lastStep || now.difference(lastAt) < interval)) {
      return false;
    }
    _lastAt = now;
    _lastStep = step;
    return true;
  }
}

/// Isolate entry point. Spawned with a map:
/// `{sendPort, config, cacheDir}`.
@pragma('vm:entry-point')
void imageWorkerEntry(Map<String, Object?> args) {
  final host = ImageWorkerHost(
    mainSendPort: args['sendPort'] as SendPort,
    config: ImageWorkerConfig.fromJson((args['config'] as Map).cast()),
    cacheDir: args['cacheDir'] as String,
  );
  host.run();
}

/// The orchestrator inside the image-worker isolate.
///
/// Owns, in order: the rhttp transport (initialized *inside* this isolate —
/// FRB runtimes are per-isolate), the [DiskImageCache], a
/// [NetworkAccessPolicy] rebuilt from the [ImageWorkerConfig] snapshot so
/// the ladder/DoH/ECH/mirror behavior matches the main isolate's, the
/// [PixivPolicyHttpClient] for the image purpose, and the
/// [ImageFetchScheduler] that all image traffic passes through.
///
/// The class is isolate-agnostic — it speaks to the main isolate through a
/// raw [SendPort] — so tests drive it directly without `Isolate.spawn`.
/// [transportInit] and [fetchClient] are the test seams at the transport
/// boundary: production defaults to `Rhttp.init` plus the real policy
/// client, and a test supplies a loopback `http.Client` and a no-op init.
class ImageWorkerHost {
  ImageWorkerHost({
    required this.mainSendPort,
    required this.config,
    required this.cacheDir,
    Future<void> Function()? transportInit,
    http.Client Function()? fetchClient,
    DateTime Function()? clock,
  }) : _transportInit = transportInit ?? Rhttp.init,
       _fetchClient = fetchClient,
       _clock = clock ?? DateTime.now;

  final SendPort mainSendPort;
  ImageWorkerConfig config;
  final String cacheDir;
  final Future<void> Function() _transportInit;
  final http.Client Function()? _fetchClient;
  final DateTime Function() _clock;

  final _inbox = ReceivePort();
  late final WorkerRouteMemoryState _routeMemoryState;
  late final WorkerFastRouteMemory _fastRoutes;
  late final WorkerRouteKindMemory _routeKinds;
  late final DiskImageCache _cache;
  late final ImageFetchScheduler<(File, int)> _scheduler;

  /// Requests between arrival and their scheduler submit (the disk lookup).
  final _lookingUp = <int>{};

  /// URLs whose download progress the main isolate shows.
  final _watched = <String>{};

  /// Extra connections for originals fetched in parallel ranges. The
  /// worker's own: a permit never crosses the isolate boundary. Three
  /// fill one original's [SegmentedFetch.defaultParallel] — the viewer
  /// usually fetches one at a time. Downloads keep their own budget.
  final _segmentBudget = SegmentBudget(limit: segmentLimit);
  static const segmentLimit = 3;

  /// Path marker of full-size originals, the only images worth splitting.
  static const _segmentedPath = '/img-original/';

  /// Transfers in parallel ranges still running; [close] ends them.
  final _segmentedFetches = <SegmentedFetch>{};

  NetworkAccessPolicy? _policy;
  http.Client? _imageClient;
  ImageMirror _mirror = ImageMirror.direct;
  Set<String> _allowlist = const {};
  var _closed = false;

  void _send(WorkerEvent event) => mainSendPort.send(encodeWorkerEvent(event));

  /// Listens for downstream messages, initializes, then announces readiness
  /// (or the init error) on the main port.
  Future<void> run() async {
    _inbox.listen(_handle);
    try {
      await _transportInit();
      _cache = DiskImageCache.open(Directory(cacheDir), clock: _clock);
      _routeMemoryState = _buildMemory(config);
      _applyConfig(config, initial: true);
      _scheduler = ImageFetchScheduler<(File, int)>(execute: _fetch);
      _send(ReadyEvent(_inbox.sendPort));
    } on Object catch (error) {
      // Explicit failure: the main isolate must see init fail, not wait
      // for a worker that never answers.
      _send(InitErrorEvent('$error'));
    }
  }

  /// Errors stop here: an uncaught one would kill the isolate and every
  /// image with it. They go upstream to the crash log instead — a config
  /// that failed to apply leaves the previous one in force, loudly.
  void _handle(Object? raw) {
    try {
      switch (decodeWorkerMessage(raw)) {
        case FetchMessage(:final request):
          unawaited(_serve(request));
        case CancelMessage(:final id):
          if (!_lookingUp.remove(id)) _scheduler.cancel(id);
        case PromoteMessage(:final url):
          _scheduler.promoteUrl(url);
        case WatchMessage(:final url, :final watching):
          watching ? _watched.add(url) : _watched.remove(url);
        case ConfigMessage(:final config):
          _applyConfig(config);
        case LookupMessage(:final id, :final url):
          unawaited(_lookup(id, url));
        case RoutesMessage(:final id):
          final routes = _policy?.effectiveRouteSnapshot() ?? const {};
          _send(
            RoutesEvent(id, {
              for (final MapEntry(:key, :value) in routes.entries)
                key: value.name,
            }),
          );
        case StatusMessage(:final id):
          _send(
            StatusEvent(
              id,
              ImageWorkerStatus(
                inFlight: _scheduler.inFlight,
                queued: _scheduler.queued,
                diskEntries: _cache.entryCount,
                diskBytes: _cache.totalBytes,
                diskMaxBytes: _cache.maxBytes,
              ),
            ),
          );
      }
    } on Object catch (error, stack) {
      _send(WorkerErrorEvent('$error', '$stack'));
    }
  }

  /// Answers whether [url] is on disk; never fetches it.
  Future<void> _lookup(int id, String url) async {
    try {
      final file = await _cache.lookup(url);
      _send(CachedEvent(id, file?.path));
    } on Object catch (error, stack) {
      // An unreadable cache is a miss to the caller, and a crash-log line.
      _send(CachedEvent(id, null));
      _send(WorkerErrorEvent('lookup $url: $error', '$stack'));
    }
  }

  /// A disk hit answers at once; only a miss queues for a lane permit, so
  /// cached images never wait behind network transfers.
  Future<void> _serve(FetchRequest request) async {
    _lookingUp.add(request.id);
    try {
      final cached = await _cache.lookup(request.url);
      // Cancelled during the lookup: a miss must not queue for nobody.
      if (!_lookingUp.remove(request.id)) return;
      final (file, bytes) = cached != null
          ? (cached, await cached.length())
          : await _scheduler.submit(
              request.id,
              request.url,
              priority: request.priority,
            );
      _send(ResultEvent(request.id, file.path, bytes));
    } on Object catch (error) {
      _lookingUp.remove(request.id);
      _reportFailure(request.id, error);
    }
  }

  WorkerRouteMemoryState _buildMemory(ImageWorkerConfig config) {
    final state = WorkerRouteMemoryState(
      learnedFastRoutes: config.learnedFastRoutes,
      routeKinds: config.routeKinds,
    );
    _fastRoutes = WorkerFastRouteMemory(
      state,
      onFastRouteLearned: (host, address) =>
          _send(FastRouteLearnedEvent(host, address)),
    );
    _routeKinds = WorkerRouteKindMemory(
      state,
      onRouteKindLearned: (identity, group, kind) =>
          _send(RouteKindLearnedEvent(identity, group, kind)),
    );
    return state;
  }

  /// Rebuilds whichever layer the changed config fields affect:
  ///
  /// - `networkIdentity` → `advanceNetworkRevision` on the live policy plus
  ///   a route-kind reseed (the new identity may have its own remembered
  ///   kinds); learned fast routes survive — they are bootstrap addresses,
  ///   not per-network.
  /// - resolver/policy inputs (mode, DoH endpoints, ECH host, allowlist)
  ///   → full policy rebuild, same as a provider rebuild on the main side.
  /// - `imageSource`/`autoWinnerHost` → mirror + client rewrite only; the
  ///   auto allowlist is the constant candidate set, so a winner flip is a
  ///   pure URL-rewrite change.
  void _applyConfig(ImageWorkerConfig next, {bool initial = false}) {
    final previous = config;
    config = next;
    _mirror = next.imageSource == 'auto'
        ? ImageMirror.auto(next.autoWinnerHost)
        : ImageMirror.of(next.imageSource);
    final allowlist = ImageMirror.of(next.imageSource).extraHosts;
    final policyInputsChanged =
        next.mode != previous.mode ||
        next.echFrontHost != previous.echFrontHost ||
        next.bootstrapNoSniEnabled != previous.bootstrapNoSniEnabled ||
        !_listEquals(next.dohEndpoints, previous.dohEndpoints) ||
        !_setEquals(allowlist, _allowlist);
    if (initial || policyInputsChanged) {
      unawaited(_policy?.dispose());
      _allowlist = allowlist;
      _policy = _buildPolicy(next, allowlist);
      _policy!.onImageHostExhausted = (host) =>
          _send(RouteExhaustedEvent(host));
    } else if (next.networkIdentity != previous.networkIdentity) {
      _policy!.advanceNetworkRevision(networkIdentity: next.networkIdentity);
      _routeMemoryState.reseed(
        learnedFastRoutes: next.learnedFastRoutes,
        routeKinds: next.routeKinds,
      );
    }
    _imageClient =
        _fetchClient?.call() ??
        PixivPolicyHttpClient(
          policy: _policy!,
          purpose: PixivDestinationPurpose.image,
          urlRewriter: _mirror.rewrite,
        );
  }

  NetworkAccessPolicy _buildPolicy(
    ImageWorkerConfig config,
    Set<String> allowlist,
  ) {
    return NetworkAccessPolicy(
      registry: PixivDestinationRegistry(extraImageHosts: allowlist),
      mode: NetworkMode.values.byName(config.mode),
      revision: NetworkRevision(0, networkIdentity: config.networkIdentity),
      echFrontHost: config.echFrontHost,
      bootstrapNoSniEnabled: config.bootstrapNoSniEnabled,
      fastRouteStore: _fastRoutes,
      routeKindStore: _routeKinds,
      dohEndpoints: config.dohEndpoints,
    );
  }

  /// The single admitted-flight body: one policy GET (an original: its
  /// ranges), then an atomic commit into the cache. Called by the scheduler
  /// only after the fetch holds its lane permit.
  Future<(File, int)> _fetch(String url) async {
    // A flight for the URL may have committed between this request's own
    // lookup and its submit; the re-check is a stat, the miss a download.
    final cached = await _cache.lookup(url);
    if (cached != null) {
      return (cached, await cached.length());
    }
    final uri = Uri.parse(url);
    final (body, segmented) = uri.path.contains(_segmentedPath)
        ? await _openInRanges(uri)
        : (await _wholeBody(await _request(uri), uri), null);
    if (segmented != null) _segmentedFetches.add(segmented);
    try {
      final file = await _cache.store(
        url,
        _reportingProgress(url, body.stream, body.length),
        expectedLength: body.length,
      );
      return (file, body.length ?? await file.length());
    } finally {
      _segmentedFetches.remove(segmented);
    }
  }

  /// An original file: its first range, then the rest in parallel ranges
  /// when the server answers a sized 206 from byte 0. A 200 (`Range`
  /// ignored) is the whole file; anything else fails like any image. The
  /// worker sends no conditional headers, so every range asks the same.
  Future<(_Body, SegmentedFetch?)> _openInRanges(Uri uri) async {
    final first = await _request(
      uri,
      range: (0, SegmentedFetch.defaultSegmentBytes - 1),
    );
    final range = parseContentRange(first.headers['content-range']);
    final total = range?.total;
    if (first.statusCode != 206 ||
        range == null ||
        range.start != 0 ||
        total == null) {
      return (await _wholeBody(first, uri), null);
    }
    if (range.end + 1 >= total) {
      return ((stream: first.stream, length: total), null);
    }
    final segmented = SegmentedFetch(
      open: (start, end, {ifRange, required cancel}) async =>
          RangeResponse.fromHttp(
            await _request(
              uri,
              range: (start, end),
              ifRange: ifRange,
              cancel: cancel,
            ),
          ),
      budget: _segmentBudget,
    );
    final body = segmented.continueFrom(RangeResponse.fromHttp(first));
    return ((stream: body, length: total), segmented);
  }

  Future<http.StreamedResponse> _request(
    Uri uri, {
    (int, int)? range,
    String? ifRange,
    NetworkCancelSignal? cancel,
  }) {
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: cancel?.whenCancel,
    )..headers.addAll(PixivHeaders.image());
    if (range case (final start, final end)) {
      request.headers['range'] = 'bytes=$start-$end';
    }
    if (ifRange != null) request.headers['if-range'] = ifRange;
    return _imageClient!.send(request);
  }

  /// [response]'s body when it is the whole file; any other status fails
  /// the fetch with it.
  static Future<_Body> _wholeBody(
    http.StreamedResponse response,
    Uri uri,
  ) async {
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw ImageHttpStatus(response.statusCode, '$uri');
    }
    return (stream: response.stream, length: response.contentLength);
  }

  /// [body] with throttled progress reports while [url] is watched. The
  /// watch is read per chunk, so a ring that appears mid-transfer starts
  /// reporting with the next bytes.
  Stream<List<int>> _reportingProgress(
    String url,
    Stream<List<int>> body,
    int? total,
  ) {
    final throttle = ImageProgressThrottle(clock: _clock);
    var received = 0;
    return body.map((chunk) {
      received += chunk.length;
      if (_watched.contains(url) && throttle.shouldReport(received, total)) {
        _send(ProgressEvent(url, received, total));
      }
      return chunk;
    });
  }

  void _reportFailure(int id, Object error) {
    if (_closed) return;
    switch (error) {
      case ImageFetchDropped():
        return; // caller left on its own — nothing to report
      case ImageHttpStatus(:final statusCode):
        _send(FailureEvent(id, '$error', statusCode: statusCode));
      default:
        _send(FailureEvent(id, '$error'));
    }
  }

  // Tests drive the host in-process and tear it down through close().
  // ignore: unreachable_from_main
  Future<void> close() async {
    _closed = true;
    _inbox.close();
    for (final segmented in List.of(_segmentedFetches)) {
      segmented.close();
    }
    await _policy?.dispose();
  }
}

/// A response body and its length, when the server declared one.
typedef _Body = ({Stream<List<int>> stream, int? length});

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _setEquals<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);
