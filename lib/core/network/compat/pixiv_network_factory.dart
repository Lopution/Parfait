import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import 'network_contracts.dart';
import 'network_policy.dart';
import 'image_cache.dart';

/// A policy-aware `package:http` client. The business request is the route
/// attempt (PixEz-style): selection never pays for a separate probe. A
/// retryable undelivered failure walks the remaining unused kinds (ECH
/// first on a cold start; `insecureNoSni` always last). The request is
/// freshly cloned for each attempt because package:http requests are
/// single-use after finalize().
class PixivPolicyHttpClient extends http.BaseClient {
  PixivPolicyHttpClient({required this.policy, required this.purpose});

  final NetworkAccessPolicy policy;
  final PixivDestinationPurpose purpose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final destination = policy.registry.require(request.url, purpose);
    request.followRedirects = false;
    final replayFactory = _safeReplayFactory(request);
    final cancelSignal = _RequestCancelSignal.from(request);
    return policy.runLadder<http.StreamedResponse>(
      destination: destination,
      cancelSignal: cancelSignal,
      // canReplay carries operation idempotency, not cloneability: GET/HEAD
      // may retry on timeout too, while POST-family retries only when the
      // failure proves the request never reached the server.
      canReplay: request.method == 'GET' || request.method == 'HEAD',
      attempt: (route, url) async {
        // A clone is created for each attempt. package:http requests are
        // single-use after finalize(), so reusing one object would turn the
        // allowed retry into a local "already finalized" failure.
        final outbound = replayFactory?.call() ?? request;
        final response = await policy
            .clientFor(purpose, route, destination.canonicalHost)
            .send(outbound);
        if (response.statusCode >= 300 && response.statusCode < 400) {
          await response.stream.drain<void>();
          throw NetworkRedirectException(response.statusCode);
        }
        return response;
      },
    );
  }

  /// Builds a fresh clone for every attempt, so any request shape —
  /// including POST bodies such as the OAuth token exchange — can be
  /// re-sent on each unused kind the ladder still walks.
  static http.BaseRequest Function()? _safeReplayFactory(
    http.BaseRequest request,
  ) {
    if (request is! http.Request) return null;
    final headers = Map<String, String>.from(request.headers);
    final body = List<int>.from(request.bodyBytes);
    return () {
      final abortTrigger = request is http.AbortableRequest
          ? request.abortTrigger
          : null;
      final clone =
          http.AbortableRequest(
              request.method,
              request.url,
              abortTrigger: abortTrigger,
            )
            ..headers.addAll(headers)
            ..followRedirects = false
            ..maxRedirects = request.maxRedirects
            ..persistentConnection = request.persistentConnection
            ..bodyBytes = body;
      return clone;
    };
  }
}

class _RequestCancelSignal implements NetworkCancelSignal {
  _RequestCancelSignal(Future<void> trigger) {
    trigger.then<void>(
      (_) {
        _cancelled = true;
        if (!_completer.isCompleted) _completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        _cancelled = true;
        if (!_completer.isCompleted) _completer.complete();
      },
    );
  }

  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get whenCancel => _completer.future;

  static _RequestCancelSignal? from(http.BaseRequest request) {
    final trigger = request is http.AbortableRequest
        ? request.abortTrigger
        : null;
    return trigger == null ? null : _RequestCancelSignal(trigger);
  }
}

/// Shared app-scoped factory for API, OAuth, image cache and other strict
/// Pixiv HTTP consumers. The factory is the single place that can create a
/// policy client, making independent direct clients auditable.
class PixivNetworkFactory {
  PixivNetworkFactory(this.policy);

  final NetworkAccessPolicy policy;
  final Map<PixivDestinationPurpose, PixivPolicyHttpClient> _clients = {};
  late final PixivImageCache _imageCache = PixivImageCache(
    httpClient: client(PixivDestinationPurpose.image),
  );
  Future<void>? _warmupFuture;

  PixivPolicyHttpClient client(PixivDestinationPurpose purpose) {
    return _clients.putIfAbsent(
      purpose,
      () => PixivPolicyHttpClient(policy: policy, purpose: purpose),
    );
  }

  PixivPolicyHttpClient get apiClient => client(PixivDestinationPurpose.appApi);
  PixivPolicyHttpClient get oauthClient =>
      client(PixivDestinationPurpose.oauth);

  CacheManager get imageCacheManager => _imageCache.manager;

  /// Eagerly constructs the shared API/OAuth/image clients and their fast
  /// route pools. It is idempotent so callers can safely trigger it from the
  /// app lifecycle and from headless widget startup.
  Future<void> warmUp() {
    return _warmupFuture ??= () async {
      client(PixivDestinationPurpose.appApi);
      client(PixivDestinationPurpose.oauth);
      client(PixivDestinationPurpose.image);
      imageCacheManager;
      await policy.warmUp();
    }();
  }

  Future<void> dispose() async {
    await _imageCache.dispose();
    await policy.dispose();
  }
}
