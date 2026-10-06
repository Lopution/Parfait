import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart';

import '../network/compat/network_contracts.dart';
import '../network/compat/network_policy.dart';
import '../network/compat/pixiv_network_factory.dart';
import '../network/pixiv_headers.dart';
import '../settings/image_mirror.dart';
import 'disk_image_cache.dart';
import 'image_fetch_scheduler.dart';
import 'image_worker_protocol.dart';
import 'lane_permit_gate.dart';
import 'worker_route_memory.dart';

/// A non-200 image response. `package:http`'s `HttpException` variants live
/// in flutter_cache_manager (which the worker must not depend on), so the
/// worker reports the status with its own type and the client maps it back
/// onto `FetchFailure.statusCode`.
class ImageHttpStatus implements Exception {
  const ImageHttpStatus(this.statusCode, this.url);

  final int statusCode;
  final String url;

  @override
  String toString() => 'HTTP $statusCode for $url';
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
      // Explicit failure per the rewrite contract: the main isolate must
      // see init fail, not silently continue on the legacy stack.
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
        case ConfigMessage(:final config):
          _applyConfig(config);
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
        next.insecureNoSniEnabled != previous.insecureNoSniEnabled ||
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
      insecureNoSniEnabled: config.insecureNoSniEnabled,
      fastRouteStore: _fastRoutes,
      routeKindStore: _routeKinds,
      dohEndpoints: config.dohEndpoints,
    );
  }

  /// The single admitted-flight body: one policy GET, then an atomic commit
  /// into the cache. Called by the scheduler only after the fetch holds its
  /// lane permit.
  Future<(File, int)> _fetch(String url) async {
    // A flight for the URL may have committed between this request's own
    // lookup and its submit; the re-check is a stat, the miss a download.
    final cached = await _cache.lookup(url);
    if (cached != null) {
      return (cached, await cached.length());
    }
    final request = http.Request('GET', Uri.parse(url))
      ..headers.addAll(PixivHeaders.image());
    final response = await _imageClient!.send(request);
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw ImageHttpStatus(response.statusCode, url);
    }
    final file = await _cache.store(
      url,
      response.stream,
      expectedLength: response.contentLength,
    );
    return (file, response.contentLength ?? await file.length());
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
    await _policy?.dispose();
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _setEquals<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);
