part of 'network_policy.dart';

/// Idempotent requests may retry on timeout too — repeating a read is safe.
const Set<NetworkFailureKind> _replayEligibleKinds = {
  NetworkFailureKind.dns,
  NetworkFailureKind.connect,
  NetworkFailureKind.timeout,
  NetworkFailureKind.reset,
  NetworkFailureKind.tlsHandshake,
};

/// Non-idempotent requests advance only when the failure proves the request
/// never reached the server, so a delivered request is never repeated.
const Set<NetworkFailureKind> _unsentEligibleKinds = {
  NetworkFailureKind.dns,
  NetworkFailureKind.connect,
  NetworkFailureKind.reset,
  NetworkFailureKind.tlsHandshake,
};

/// A Cloudflare address that served the ECH front from Hong Kong where the
/// fronts the ECH config names were routed to Los Angeles (Unicom,
/// 2026-11-03): pixiv's image hosts always have it as a candidate.
final _kSeedEchFront = InternetAddress('162.159.152.4');

/// ECH candidates per image host: the config's fronts, then the seed.
const _kMaxEchCandidates = 4;

extension NetworkAccessPolicyLadder on NetworkAccessPolicy {
  /// The single route ladder shared by the API, OAuth, image and download
  /// exits.
  ///
  /// Attempt-first: the business request itself is the route
  /// attempt, so no credential-free probe round trip is paid before data. If
  /// the attempt fails with a transport-level error that proves the request
  /// was never delivered, the ladder walks the remaining unused kinds (ECH
  /// first on a cold start; pixiv's image hosts by score) and sends each
  /// unused kind at most once.
  /// [canReplay] selects the retry set: idempotent GET/HEAD/downloads also
  /// retry on timeout (a repeat is safe), while POST-family and the token
  /// exchange retry only on delivery-proven failures (DNS, connect, reset,
  /// TLS handshake), so a request that may have reached the server (HTTP
  /// response, timeout after send) is never repeated. A [background]
  /// request (a prefetch) to pixiv's image hosts may explore a candidate
  /// route no recent load has tried; a [pin] keeps the ranges of one of
  /// their transfers on one route.
  Future<T> runLadder<T>({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required bool canReplay,
    required FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
    bool raceWhenCold = false,
    bool background = false,
    ImageRoutePin? pin,
  }) async {
    _checkUsable();
    final host = destination.canonicalHost;
    if (localNetworkBlockedHosts.contains(host)) {
      throw LocalNetworkBlocked(host);
    }
    // First request after a cold start waits for the Rust transport; this
    // keeps `main` free to render the boot before rhttp finishes loading.
    final rhttpReady = RhttpGate.ready;
    if (rhttpReady != null) await rhttpReady;
    try {
      return await _runAttemptLadder<T>(
        destination: destination,
        cancelSignal: cancelSignal,
        canReplay: canReplay,
        attempt: attempt,
        raceWhenCold: raceWhenCold,
        background: background,
        pin: _isPixivImage(destination) ? pin : null,
      );
    } on Object {
      // A mirror/auto-source host that exhausted every tier is reported so
      // the auto source selection can drop the dead winner — the original
      // error still propagates to the caller unchanged.
      if (destination.purpose == PixivDestinationPurpose.image) {
        if (host != 'i.pximg.net' && host != 's.pximg.net') {
          onImageHostExhausted?.call(host);
        }
      }
      rethrow;
    }
  }

