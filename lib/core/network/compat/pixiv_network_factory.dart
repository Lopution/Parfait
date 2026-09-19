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
  PixivPolicyHttpClient({
    required this.policy,
    required this.purpose,
    this.urlRewriter,
  });

  final NetworkAccessPolicy policy;
  final PixivDestinationPurpose purpose;

  /// Optional request-URL mapping applied before destination resolution
  /// (image-source mirroring). When it returns the same [Uri] instance the
  /// request is sent as-is; a different URL retargets the request so the
  /// route ladder, client pool and socket all key on the mirror host.
  final Uri Function(Uri url)? urlRewriter;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final targetUrl = urlRewriter?.call(request.url) ?? request.url;
    final destination = policy.registry.require(targetUrl, purpose);
    final retargeted = identical(targetUrl, request.url)
        ? request
        : _cloneWithUrl(request, targetUrl);
    retargeted.followRedirects = false;
    final replayFactory = _safeReplayFactory(retargeted);
    final cancelSignal = _RequestCancelSignal.from(request);
    return policy.runLadder<http.StreamedResponse>(
      destination: destination,
      cancelSignal: cancelSignal,
      // canReplay carries operation idempotency, not cloneability: GET/HEAD
      // may retry on timeout too, while POST-family retries only when the
      // failure proves the request never reached the server.
      canReplay: request.method == 'GET' || request.method == 'HEAD',
      // A cold image host pays each candidate tier's timeout in series;
      // racing the top two turns that into one round trip for the waterfall's
      // first paint. API/OAuth stays serial — duplicate reads are free for
      // the CDN, not for the app backend.
      raceWhenCold:
          purpose == PixivDestinationPurpose.image &&
          (request.method == 'GET' || request.method == 'HEAD'),
      attempt: (route, url) async {
        // A clone is created for each attempt. package:http requests are
        // single-use after finalize(), so reusing one object would turn the
        // allowed retry into a local "already finalized" failure.
        final outbound = replayFactory?.call() ?? retargeted;
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

  /// Re-targets [request] to [url]. Only [http.Request] is clonable; any
  /// other request type reaching this path with a *changed* URL is a
  /// wiring error (the image cache only ever sends plain Requests), so it
  /// fails loudly instead of silently fetching the un-mirrored host.
  static http.BaseRequest _cloneWithUrl(http.BaseRequest request, Uri url) {
    if (request is! http.Request) {
      if (request.url == url) return request;
      throw StateError(
        'cannot re-target ${request.runtimeType} to a rewritten URL',
      );
    }
    final headers = Map<String, String>.from(request.headers);
    final body = List<int>.from(request.bodyBytes);
    final abortTrigger = request is http.AbortableRequest
        ? request.abortTrigger
        : null;
    return http.AbortableRequest(
        request.method,
        url,
        abortTrigger: abortTrigger,
      )
      ..headers.addAll(headers)
      ..followRedirects = false
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..bodyBytes = body;
  }

  /// Builds a fresh clone for every attempt, so any request shape —
  /// including POST bodies such as the OAuth token exchange — can be
  /// re-sent on each unused kind the ladder still walks.
  static http.BaseRequest Function()? _safeReplayFactory(
    http.BaseRequest request,
  ) {
    if (request is! http.Request) return null;
    return () => _cloneWithUrl(request, request.url);
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
  /// [imageUrlRewriter] mirrors `i./s.pximg.net` URLs onto the selected
  /// image source before destination resolution; null/identity keeps the
  /// stock pximg path.
  PixivNetworkFactory(this.policy, {this.imageUrlRewriter});

  final NetworkAccessPolicy policy;
  final Uri Function(Uri url)? imageUrlRewriter;
  final Map<PixivDestinationPurpose, PixivPolicyHttpClient> _clients = {};
  // CacheManager keeps its HttpFileService for the lifetime of the cache.
  // NetworkAccessPolicy intentionally closes pooled clients when the account
  // or network revision changes, so handing the manager a concrete client
  // would leave every later image request using a closed socket pool (the
  // post-first-login all-grey screen). The proxy resolves the current image
  // client for each request and therefore survives a policy revision while
  // retaining decoded/file cache entries.
  late final PixivImageCache _imageCache = PixivImageCache(
    httpClient: _ImageClientProxy(this),
  );
  Future<void>? _warmupFuture;

  PixivPolicyHttpClient client(PixivDestinationPurpose purpose) {
    return _clients.putIfAbsent(
      purpose,
      () => PixivPolicyHttpClient(
        policy: policy,
        purpose: purpose,
        urlRewriter: purpose == PixivDestinationPurpose.image
            ? imageUrlRewriter
            : null,
      ),
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

class _ImageClientProxy extends http.BaseClient {
  _ImageClientProxy(this.owner);

  final PixivNetworkFactory owner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return owner.client(PixivDestinationPurpose.image).send(request);
  }
}
