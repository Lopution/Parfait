/// Wire contract between the main isolate and the background image worker.
///
/// Messages are plain `Map<String, Object?>` so they cross `SendPort`
/// without platform channels or shared objects. The worker receives one
/// [ImageWorkerConfig] snapshot at spawn (as the `Isolate.spawn` argument)
/// and may receive `config` messages afterwards when network settings or
/// the connectivity identity change.
library;

import 'dart:io' show File;
import 'dart:isolate' show SendPort;

import 'lane_permit_gate.dart';

/// Every knob the worker needs to rebuild the same `NetworkAccessPolicy`
/// and image-mirror rewrite the main isolate runs — nothing per-request
/// lives here.
class ImageWorkerConfig {
  const ImageWorkerConfig({
    required this.imageSource,
    this.autoWinnerHost,
    required this.mode,
    required this.networkIdentity,
    required this.echFrontHost,
    required this.dohEndpoints,
    required this.insecureNoSniEnabled,
    this.learnedFastRoutes = const {},
    this.routeKinds = const {},
  });

  /// Persisted `imageSource` setting (`i.pximg.net`, `auto`, a preset host
  /// or a normalized custom prefix). The worker resolves the
  /// `ImageMirror` the same way `imageMirrorProvider` does.
  final String imageSource;

  /// Last raced auto-source winner; meaningful only when [imageSource]
  /// is `auto`.
  final String? autoWinnerHost;

  /// `NetworkMode.name` — `automatic`, `directOnly` or `compatPrefer`.
  final String mode;

  /// Connectivity identity the shared policy keyed its route memory on;
  /// a change hands the worker a fresh policy revision.
  final String networkIdentity;

  /// HTTPS-RR query target for the ECH config, same setting the main
  /// policy reads.
  final String echFrontHost;

  /// DoH endpoint URLs in preference order; empty means DoH disabled and
  /// the worker's policy falls back to the system resolver.
  final List<String> dohEndpoints;

  /// Whether the compatibility transport tier is enabled; the app wiring
  /// always sets this, the flag is carried so the worker mirrors the
  /// wiring rather than hardcoding policy.
  final bool insecureNoSniEnabled;

  /// Persisted host→address map from the main isolate's fast-route store
  /// (learned entries only — the compile-time bootstrap map is readable
  /// inside the worker).
  final Map<String, String> learnedFastRoutes;

  /// Group→kind hints the main isolate's route-kind store kept for
  /// [networkIdentity].
  final Map<String, String> routeKinds;

  Map<String, Object?> toJson() => {
    'imageSource': imageSource,
    'autoWinnerHost': autoWinnerHost,
    'mode': mode,
    'networkIdentity': networkIdentity,
    'echFrontHost': echFrontHost,
    'dohEndpoints': dohEndpoints,
    'insecureNoSniEnabled': insecureNoSniEnabled,
    'learnedFastRoutes': learnedFastRoutes,
    'routeKinds': routeKinds,
  };

  static ImageWorkerConfig fromJson(Map<String, Object?> json) {
    return ImageWorkerConfig(
      imageSource: json['imageSource'] as String,
      autoWinnerHost: json['autoWinnerHost'] as String?,
      mode: json['mode'] as String,
      networkIdentity: json['networkIdentity'] as String,
      echFrontHost: json['echFrontHost'] as String,
      dohEndpoints: (json['dohEndpoints'] as List).cast<String>(),
      insecureNoSniEnabled: json['insecureNoSniEnabled'] as bool,
      learnedFastRoutes: (json['learnedFastRoutes'] as Map? ?? const {}).cast(),
      routeKinds: (json['routeKinds'] as Map? ?? const {}).cast(),
    );
  }
}

/// Main→worker: fetch [url] (the canonical, pre-rewrite URL) on [priority].
/// The worker coalesces by URL; [id] identifies this caller.
class FetchRequest {
  const FetchRequest(this.id, this.url, this.priority);

  final int id;
  final String url;
  final ImageFetchPriority priority;
}

/// Worker→main success: the body is committed at [file] — the main
/// isolate decodes through engine facilities (`ImmutableBuffer`) and
/// never touches bytes in Dart.
class FetchResult {
  const FetchResult(this.id, this.file, this.bytes);

  final int id;
  final File file;
  final int bytes;
}

/// The worker cannot serve requests: it failed to start, died, or was
/// disposed. Requests fail with this instead of falling back to the legacy
/// pipeline.
class ImageWorkerUnavailable implements Exception {
  const ImageWorkerUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'ImageWorkerUnavailable: $reason';
}

/// What an image provider needs from the worker: the committed file for a
/// URL.
abstract interface class ImageFetcher {
  Future<FetchResult> fetch(String url, {required ImageFetchPriority priority});
}

/// A point-in-time view of the worker's queue and disk cache, for the
/// probe page.
class ImageWorkerStatus {
  const ImageWorkerStatus({
    required this.inFlight,
    required this.queued,
    required this.diskEntries,
    required this.diskBytes,
    required this.diskMaxBytes,
  });