  /// Sends the business request on the selected route and, on a retryable
  /// transport failure, walks the remaining unused kinds. Each tier is
  /// attempted at most once; a delivered outcome (HTTP response, timeout
  /// after send, auth/parse error) never moves on, so a non-idempotent
  /// request can only be repeated when every earlier failure proved the
  /// request never reached the server.
  Future<T> _runAttemptLadder<T>({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required bool canReplay,
    required FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
    required bool raceWhenCold,
    required bool background,
    required ImageRoutePin? pin,
  }) async {
    final host = destination.canonicalHost;
    final pinned = pin?.route != null;
    final attemptedKeys = <String>{};
    final attemptedKinds = <NetworkRouteKind>{};
    // Shared by every tier and selection of this request, failure
    // included: a DoH lookup that cannot connect costs its timeouts once.
    // A network change mid-request looks the host up again.
    Future<ResolvedHost>? pendingResolve;
    int? pendingRevision;
    Future<ResolvedHost> resolveHost() {
      if (pendingRevision != _revision.value) {
        pendingRevision = _revision.value;
        pendingResolve = resolve(destination, cancelSignal: cancelSignal);
      }
      return pendingResolve!;
    }

    var useMemory = true;
    var explore = background;
    // Pixiv's own image hosts never race: a first-byte race says nothing
    // of the body, which is where their routes differ (see
    // [ImageRouteScores]).
    if (canReplay && raceWhenCold && !_isPixivImage(destination)) {
      final (raced, value) = await _raceColdTiers<T>(
        destination: destination,
        cancelSignal: cancelSignal,
        attempt: attempt,
        attemptedKeys: attemptedKeys,
        attemptedKinds: attemptedKinds,
        resolveHost: resolveHost,
      );
      if (raced) return value as T;
      useMemory = false;
    }
    while (true) {
      NetworkRoute route;
      try {
        route = await _selectRoute(
          destination: destination,
          cancelSignal: cancelSignal,
          attemptedKeys: attemptedKeys,
          attemptedKinds: attemptedKinds,
          resolveHost: resolveHost,
          useMemory: useMemory,
          explore: explore,
          pin: pin,
        );
      } on Object catch (error, stackTrace) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      useMemory = false;
      explore = false;

      final businessTimer = Stopwatch()..start();
      try {
        final result = await _sendOnRoute(
          destination,
          route,
          attempt,
          cancelSignal,
        );
        if (pin != null && !pinned) {
          pin.route =
              _imageCandidateKey(route.kind, route.address) ?? route.kind.name;
        }
        return result;
      } on Object catch (error, stackTrace) {
        policyRecord(destination, route, error, businessTimer.elapsed);
        final eligible = _retryEligible(canReplay, error, route);
        if (eligible) {
          _invalidateRouteMemory(host, route, purpose: destination.purpose);
          if (_isPixivImage(destination)) {
            _imageRouteFailed(host, route);
          }
        }
        if (_mode == NetworkMode.directOnly ||
            (cancelSignal?.isCancelled ?? false) ||
            !eligible ||
            pinned) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        // Advance to the next candidate. [attemptedKinds] already contains
        // this route's kind, so the loop cannot repeat the same tier.
      }
    }
  }

  /// Whether a failed [error] justifies moving on to the next route tier.
  bool _retryEligible(bool canReplay, Object error, NetworkRoute route) {
    final kind = TransportFailureClassifier.classify(error).kind;
    // An empty-SNI handshake that fails certificate verification does not
    // necessarily mean MITM: without SNI the server answered from its
    // default vhost, which simply may not carry this hostname (a mirror on
    // shared hosting). Falling through to the real-SNI tier is the correct
    // answer — verification stays ON everywhere. Real-SNI mismatches and
    // pixiv's origin keep their terminal semantics: the origin always
    // presents its own certificate, so a mismatch is suspect.
    if (kind == NetworkFailureKind.certificateMismatch &&
        route.kind == NetworkRouteKind.noSni) {
      return true;
    }
    if (canReplay) return _replayEligibleKinds.contains(kind);
    return _unsentEligibleKinds.contains(kind);
  }

