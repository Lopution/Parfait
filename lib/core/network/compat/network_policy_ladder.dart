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

const _kFastRouteCooldown = Duration(seconds: 30);

extension NetworkAccessPolicyLadder on NetworkAccessPolicy {
  /// The single route ladder shared by the API, OAuth, image and download
  /// exits.
  ///
  /// PixEz-style attempt-first: the business request itself is the route
  /// attempt, so no credential-free probe round trip is paid before data. If
  /// the attempt fails with a transport-level error that proves the request
  /// was never delivered, the ladder walks the remaining unused kinds (ECH
  /// first on a cold start; `insecureNoSni` always last) and sends each
  /// unused kind at most once.
  /// [canReplay] selects the retry set: idempotent GET/HEAD/downloads also
  /// retry on timeout (a repeat is safe), while POST-family and the token
  /// exchange retry only on delivery-proven failures (DNS, connect, reset,
  /// TLS handshake), so a request that may have reached the server (HTTP
  /// response, timeout after send) is never repeated.
  Future<T> runLadder<T>({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required bool canReplay,
    required FutureOr<T> Function(NetworkRoute route, Uri url) attempt,
    bool raceWhenCold = false,
  }) async {
    _checkUsable();
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
      );
    } on Object {
      // A mirror/auto-source host that exhausted every tier is reported so
      // the auto source selection can drop the dead winner — the original
      // error still propagates to the caller unchanged.
      if (destination.purpose == PixivDestinationPurpose.image) {
        final host = destination.canonicalHost;
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
    bool raceWhenCold = false,
  }) async {
    final host = destination.canonicalHost;
    final attemptedKeys = <String>{};
    final attemptedKinds = <NetworkRouteKind>{};
    var useMemory = true;
    if (canReplay && raceWhenCold) {
      final (raced, value) = await _raceColdTiers<T>(
        destination: destination,
        cancelSignal: cancelSignal,
        attempt: attempt,
        attemptedKeys: attemptedKeys,
        attemptedKinds: attemptedKinds,
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
          useMemory: useMemory,
        );
      } on Object catch (error, stackTrace) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      useMemory = false;

      final businessTimer = Stopwatch()..start();
      try {
        final result = await _sendOnRoute(
          destination,
          route,
          attempt,
          cancelSignal,
        );
        _clearFastRouteCooldown(host, route);
        return result;
      } on Object catch (error, stackTrace) {
        policyRecord(destination, route, error, businessTimer.elapsed);
        final eligible = _retryEligible(canReplay, error, route);
        if (eligible) {
          _invalidateRouteMemory(host, route, purpose: destination.purpose);
          _coolFastRoute(host, route);
        }
        if (_mode == NetworkMode.directOnly ||
            (cancelSignal?.isCancelled ?? false) ||
            !eligible) {
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
    // the insecure tier keep their terminal semantics.
    if (kind == NetworkFailureKind.certificateMismatch &&
        route.kind == NetworkRouteKind.noSni) {
      return true;
    }
    if (canReplay) return _replayEligibleKinds.contains(kind);
    return _unsentEligibleKinds.contains(kind);
  }

  /// Finds the first candidate route for the operation. The route is *not*
  /// verified here: the business request itself is the attempt (PixEz-style),
  /// so a candidate only needs a usable connect address (fast tier: known
  /// address; direct: no address; ECH: config+front address; DoH tiers: a
  /// resolved address).
  Future<NetworkRoute> _selectRoute({
    required PixivDestination destination,
    required NetworkCancelSignal? cancelSignal,
    required Set<String> attemptedKeys,
    required Set<NetworkRouteKind> attemptedKinds,
    bool useMemory = true,
  }) async {
    final host = destination.canonicalHost;
    final now = clock();
    final fastCompatibilityAvailable =
        _fastCompatibilityEnabled && !_isFastRouteCooling(host, now);
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

    if (useMemory) {
      final remembered = _routeMemory[host];
      if (remembered != null &&
          remembered.isUsable(now, _revision.networkIdentity)) {
        final route = remembered.routeFor(_revision);
        if ((!_isFastRouteCooling(host, now) ||
                route.kind != NetworkRouteKind.insecureNoSni) &&
            !attemptedKinds.contains(route.kind) &&
            attemptedKeys.add(route.key)) {
          attemptedKinds.add(route.kind);
          return route;
        }
      }
    }

    Object? lastError;
    StackTrace? lastStack;
    ResolvedHost? pendingResolved;
    Future<ResolvedHost> resolveOnce() async => pendingResolved ??=
        await resolve(destination, cancelSignal: cancelSignal);

    final preferredKind = rememberedGroupRouteKind(
      destination.purpose,
      destination.canonicalHost,
      now: now,
    );
    final usablePreferredKind =
        preferredKind == NetworkRouteKind.insecureNoSni &&
            !fastCompatibilityAvailable
        ? null
        : preferredKind;
    final fallbackTiers = _fallbackTiersFor(destination);
    // Verified-fast-first ordering, driven by real-device probe data:
    // Cloudflare hosts (API/OAuth) reach the ECH tier inside the wall while
    // plain SNI is RST; image hosts reach the empty-SNI tier on their origin
    // addresses. The PixEz bootstrap (insecureNoSni) stays as the very last
    // fallback: if it happens to work on this network it is remembered and
    // promoted by route/group memory after one success, but an unverified
    // address can never again cost the first N requests of a screen.
    final hasInsecureFallback = fallbackTiers.contains(
      NetworkRouteKind.insecureNoSni,
    );
    final kinds = <NetworkRouteKind>[
      ?usablePreferredKind,
      ...fallbackTiers.where((kind) => kind != NetworkRouteKind.insecureNoSni),
      NetworkRouteKind.direct,
      if (hasInsecureFallback && !_isFastRouteCooling(host, now))
        NetworkRouteKind.insecureNoSni,
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
                resolveHost: resolveOnce,
                cancelSignal: cancelSignal,
              );
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStack = stackTrace;
        if (_isCancellation(error, cancelSignal)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        if (usablePreferredKind == kind) {
          _invalidateGroupPreference(
            destination.purpose,
            kind,
            destination.canonicalHost,
          );
        }
        continue;
      }
      if (route == null) {
        if (usablePreferredKind == kind) {
          _invalidateGroupPreference(
            destination.purpose,
            kind,
            destination.canonicalHost,
          );
        }
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
        // PixEz-style: the candidate is not pre-verified. The business
        // request itself is the attempt; a failure falls through to the
        // re-selection in the caller. Only cancellations abort here.
        _rememberRoute(host, route, purpose: destination.purpose);
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
      useMemory: false,
    );
    final sendA = _raceSend(destination, routeA, attempt, cancelSignal);
    // Selecting the second tier may resolve DNS/ECH while A's send is
    // already in flight — that overlap is the point of racing.
    NetworkRoute? routeB;
    try {
      routeB = await _selectRoute(
        destination: destination,
        cancelSignal: cancelSignal,
        attemptedKeys: attemptedKeys,
        attemptedKinds: attemptedKinds,
        useMemory: false,
      );
    } on Object {
      routeB = null;
    }
    if (routeB == null) {
      // Only one tier was constructible — take A's outcome alone.
      return switch (await sendA) {
        _RaceSuccess<T>(value: final value) => (true, value),
        _RaceFailure<T>(:final error, :final stackTrace) =>
          Error.throwWithStackTrace(error, stackTrace),
      };
    }
    final sendB = _raceSend(destination, routeB, attempt, cancelSignal);

    // Tag each send so `Future.any` tells us which one resolved.
    final indexed = [
      sendA.then((outcome) => (0, outcome)),
      sendB.then((outcome) => (1, outcome)),
    ];
    final (firstIndex, first) = await Future.any(indexed);
    _RaceSuccess<T>? winner;
    Future<_RaceOutcome<T>>? loser;
    if (first is _RaceSuccess<T>) {
      winner = first;
      loser = firstIndex == 0 ? sendB : sendA;
    } else {
      // The first failure often lands fast (RST/refused) while the winning
      // tier is still handshaking — wait for the sibling before giving up.
      final second = await (firstIndex == 0 ? sendB : sendA);
      if (second is _RaceSuccess<T>) {
        winner = second;
      } else {
        _discardRaceOutcome(destination, first);
        _discardRaceOutcome(destination, second);
        _invalidateRouteMemory(host, routeA, purpose: destination.purpose);
        _invalidateRouteMemory(host, routeB, purpose: destination.purpose);
        _coolFastRoute(host, routeA);
        _coolFastRoute(host, routeB);
        // Racing must not weaken terminal semantics: a failure the serial
        // ladder would have called final (e.g. a real-SNI certificate
        // mismatch) still ends the walk here instead of leaking into the
        // remaining tiers.
        for (final failure in [first, second]) {
          if (failure is _RaceFailure<T> &&
              !_retryEligible(true, failure.error, failure.route)) {
            Error.throwWithStackTrace(failure.error, failure.stackTrace);
          }
        }
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
    _clearFastRouteCooldown(host, winner.route);
    if (winner.route.kind == NetworkRouteKind.insecureNoSni &&
        winner.route.address != null) {
      unawaited(_refreshFastRoute(host, winner.route.address!));
    }
    // The loser keeps no memory and never reports back; drain its body so
    // the socket is reclaimed promptly, or record a late failure so the
    // diagnostics stay truthful.
    if (loser != null) {
      unawaited(loser.then((o) => _discardRaceOutcome(destination, o)));
    }
    return (true, winner.value);
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
          unawaited(value.stream.drain<void>());
        }
      case _RaceFailure(:final route, :final error, :final latency):
        policyRecord(destination, route, error, latency);
        _invalidateRouteMemory(
          destination.canonicalHost,
          route,
          purpose: destination.purpose,
        );
        _coolFastRoute(destination.canonicalHost, route);
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
    if (route.kind == NetworkRouteKind.insecureNoSni &&
        fastRouteStore != null) {
      unawaited(_refreshFastRoute(destination.canonicalHost, route.address!));
    }
    return result;
  }

  Future<void> _refreshFastRoute(String host, InternetAddress address) async {
    final store = fastRouteStore;
    if (store == null) return;
    try {
      await store.remember(host, address);
      await store.refresh(host, resolver: _resolver, revision: _revision);
    } on Object {
      // Fast-route persistence is an acceleration layer; the active request
      // has already completed and must not be changed by a cache write error.
    }
  }

  void _rememberRoute(
    String host,
    NetworkRoute route, {
    required PixivDestinationPurpose purpose,
  }) {
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
    } else if (_isGroupPreferenceKind(route.kind)) {
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
      // serialized inside the store; a failure is swallowed there.
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

  bool _isFastRouteCooling(String host, DateTime now) {
    final until = _fastRouteCooldownUntil[host];
    if (until == null) return false;
    if (now.isBefore(until)) return true;
    _fastRouteCooldownUntil.remove(host);
    return false;
  }

  void _coolFastRoute(String host, NetworkRoute route) {
    if (route.kind != NetworkRouteKind.insecureNoSni ||
        !_fastCompatibilityEnabled) {
      return;
    }
    _fastRouteCooldownUntil[host] = clock().add(_kFastRouteCooldown);
  }

  void _clearFastRouteCooldown(String host, NetworkRoute route) {
    if (route.kind == NetworkRouteKind.insecureNoSni) {
      _fastRouteCooldownUntil.remove(host);
    }
  }

  bool _isCancellation(Object error, NetworkCancelSignal? signal) =>
      signal?.isCancelled == true ||
      TransportFailureClassifier.classify(error).kind ==
          NetworkFailureKind.cancelled;

  /// Ordered fallback tiers after the group preference, per destination
  /// group. Cloudflare hosts (API/OAuth) reach ECH inside the wall (real
  /// SNI is RST) and ECH gives HTTP/2 multiplexing on one connection; image
  /// hosts answer on the ECH front too (real-device probes return reachable
  /// 403/404), and the plain empty-SNI tier on their origin addresses is the
  /// second choice. The PixEz bootstrap (insecureNoSni) is always last: it
  /// is unverified on a cold network and costs a connect timeout when its
  /// address cannot be reached.
  List<NetworkRouteKind> _fallbackTiersFor(PixivDestination destination) {
    final purpose = destination.purpose;
    // Third-party image mirrors (preset/custom reverse proxies) are not
    // pixiv infrastructure: the ECH config and the persisted-address tier
    // only exist for pixiv's own hosts and would fail or mis-route a
    // mirror. `noSni` leads the fallback because mirror domains are
    // SNI-blocked inside the wall, and a single-tenant reverse proxy
    // answers an empty-SNI handshake from a default vhost that still
    // presents a valid certificate for the mirror name — verification
    // stays ON (no insecureNoSni tier for mirrors: we must not switch off
    // verification for a host the user configured themselves). A mirror
    // whose default vhost does not cover the name fails the handshake
    // with a certificate mismatch, which `_retryEligible` advances past
    // on this tier; dohRealSni keeps the real-SNI escape hatch.
    if (purpose == PixivDestinationPurpose.image &&
        !PixivClientIdentity.downloadHosts.contains(
          destination.canonicalHost,
        )) {
      return [NetworkRouteKind.noSni, NetworkRouteKind.dohRealSni];
    }
    final isCloudflareHost = switch (purpose) {
      PixivDestinationPurpose.appApi ||
      PixivDestinationPurpose.oauth ||
      PixivDestinationPurpose.accountsWeb ||
      PixivDestinationPurpose.pixivWeb => true,
      PixivDestinationPurpose.image => false,
    };
    final tiers = isCloudflareHost
        ? [NetworkRouteKind.ech, NetworkRouteKind.dohRealSni]
        : [
            NetworkRouteKind.ech,
            NetworkRouteKind.noSni,
            NetworkRouteKind.dohRealSni,
          ];
    if (insecureNoSniEnabled) {
      tiers.add(NetworkRouteKind.insecureNoSni);
    }
    return tiers;
  }

  bool _isGroupPreferenceKind(NetworkRouteKind kind) => switch (kind) {
    NetworkRouteKind.ech ||
    NetworkRouteKind.dohRealSni ||
    NetworkRouteKind.noSni ||
    NetworkRouteKind.insecureNoSni =>
      kind != NetworkRouteKind.insecureNoSni || _fastCompatibilityEnabled,
    NetworkRouteKind.direct => false,
  };

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
      case NetworkRouteKind.insecureNoSni:
        final store = fastRouteStore;
        if (store != null) {
          final fastAddress = await store.addressFor(destination.canonicalHost);
          if (fastAddress == null) return null;
          return NetworkRoute.insecureNoSni(
            _revision,
            fastAddress,
            dnsSource: DnsSource.doh,
            ttl: _kRouteMemoryTtl,
          );
        }
        final resolved = await resolveHost();
        return NetworkRoute.insecureNoSni(
          _revision,
          resolved.addresses.first,
          dnsSource: resolved.dnsSource,
          ttl: resolved.ttl,
        );
      case NetworkRouteKind.direct:
        throw StateError('direct is not a fallback tier');
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