  /// Fetches holding a lane permit.
  final int inFlight;

  /// Fetches waiting for one.
  final int queued;

  final int diskEntries;
  final int diskBytes;
  final int diskMaxBytes;
}

/// Worker→main failure. [statusCode] is set for plain HTTP failures so
/// the UI can keep 403/404-no-retry and error-widget behavior identical
/// to the legacy path.
class FetchFailure implements Exception {
  const FetchFailure(this.id, this.message, {this.statusCode});

  final int id;
  final String message;
  final int? statusCode;

  /// A 404 means the image itself is gone — retrying cannot help.
  bool get isPermanent => statusCode == 404;

  @override
  String toString() => statusCode == null
      ? 'FetchFailure($id): $message'
      : 'FetchFailure($id, $statusCode): $message';
}

// --- Message shapes ------------------------------------------------------

/// Worker-side decode of downstream (main→worker) messages.
sealed class WorkerMessage {
  const WorkerMessage();
}

class FetchMessage extends WorkerMessage {
  const FetchMessage(this.request);
  final FetchRequest request;
}

class CancelMessage extends WorkerMessage {
  const CancelMessage(this.id);
  final int id;
}

class ConfigMessage extends WorkerMessage {
  const ConfigMessage(this.config);
  final ImageWorkerConfig config;
}

/// Promotes the queued fetch for [url] onto the foreground lane — the
/// demand layer's "this URL is on screen now" signal. A no-op when no
/// queued background fetch exists for the URL.
class PromoteMessage extends WorkerMessage {
  const PromoteMessage(this.url);
  final String url;
}

/// Starts ([watching]) or stops reporting download progress for [url].
/// Progress is a subscription by URL, not a property of a fetch: a widget
/// showing a progress ring may attach to a decode another caller started.
class WatchMessage extends WorkerMessage {
  const WatchMessage(this.url, {required this.watching});
  final String url;
  final bool watching;
}

/// Asks for an [ImageWorkerStatus]; [id] matches the reply.
class StatusMessage extends WorkerMessage {
  const StatusMessage(this.id);
  final int id;
}

/// Parses a raw wire map; unknown shapes throw so a protocol drift is loud.
WorkerMessage decodeWorkerMessage(Object? raw) {
  if (raw is! Map) throw StateError('worker message is not a map: $raw');
  switch (raw['type']) {
    case 'fetch':
      return FetchMessage(
        FetchRequest(
          raw['id'] as int,
          raw['url'] as String,
          ImageFetchPriority.values.byName(raw['priority'] as String),
        ),
      );
    case 'cancel':
      return CancelMessage(raw['id'] as int);
    case 'config':
      return ConfigMessage(
        ImageWorkerConfig.fromJson((raw['config'] as Map).cast()),
      );
    case 'promote':
      return PromoteMessage(raw['url'] as String);
    case 'status':
      return StatusMessage(raw['id'] as int);
    case 'watch':
      return WatchMessage(raw['url'] as String, watching: raw['on'] as bool);
  }
  throw StateError('unknown worker message type: ${raw['type']}');
}

Map<String, Object?> encodeFetch(FetchRequest request) => {
  'type': 'fetch',
  'id': request.id,
  'url': request.url,
  'priority': request.priority.name,
};

Map<String, Object?> encodeCancel(int id) => {'type': 'cancel', 'id': id};

Map<String, Object?> encodePromote(String url) => {
  'type': 'promote',
  'url': url,
};

Map<String, Object?> encodeStatusRequest(int id) => {
  'type': 'status',
  'id': id,
};

Map<String, Object?> encodeWatch(String url, {required bool watching}) => {
  'type': 'watch',
  'url': url,
  'on': watching,
};

Map<String, Object?> encodeConfig(ImageWorkerConfig config) => {
  'type': 'config',
  'config': config.toJson(),
};

// --- Upstream (worker→main) ----------------------------------------------

sealed class WorkerEvent {
  const WorkerEvent();
}

/// Initialization finished — the worker can now serve fetches. Sent once
/// after the spawn-time config is applied; carries the worker's own
/// inbox [sendPort] for downstream fetch/cancel/config messages.
class ReadyEvent extends WorkerEvent {
  const ReadyEvent(this.sendPort);
  final SendPort sendPort;
}

/// Initialization failed — rhttp could not load, the cache directory is
/// unusable, or policy construction threw. The client turns this into an
/// explicit error for every pending and future request.
class InitErrorEvent extends WorkerEvent {
  const InitErrorEvent(this.message);
  final String message;
}

class ResultEvent extends WorkerEvent {
  const ResultEvent(this.id, this.path, this.bytes);
  final int id;
  final String path;
  final int bytes;
}

/// [received] of [total] bytes of [url] have arrived; [total] is null when
/// the response declared no length. Sent only for watched URLs, throttled.
class ProgressEvent extends WorkerEvent {
  const ProgressEvent(this.url, this.received, this.total);
  final String url;
  final int received;
  final int? total;
}

