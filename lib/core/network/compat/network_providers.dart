import 'dart:async';

import 'package:flutter/services.dart' show ServicesBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/shared_preferences.dart';

import '../../log.dart';
import '../../platform/local_network.dart';
import '../../platform/network_identity.dart';
import '../../settings/app_settings.dart';
import '../../settings/settings_controller.dart';
import '../network_restore_signal.dart';
import 'network_contracts.dart' as contracts;
import 'auto_image_source.dart';
import 'pixiv_network_factory.dart';
import 'network_policy.dart';
import '../dev_transport_override.dart';
import 'network_fast_route_store.dart';
import 'image_route_score_store.dart';
import 'route_kind_store.dart';

/// App-scoped network policy. Every native Pixiv API/OAuth/image/download
/// consumer receives this same revision and diagnostics owner.
///
/// DoH settings are watched so an enable/endpoint change rebuilds the
/// policy's resolver; pooled clients are closed by the old policy's dispose.
/// The persisted network mode (D3) seeds the initial route decision and
/// rebuilds the policy (and its mode) when the user changes it.
final networkAccessPolicyProvider = Provider<NetworkAccessPolicy>((ref) {
  final dohEnabled = ref.watch(dohEnabledProvider);
  final endpoints = ref.watch(dohEndpointsProvider);
  final echFrontHost = ref.watch(echFrontHostProvider);
  final mode = ref.watch(networkModeProvider);
  final imageMirrorHosts = ref.watch(imageMirrorAllowlistProvider);
  final localNetworkBlockedHosts = ref.watch(localNetworkBlockedHostsProvider);
  // The compatibility transport is an internal performance tier, not a
  // user-facing security switch. It uses persisted/bootstrap host addresses
  // and remains behind the explicit directOnly escape hatch.
  final devTransport = ref.watch(devTransportProvider);
  final loopbackOrigin = devTransport.activeLoopbackOrigin;
  final policy = NetworkAccessPolicy(
    registry: contracts.PixivDestinationRegistry(
      extraImageHosts: imageMirrorHosts,
    ),
    dohEndpoints: loopbackOrigin != null
        ? const []
        : (dohEnabled ? endpoints : const []),
    echFrontHost: echFrontHost,
    bootstrapNoSniEnabled: true,
    localNetworkBlockedHosts: loopbackOrigin != null
        ? const {}
        : localNetworkBlockedHosts,
    fastRouteStore: loopbackOrigin != null
        ? null
        : ref.watch(fastRouteStoreProvider),
    routeKindStore: loopbackOrigin != null
        ? null
        : ref.watch(routeKindStoreProvider),
    imageRouteScoreStore: loopbackOrigin != null
        ? null
        : ref.watch(imageRouteScoreStoreProvider),
    mode: loopbackOrigin != null
        ? contracts.NetworkMode.directOnly
        : switch (mode) {
            NetworkMode.automatic => contracts.NetworkMode.automatic,
            NetworkMode.directOnly => contracts.NetworkMode.directOnly,
            NetworkMode.compatPrefer => contracts.NetworkMode.compatPrefer,
          },
    clientFactory: loopbackOrigin == null
        ? null
        : loopbackNetworkClientFactory(loopbackOrigin),
  );

  // A network change (Wi-Fi↔cellular, VPN toggle, captive portal escape)
  // invalidates every learned route and pooled client — the remembered
  // winner on the old network is frequently unreachable on the new one.
  // The identity string also keys the persisted route kinds, so returning
  // to a known network re-seeds its last-good tiers.
  var connectivityIdentity = 'initial';
  var hasRealIdentity = false;
  var fallbackElapsed = false;
  var lastAutoNotifiedIdentity = '';
  Timer? startupFallbackTimer;
  // In auto mode the winner applies through [autoImageSourceWinnerProvider]:
  // its update rebuilds [imageMirrorProvider], so image URLs start
  // rewriting through it.
  final autoSource = AutoSourceSelector(
    store: AutoImageSource(preferences: ref.watch(sharedPreferencesProvider)),
    raceWithCancel: (cancel) =>
        AutoImageSource.race(policy, cancelSignal: cancel),
    enabled: () =>
        ref.read(settingsProvider).value?.imageSource ==
        ImageSourceMode.auto.host,
    current: () => ref.read(autoImageSourceWinnerProvider),
    apply: (host) => ref.read(autoImageSourceWinnerProvider.notifier).set(host),
  );
  ref.onDispose(autoSource.dispose);

  void maybeNotifyAutoSource() {
    if (!hasRealIdentity && !fallbackElapsed) return;
    if (ref.read(settingsProvider).value == null) return;
    if (connectivityIdentity == lastAutoNotifiedIdentity) return;
    lastAutoNotifiedIdentity = connectivityIdentity;
    autoSource.networkSeen(connectivityIdentity);
  }

  // A dead mirror winner (every ladder tier exhausted) is dropped back to
  // direct and the candidates are re-raced — the next reachable source
  // takes over without user intervention.
  policy.onImageHostExhausted = autoSource.winnerExhausted;

  void onConnectivity(String identity) {
    final wasInitial = connectivityIdentity == 'initial';
    hasRealIdentity = true;
    startupFallbackTimer?.cancel();
    startupFallbackTimer = null;
    if (identity == connectivityIdentity) {
      maybeNotifyAutoSource();
      return;
    }
    connectivityIdentity = identity;
    if (wasInitial && identity != 'none') {
      policy.bindInitialNetworkIdentity(identity);
    } else {
      policy.advanceNetworkRevision(networkIdentity: identity);
    }
    maybeNotifyAutoSource();
    ref.read(networkRestoreSignalProvider.notifier).observe(identity);
  }

  ref.listen(settingsProvider, (_, next) {
    if (next.hasValue) maybeNotifyAutoSource();
  });

  StreamSubscription<String>? connectivitySub;
  // A platform stream errors asynchronously when no ServicesBinding exists
  // (headless test containers) — a try/catch around listen cannot reach
  // the EventChannel's deferred onListen body, so probe the binding first
  // instead.
  final bindingReady = () {
    try {
      ServicesBinding.instance;
      return true;
    } on Object {
      return false;
    }
  }();
  if (bindingReady) {
    connectivitySub = ref
        .watch(networkIdentitySourceProvider)
        .identities()
        .listen(
          onConnectivity,
          onError: (Object error) => log('network identity: $error'),
        );
    // Bounded fallback for environments whose connectivity plugin never emits.
    startupFallbackTimer = Zone.root.createTimer(
      const Duration(milliseconds: 500),
      () {
        startupFallbackTimer = null;
        if (hasRealIdentity) return;
        fallbackElapsed = true;
        maybeNotifyAutoSource();
      },
    );
  } else {
    fallbackElapsed = true;
    maybeNotifyAutoSource();
  }
  ref.onDispose(() {
    startupFallbackTimer?.cancel();
    unawaited(() async {
      try {
        await connectivitySub?.cancel();
      } on Object {
        // Cancelling an EventChannel subscription needs the binary
        // messenger — absent in headless test containers.
      }
    }());
  });
  ref.onDispose(() => unawaited(policy.dispose()));
  return policy;
});