  /// Finds the first candidate route for the operation. The route is *not*
  /// verified here: the business request itself is the attempt,
  /// so a candidate only needs a usable connect address (fast tier: known
  /// address; direct: no address; ECH: config+front address; DoH tiers: a
  /// resolved address). [resolveHost] is shared by every selection of one
  /// request, so a DoH lookup that cannot connect costs its timeouts once.
  /// [remember] is off while racing, where only the winner is remembered.
  /// Pixiv's image hosts choose by score instead ([_selectImageRoute]).
  Future<NetworkRoute> _selectRoute({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required Set<String> attemptedKeys,
    required Set<NetworkRouteKind> attemptedKinds,
    required Future<ResolvedHost> Function() resolveHost,
    bool useMemory = true,
    bool remember = true,
    bool explore = false,
    ImageRoutePin? pin,
  }) async {
    final host = destination.canonicalHost;
    final now = clock();
    final memory = _routeMemory[host];
    if (memory != null && !memory.isUsable(now, _revision.networkIdentity)) {
      _routeMemory.remove(host);
    }

    // Explicit direct-only mode is a route decision, not a reason to probe
    // and then issue a second direct request.
    if (_mode == NetworkMode.directOnly) {
      final direct = NetworkRoute.direct(_revision);
      attemptedKinds.add(direct.kind);
      attemptedKeys.add(direct.key);
      _rememberRoute(host, direct, purpose: destination.purpose);
      return direct;
    }
    if (_isPixivImage(destination)) {
      return _selectImageRoute(
        destination: destination,
        cancelSignal: cancelSignal,
        attemptedKeys: attemptedKeys,
        attemptedKinds: attemptedKinds,
        resolveHost: resolveHost,
        explore: explore,
        pin: pin,
      );
    }

    if (useMemory) {
      final remembered = _routeMemory[host];
      if (remembered != null &&
          remembered.isUsable(now, _revision.networkIdentity)) {
        final route = remembered.routeFor(_revision);
        if (!attemptedKinds.contains(route.kind) &&
            attemptedKeys.add(route.key)) {
          attemptedKinds.add(route.kind);
          return route;
        }
      }
    }

    Object? lastError;
    StackTrace? lastStack;

    final preferredKind = rememberedGroupRouteKind(
      destination.purpose,
      destination.canonicalHost,
      now: now,
    );
    // Verified-fast-first ordering, driven by real-device probe data:
    // Cloudflare hosts (API/OAuth) reach the ECH tier inside the wall while
    // plain SNI is RST. Mirrors go direct first, in every mode (see
    // [_fallbackTiersFor]).
    final fallbackTiers = _fallbackTiersFor(destination);
    final kinds = <NetworkRouteKind>[
      ?preferredKind,
      ...fallbackTiers,
      if (!fallbackTiers.contains(NetworkRouteKind.direct))
        NetworkRouteKind.direct,
    ];
    for (final kind in kinds) {
      if (attemptedKinds.contains(kind)) continue;
      NetworkRoute? route;
      try {
        route = kind == NetworkRouteKind.direct
            ? NetworkRoute.direct(_revision)
            : await _routeForTier(
                kind,
                destination,
                resolveHost: resolveHost,
                cancelSignal: cancelSignal,
              );
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStack = stackTrace;
        if (_isCancellation(error, cancelSignal)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        _onTierUnavailable(destination, kind, preferredKind);
        continue;
      }
      if (route == null) {
        _onTierUnavailable(destination, kind, preferredKind);
        continue;
      }
      if (!attemptedKeys.add(route.key)) {
        attemptedKinds.add(kind);
        continue;
      }
      attemptedKinds.add(kind);

      final timer = Stopwatch()..start();
      try {
        if (cancelSignal?.isCancelled ?? false) {
          throw const NetworkFailureException(NetworkFailureKind.cancelled);
        }
        // The candidate is not pre-verified. The business
        // request itself is the attempt; a failure falls through to the
        // re-selection in the caller. Only cancellations abort here.
        if (remember) {
          _rememberRoute(host, route, purpose: destination.purpose);
        }
        return route;
      } on Object catch (error, stackTrace) {
        policyRecord(destination, route, error, timer.elapsed);
        lastError = error;
        lastStack = stackTrace;
        if (_isCancellation(error, cancelSignal) ||
            !TransportFailureClassifier.isFallbackEligible(error)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        _invalidateRouteMemory(host, route, purpose: destination.purpose);
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
    }
    throw const NetworkFailureException(NetworkFailureKind.connect);
  }

  bool _isPixivImage(PixivDestination destination) =>
      _routeGroupFor(destination.purpose, destination.canonicalHost) ==
      _RouteGroup.image;

  /// Pixiv's image hosts try their route candidates in the order of
  /// [_imageScores], then `dohRealSni` and `direct`; each candidate and
  /// tier once per request. A candidate that cannot be built (no ECH
  /// config) is left out. Only a request's first selection may [explore].
  /// A set [pin] allows its route alone; a resuming one tries last the
  /// candidates that answered a `Range` with the whole file.
  Future<NetworkRoute> _selectImageRoute({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required Set<String> attemptedKeys,
    required Set<NetworkRouteKind> attemptedKinds,
    required Future<ResolvedHost> Function() resolveHost,
    required bool explore,
    required ImageRoutePin? pin,
  }) async {
    final pinned = pin?.route;
    final candidates = await _imageCandidates(destination, cancelSignal);
    var order = pinned != null
        ? [if (candidates.containsKey(pinned)) pinned]
        : _imageScores.order(
            candidates.keys.toList(growable: false),
            background: explore,
          );
    if (pin != null && pin.resuming && pinned == null) {
      order = [
        ...order.where(_imageScores.servesRanges),
        ...order.where((candidate) => !_imageScores.servesRanges(candidate)),
      ];
    }
    for (final candidate in order) {
      if (attemptedKeys.add('candidate:$candidate')) {
        return candidates[candidate]!;
      }
    }
    Object? lastError;
    StackTrace? lastStack;
    for (final kind in const [
      NetworkRouteKind.dohRealSni,
      NetworkRouteKind.direct,
    ]) {
      if (pinned != null && pinned != kind.name) continue;
      if (!attemptedKinds.add(kind)) continue;
      try {
        final route = kind == NetworkRouteKind.direct
            ? NetworkRoute.direct(_revision)
            : await _routeForTier(
                kind,
                destination,
                resolveHost: resolveHost,
                cancelSignal: cancelSignal,
              );
        if (route != null && attemptedKeys.add(route.key)) return route;
      } on Object catch (error, stackTrace) {
        if (_isCancellation(error, cancelSignal)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        lastError = error;
        lastStack = stackTrace;
      }
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
    }
    throw const NetworkFailureException(NetworkFailureKind.connect);
  }

  /// A pixiv image host's route candidates by key, in their default order:
  /// ECH through each front the ECH config names, then through the seed
  /// front, then pixiv's origin.
  Future<Map<String, NetworkRoute>> _imageCandidates(
    PixivDestination destination,
    NetworkCancelSignal? cancelSignal,
  ) async {
    final candidates = <String, NetworkRoute>{};
    final ech = await _lookupEchConfig(cancelSignal: cancelSignal);
    if (ech != null && ech.echConfig.isNotEmpty) {
      final fronts = [
        ...ech.frontAddresses
            .where(isPublicNetworkAddress)
            .take(_kMaxEchCandidates - 1),
        _kSeedEchFront,
      ];
      for (final front in fronts) {
        candidates.putIfAbsent(
          _imageCandidateKey(NetworkRouteKind.ech, front)!,
          () => NetworkRoute.ech(
            _revision,
            front,
            ech.echConfig,
            dnsSource: DnsSource.doh,
            ttl: ech.ttl,
          ),
        );
      }
    }
    if (bootstrapNoSniEnabled) {
      final origin = await _originRoute(destination.canonicalHost);
      candidates[_imageCandidateKey(origin.kind, origin.address)!] = origin;
    }
    return candidates;
  }

  /// The origin candidate on the address [host]'s book has in use: the one
  /// it last loaded from, then pixiv's other origin addresses.
  Future<NetworkRoute> _originRoute(String host) async {
    var book = _originBooks[host];
    if (book == null) {
      final first =
          await fastRouteStore?.addressFor(host) ??
          PixivFastRouteStore.bootstrap[host];
      book = _originBooks[host] ??= _OriginBook([
        ?first,
        ...PixivFastRouteStore.originAddresses.where(
          (address) => address.address != first?.address,
        ),
      ]);
    }
    return NetworkRoute.bootstrapNoSni(
      _revision,
      book.current,
      dnsSource: DnsSource.doh,
      ttl: _kRouteMemoryTtl,
    );
  }

  /// Cold-start racing: when neither the host nor its route group has any
  /// usable memory, the first request would otherwise pay each candidate
  /// tier's timeout in series. For idempotent image loads (a duplicate GET
  /// is safe — [canReplay] is already proven by the caller) the top two
  /// constructible tiers are sent in parallel and the first success wins;
  /// the loser is drained and dropped. Both failing falls back to the
  /// serial ladder with the two raced kinds already marked attempted.
  ///
  /// Returns `(true, value)` on a raced win and `(false, null)` when the
  /// caller should continue with the serial walk.
  Future<(bool, T?)> _raceColdTiers<T>({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
    required Set<String> attemptedKeys,
    required Set<NetworkRouteKind> attemptedKinds,
    required Future<ResolvedHost> Function() resolveHost,
  }) async {
    final host = destination.canonicalHost;
    final now = clock();
    if (_mode == NetworkMode.directOnly) return (false, null);
    // Racing only pays when nothing is remembered — a warm host/group would
    // jump straight to a known-good tier, and two parallel sends would be
    // pure waste.
    final remembered = _routeMemory[host];
    if (remembered != null &&
        remembered.isUsable(now, _revision.networkIdentity)) {
      return (false, null);
    }
    if (rememberedGroupRouteKind(destination.purpose, host, now: now) != null) {
      return (false, null);
    }

    final routeA = await _selectRoute(
      destination: destination,
      cancelSignal: cancelSignal,
      attemptedKeys: attemptedKeys,
      attemptedKinds: attemptedKinds,
      resolveHost: resolveHost,
      useMemory: false,
      remember: false,
    );
    final sendA = _raceSend(destination, routeA, attempt, cancelSignal);
    // Selecting the second tier may resolve DNS/ECH while A's send is
    // already in flight — that overlap is the point of racing. An A that
    // succeeds first wins without waiting: B's selection may be a DoH
    // lookup that cannot connect on this network.
    final selectB = _selectRoute(
      destination: destination,
      cancelSignal: cancelSignal,
      attemptedKeys: attemptedKeys,
      attemptedKinds: attemptedKinds,
      resolveHost: resolveHost,
      useMemory: false,
      remember: false,
    ).then<NetworkRoute?>((route) => route, onError: (Object _) => null);
    final early = await Future.any<_RaceOutcome<T>?>([
      sendA,
      selectB.then((_) => null),
    ]);
    _RaceSuccess<T>? winner;
    Future<_RaceOutcome<T>>? loser;
    if (early is _RaceSuccess<T>) {
      winner = early;
    } else {
      final routeB = await selectB;
      if (routeB == null) {
        // Only one tier was constructible — take A's outcome alone.
        winner = switch (await sendA) {
          final _RaceSuccess<T> success => success,
          _RaceFailure<T>(:final error, :final stackTrace) =>
            Error.throwWithStackTrace(error, stackTrace),
        };
      } else {
        (winner, loser) = await _raceAgainst(
          destination,
          sendA,
          _raceSend(destination, routeB, attempt, cancelSignal),
        );
      }
    }
    if (winner == null) return (false, null);

    if (cancelSignal?.isCancelled ?? false) {
      _discardRaceOutcome(destination, winner);
      if (loser != null) {
        unawaited(loser.then((o) => _discardRaceOutcome(destination, o)));
      }
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }
    _rememberRoute(host, winner.route, purpose: destination.purpose);
    // The loser keeps no memory and never reports back; drain its body so
    // the socket is reclaimed promptly, or record a late failure so the
    // diagnostics stay truthful.
    if (loser != null) {
      unawaited(loser.then((o) => _discardRaceOutcome(destination, o)));
    }
    return (true, winner.value);
  }

  /// The first success of [sendA] and [sendB], with the other send to
  /// drain; a null winner when both failed and the serial ladder should
  /// continue.
  Future<(_RaceSuccess<T>?, Future<_RaceOutcome<T>>?)> _raceAgainst<T>(
    PixivDestination destination,
    Future<_RaceOutcome<T>> sendA,
    Future<_RaceOutcome<T>> sendB,
  ) async {
    final host = destination.canonicalHost;
    // Tag each send so `Future.any` tells us which one resolved.
    final (firstIndex, first) = await Future.any([
      sendA.then((outcome) => (0, outcome)),
      sendB.then((outcome) => (1, outcome)),
    ]);
    if (first is _RaceSuccess<T>) {
      return (first, firstIndex == 0 ? sendB : sendA);
    }
    // The first failure often lands fast (RST/refused) while the winning
    // tier is still handshaking — wait for the sibling before giving up.
    final second = await (firstIndex == 0 ? sendB : sendA);
    if (second is _RaceSuccess<T>) return (second, null);
    _discardRaceOutcome(destination, first);
    _discardRaceOutcome(destination, second);
    for (final failure in [first, second]) {
      _invalidateRouteMemory(host, failure.route, purpose: destination.purpose);
    }
    // Racing must not weaken terminal semantics: a failure the serial
    // ladder would have called final (e.g. a real-SNI certificate mismatch)
    // still ends the walk here instead of leaking into the remaining tiers.
    for (final failure in [first, second]) {
      if (failure is _RaceFailure<T> &&
          !_retryEligible(true, failure.error, failure.route)) {
        Error.throwWithStackTrace(failure.error, failure.stackTrace);
      }
    }
    return (null, null);
  }

  /// Wraps one raced attempt so neither send ever throws — the race loop
  /// reads outcomes instead of catching.
  Future<_RaceOutcome<T>> _raceSend<T>(
    PixivDestination destination,
    NetworkRoute route,
    FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
    NetworkCancelSignal? cancelSignal,
  ) async {
    final timer = Stopwatch()..start();
    try {
      if (cancelSignal?.isCancelled ?? false) {
        throw const NetworkFailureException(NetworkFailureKind.cancelled);
      }
      final value = await attempt(route, destination.uri);
      return _RaceSuccess<T>(route, value, timer.elapsed);
    } on Object catch (error, stackTrace) {
      return _RaceFailure<T>(route, error, stackTrace, timer.elapsed);
    }
  }

  /// Releases a raced outcome that did not win: a streamed body is drained
  /// so reqwest reclaims the socket; a failure is recorded for diagnostics
  /// and clears the optimistically-remembered selection.
  void _discardRaceOutcome(
    PixivDestination destination,
    _RaceOutcome<Object?> outcome,
  ) {
    switch (outcome) {
      case _RaceSuccess(value: final value):
        if (value is http.StreamedResponse) {
          // Nobody waits for a loser's body: its idle timeout is no error.
          value.stream.drain<void>().ignore();
        }
      case _RaceFailure(:final route, :final error, :final latency):
        policyRecord(destination, route, error, latency);
        _invalidateRouteMemory(
          destination.canonicalHost,
          route,
          purpose: destination.purpose,
        );
    }
  }

  Future<T> _sendOnRoute<T>(
    PixivDestination destination,
    NetworkRoute route,
    FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
    NetworkCancelSignal? cancelSignal,
  ) async {
    if (cancelSignal?.isCancelled ?? false) {
      throw const NetworkFailureException(NetworkFailureKind.cancelled);
    }
    final result = await attempt(route, destination.uri);
    // Refresh (rather than delete) a remembered route on every successful
    // business request.  A successful direct route is the one case that
    // intentionally replaces an older strict preference.
    _rememberRoute(
      destination.canonicalHost,
      route,
      purpose: destination.purpose,
    );
    _learnFastRoute(destination.canonicalHost, route);
    return result;
  }

  /// An origin success teaches the store its address, where the next start
  /// on [host] begins (the store keeps pixiv's image hosts only).
  void _learnFastRoute(String host, NetworkRoute route) {
    final store = fastRouteStore;
    final address = route.address;
    if (store == null ||
        address == null ||
        route.kind != NetworkRouteKind.bootstrapNoSni) {
      return;
    }
    // An acceleration layer: the request has already completed and must not
    // be changed by a cache write error.
    unawaited(
      store
          .remember(host, address)
          .catchError((Object error) => log('fast route for $host: $error')),
    );
  }

  void _rememberRoute(
    String host,
    NetworkRoute route, {
    required PixivDestinationPurpose purpose,
  }) {
    // Pixiv's image hosts remember through their scores.
    if (_routeGroupFor(purpose, host) == _RouteGroup.image) return;
    final address = route.address;
    if (route.kind != NetworkRouteKind.direct && address == null) {
      // A strict route without a connect address is not usable and must never
      // become a remembered preference.
      return;
    }
    final now = clock();
    final existing = _routeMemory[host];
    final keepEchCreatedAt =
        route.kind == NetworkRouteKind.ech &&
        existing?.kind == NetworkRouteKind.ech &&
        existing?.routeFor(_revision).key == route.key;
    _routeMemory[host] = _HostRouteMemory(
      address,
      kind: route.kind,
      dnsSource: route.dnsSource,
      ttl: route.ttl ?? _kRouteMemoryTtl,
      createdAt: keepEchCreatedAt ? existing!.createdAt : now,
      networkIdentity: _revision.networkIdentity,
      echConfig: route.echConfig == null
          ? null
          : List<int>.unmodifiable(route.echConfig!),
    );
    final group = _routeGroupFor(purpose, host);
    if (route.kind == NetworkRouteKind.direct) {
      _groupMemory.remove(group);
    } else if (_isGroupPreference(group, route.kind)) {
      final current = _groupMemory[group];
      final keepEchGroupCreatedAt =
          route.kind == NetworkRouteKind.ech &&
          current?.kind == NetworkRouteKind.ech &&
          current?.networkIdentity == _revision.networkIdentity;
      _groupMemory[group] = _RouteGroupMemory(
        kind: route.kind,
        ttl: route.ttl ?? _kRouteMemoryTtl,
        createdAt: keepEchGroupCreatedAt ? current!.createdAt : now,
        networkIdentity: _revision.networkIdentity,
      );
      // Persist the hint so the next cold start on this network seeds the
      // group preference instead of paying the discovery walk. Writes are
      // serialized inside the store; a failure is logged there.
      unawaited(
        routeKindStore?.remember(
          _revision.networkIdentity,
          group.name,
          route.kind.name,
        ),
      );
    }
    _trimRouteMemory();
  }

  void _invalidateRouteMemory(
    String host,
    NetworkRoute route, {
    required PixivDestinationPurpose purpose,
  }) {
    final memory = _routeMemory[host];
    if (memory != null &&
        memory.kind == route.kind &&
        memory.networkIdentity == _revision.networkIdentity) {
      final remembered = memory.routeFor(_revision);
      if (remembered.key == route.key) {
        _routeMemory.remove(host);
      }
    }
    final group = _routeGroupFor(purpose, host);
    final groupMemory = _groupMemory[group];
    if (groupMemory != null &&
        groupMemory.kind == route.kind &&
        groupMemory.networkIdentity == _revision.networkIdentity) {
      _groupMemory.remove(group);
    }
  }

  /// A tier that could not be built drops the group preference that pointed
  /// at it.
  void _onTierUnavailable(
    PixivDestination destination,
    NetworkRouteKind kind,
    NetworkRouteKind? preferredKind,
  ) {
    if (preferredKind == kind) {
      _invalidateGroupPreference(
        destination.purpose,
        kind,
        destination.canonicalHost,
      );
    }
  }

  bool _isCancellation(Object error, NetworkCancelSignal? signal) =>
      signal?.isCancelled == true ||
      TransportFailureClassifier.classify(error).kind ==
          NetworkFailureKind.cancelled;

  /// Ordered fallback tiers after the group preference, for the groups
  /// other than pixiv's image hosts. Cloudflare hosts (API/OAuth) reach ECH
  /// inside the wall (real SNI is RST) and ECH gives HTTP/2 multiplexing on
  /// one connection.
  List<NetworkRouteKind> _fallbackTiersFor(PixivDestination destination) {
    final purpose = destination.purpose;
    // Third-party image mirrors (preset/custom reverse proxies) are not
    // pixiv infrastructure: the ECH config and the persisted-address tier
    // only exist for pixiv's own hosts and would fail or mis-route a
    // mirror. `direct` leads, in every mode: a mirror exists to be reached
    // directly (pixiv.re and pixiv.nl are, from the mainland), and both
    // other tiers wait on DoH, which the mainland often cannot reach.
    // `noSni` serves a single-tenant reverse proxy whose name is
    // SNI-blocked: its default vhost still presents a valid certificate
    // for the mirror name (Cloudflare-hosted mirrors refuse an empty SNI).
    // A default vhost that does not cover the name fails with a
    // certificate mismatch, which `_retryEligible` advances past on this
    // tier; dohRealSni keeps the real-SNI escape hatch. No bootstrapNoSni:
    // mirrors have no known origin address.
    if (isImageMirror(purpose, destination.canonicalHost)) {
      return [
        NetworkRouteKind.direct,
        NetworkRouteKind.noSni,
        NetworkRouteKind.dohRealSni,
      ];
    }
    // No origin tier: pixiv's origin answers API, OAuth and web traffic
    // that bypasses Cloudflare with 403, which this ladder would take for a
    // working route.
    return [NetworkRouteKind.ech, NetworkRouteKind.dohRealSni];
  }

  /// Whether a success on [kind] may become [group]'s shared (and
  /// persisted) preference. Pixiv's image group has none: its scores choose
  /// (see [ImageRouteScores]).
  bool _isGroupPreference(_RouteGroup group, NetworkRouteKind kind) {
    if (group == _RouteGroup.image) return false;
    return switch (kind) {
      NetworkRouteKind.ech ||
      NetworkRouteKind.dohRealSni ||
      NetworkRouteKind.noSni => true,
      // The bootstrap kind is pixiv's image origin. Older versions persisted
      // it as the API group's preference after pixiv's origin answered 403;
      // seeding drops those entries here.
      NetworkRouteKind.bootstrapNoSni || NetworkRouteKind.direct => false,
    };
  }

  void _invalidateGroupPreference(
    PixivDestinationPurpose purpose,
    NetworkRouteKind kind,
    String host,
  ) {
    final group = _routeGroupFor(purpose, host);
    if (_groupMemory[group]?.kind == kind) _groupMemory.remove(group);
  }

  /// Builds a [NetworkRoute] for [kind], resolving the destination host only
  /// for the tiers that need it.
  ///
  /// [resolveHost] is lazy and memoised by the caller: the ECH tier never
  /// calls it. Returns null when the tier cannot be constructed (e.g. the ECH
  /// config lookup failed, or the policy was injected with a non-DoH
  /// resolver). The ladder skips null tiers and falls through to the next one
  /// — an unavailable ECH tier never turns into a hard error here, because
  /// the caller treats "no route" as "tier unavailable".
  Future<NetworkRoute?> _routeForTier(
    NetworkRouteKind kind,
    PixivDestination destination, {
    required Future<ResolvedHost> Function() resolveHost,
    required NetworkCancelSignal? cancelSignal,
  }) async {
    switch (kind) {
      case NetworkRouteKind.ech:
        // Deliberately does NOT resolve the destination host. The ECH tier's
        // TCP peer is the ECH front's anycast address (ipv4hint from the
        // front's own HTTPS RR); the destination's mainland answer is
        // polluted and would send the handshake nowhere. Coupling this tier
        // to the destination resolve also meant a slow or failing DoH lookup
        // took ECH down with it, which is exactly what kept the tier from
        // ever running on a mainland device.
        final ech = await _lookupEchConfig(cancelSignal: cancelSignal);
        if (ech == null || ech.echConfig.isEmpty) return null;
        final frontAddress =
            ech.frontAddresses.where(isPublicNetworkAddress).firstOrNull ??
            await _resolveFrontHost(cancelSignal: cancelSignal);
        if (frontAddress == null) return null;
        return NetworkRoute.ech(
          _revision,
          frontAddress,
          ech.echConfig,
          dnsSource: DnsSource.doh,
          ttl: ech.ttl,
        );
      case NetworkRouteKind.dohRealSni:
        final resolved = await resolveHost();
        return NetworkRoute.secureDns(
          _revision,
          resolved.addresses.first,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
      case NetworkRouteKind.noSni:
        final resolved = await resolveHost();
        return NetworkRoute.noSni(
          _revision,
          resolved.addresses.first,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
      case NetworkRouteKind.bootstrapNoSni || NetworkRouteKind.direct:
        throw StateError('${kind.name} is not a fallback tier');
    }
  }

  /// Fetches the ECH config for [echFrontHost]. Returns null when the
  /// resolver is not a DoH resolver or the lookup failed — the ECH tier is
  /// then treated as unavailable and the ladder moves on (never a silent
  /// plain-TLS downgrade: the next tier, if any, is its own explicit
  /// route).
  Future<EchConfigResult?> _lookupEchConfig({
    required NetworkCancelSignal? cancelSignal,
  }) async {
    final resolver = _resolver;
    if (resolver is! EchConfigResolver) {
      return null;
    }
    final echResolver = resolver as EchConfigResolver;
    try {
      return await echResolver.lookupEchConfig(
        echFrontHost,
        revision: _revision,
        cancelSignal: cancelSignal,
      );
    } on Object catch (error, stackTrace) {
      if (_isCancellation(error, cancelSignal)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      return null;
    }
  }

  /// Resolves the ECH front host (e.g. cloudflare-ech.com) to a connect
  /// address when its HTTPS RR carries no ipv4hint. The front host is not
  /// polluted by the GFW (its answers stayed clean in mainland probes), so
  /// the DoH resolve is the fallback source for the ECH TCP peer.
  Future<InternetAddress?> _resolveFrontHost({
    required NetworkCancelSignal? cancelSignal,
  }) async {
    final resolver = _resolver;
    if (resolver is! EchConfigResolver) return null;
    try {
      final resolved = await _resolver.resolve(
        echFrontHost,
        revision: _revision,
        cancelSignal: cancelSignal,
      );
      if (resolved.host != echFrontHost ||
          resolved.revision.value != _revision.value ||
          resolved.revision.networkIdentity != _revision.networkIdentity) {
        return null;
      }
      return resolved.addresses.where(isPublicNetworkAddress).firstOrNull;
    } on Object catch (error, stackTrace) {
      if (_isCancellation(error, cancelSignal)) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      return null;
    }
  }
}

/// One raced send's outcome. Successes and failures both arrive here so the
/// race loop never catches — it pattern-matches instead.
sealed class _RaceOutcome<T> {
  const _RaceOutcome(this.route, this.latency);

  final NetworkRoute route;
  final Duration latency;
}

class _RaceSuccess<T> extends _RaceOutcome<T> {
  const _RaceSuccess(super.route, this.value, super.latency);

  final T value;
}

class _RaceFailure<T> extends _RaceOutcome<T> {
  const _RaceFailure(super.route, this.error, this.stackTrace, super.latency);

  final Object error;
  final StackTrace stackTrace;
}