class FailureEvent extends WorkerEvent {
  const FailureEvent(this.id, this.message, {this.statusCode});
  final int id;
  final String message;
  final int? statusCode;
}

/// A fast-route address the worker's policy learned — the main isolate
/// persists it into the real store so the next cold start keeps it.
class FastRouteLearnedEvent extends WorkerEvent {
  const FastRouteLearnedEvent(this.host, this.address);
  final String host;
  final String address;
}

/// A route-kind hint the worker's policy learned.
class RouteKindLearnedEvent extends WorkerEvent {
  const RouteKindLearnedEvent(this.networkIdentity, this.group, this.kind);
  final String networkIdentity;
  final String group;
  final String kind;
}

/// Every ladder tier on [host] was exhausted — forwarded from
/// `NetworkAccessPolicy.onImageHostExhausted` so the main isolate can drop
/// the auto-source winner and re-race, exactly like the legacy path.
class RouteExhaustedEvent extends WorkerEvent {
  const RouteExhaustedEvent(this.host);
  final String host;
}

Map<String, Object?> encodeWorkerEvent(WorkerEvent event) => switch (event) {
  ReadyEvent(:final sendPort) => {'type': 'ready', 'port': sendPort},
  InitErrorEvent(:final message) => {'type': 'initError', 'error': message},
  ResultEvent(:final id, :final path, :final bytes) => {
    'type': 'result',
    'id': id,
    'path': path,
    'bytes': bytes,
  },
  ProgressEvent(:final url, :final received, :final total) => {
    'type': 'progress',
    'url': url,
    'received': received,
    'total': total,
  },
  FailureEvent(:final id, :final message, :final statusCode) => {
    'type': 'failure',
    'id': id,
    'message': message,
    'statusCode': statusCode,
  },
  FastRouteLearnedEvent(:final host, :final address) => {
    'type': 'fastRouteLearned',
    'host': host,
    'address': address,
  },
  RouteKindLearnedEvent(:final networkIdentity, :final group, :final kind) => {
    'type': 'routeKindLearned',
    'networkIdentity': networkIdentity,
    'group': group,
    'kind': kind,
  },
  RouteExhaustedEvent(:final host) => {'type': 'routeExhausted', 'host': host},
  WorkerErrorEvent(:final message, :final stack) => {
    'type': 'workerError',
    'message': message,
    'stack': stack,
  },
  StatusEvent(:final id, :final status) => {
    'type': 'status',
    'id': id,
    'inFlight': status.inFlight,
    'queued': status.queued,
    'diskEntries': status.diskEntries,
    'diskBytes': status.diskBytes,
    'diskMaxBytes': status.diskMaxBytes,
  },
};

/// An error the worker caught at its message boundary instead of dying of
/// it; the main isolate records it in the crash log.
class WorkerErrorEvent extends WorkerEvent {
  const WorkerErrorEvent(this.message, this.stack);
  final String message;
  final String stack;
}

/// The answer to a [StatusMessage].
class StatusEvent extends WorkerEvent {
  const StatusEvent(this.id, this.status);
  final int id;
  final ImageWorkerStatus status;
}

/// Main-side decode of upstream messages.
WorkerEvent decodeWorkerEvent(Object? raw) {
  if (raw is! Map) throw StateError('worker event is not a map: $raw');
  return switch (raw['type']) {
    'ready' => ReadyEvent(raw['port'] as SendPort),
    'initError' => InitErrorEvent(raw['error'] as String),
    'result' => ResultEvent(
      raw['id'] as int,
      raw['path'] as String,
      raw['bytes'] as int,
    ),
    'progress' => ProgressEvent(
      raw['url'] as String,
      raw['received'] as int,
      raw['total'] as int?,
    ),
    'failure' => FailureEvent(
      raw['id'] as int,
      raw['message'] as String,
      statusCode: raw['statusCode'] as int?,
    ),
    'fastRouteLearned' => FastRouteLearnedEvent(
      raw['host'] as String,
      raw['address'] as String,
    ),
    'routeKindLearned' => RouteKindLearnedEvent(
      raw['networkIdentity'] as String,
      raw['group'] as String,
      raw['kind'] as String,
    ),
    'routeExhausted' => RouteExhaustedEvent(raw['host'] as String),
    'workerError' => WorkerErrorEvent(
      raw['message'] as String,
      raw['stack'] as String,
    ),
    'status' => StatusEvent(
      raw['id'] as int,
      ImageWorkerStatus(
        inFlight: raw['inFlight'] as int,
        queued: raw['queued'] as int,
        diskEntries: raw['diskEntries'] as int,
        diskBytes: raw['diskBytes'] as int,
        diskMaxBytes: raw['diskMaxBytes'] as int,
      ),
    ),
    _ => throw StateError('unknown worker event type: ${raw['type']}'),
  };
}