/// Persisted route memories. They outlive policy rebuilds so each
/// preference key has one writer — the policy and the image worker's
/// forwarded learning share these instances.
final fastRouteStoreProvider = Provider<PixivFastRouteStore>(
  (ref) =>
      PixivFastRouteStore(preferences: ref.watch(sharedPreferencesProvider)),
);
final routeKindStoreProvider = Provider<RouteKindStore>(
  (ref) => RouteKindStore(preferences: ref.watch(sharedPreferencesProvider)),
);
final imageRouteScoreStoreProvider = Provider<ImageRouteScoreStore>((ref) {
  final store = ImageRouteScoreStore(
    preferences: ref.watch(sharedPreferencesProvider),
  );
  ref.onDispose(() => unawaited(store.flush()));
  return store;
});

final pixivNetworkFactoryProvider = Provider<PixivNetworkFactory>((ref) {
  return PixivNetworkFactory(
    ref.watch(networkAccessPolicyProvider),
    // Read the mirror lazily per request instead of watching it: the auto
    // winner flips mid-session, and a watched rebuild would tear down every
    // pooled client for a pure URL-rewrite rule change. The closure always
    // resolves the current mirror.
    imageUrlRewriter: (url) => ref.read(imageMirrorProvider).rewrite(url),
  );
});
