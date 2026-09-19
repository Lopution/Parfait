import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../settings/shared_preferences.dart';

import '../../settings/app_settings.dart';
import '../../settings/settings_controller.dart';
import 'network_contracts.dart' as contracts;
import 'auto_image_source.dart';
import 'pixiv_network_factory.dart';
import 'network_policy.dart';
import 'network_fast_route_store.dart';
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
  // PixEz's compatibility transport is an internal performance tier, not a
  // user-facing security switch. It uses persisted/bootstrap host addresses
  // and remains behind the explicit directOnly escape hatch.
  final policy = NetworkAccessPolicy(
    registry: contracts.PixivDestinationRegistry(
      extraImageHosts: imageMirrorHosts,
    ),
    dohEndpoints: dohEnabled ? endpoints : const [],
    echFrontHost: echFrontHost,
    insecureNoSniEnabled: true,
    fastRouteStore: PixivFastRouteStore(
      preferences: ref.watch(sharedPreferencesProvider),
    ),
    routeKindStore: RouteKindStore(
      preferences: ref.watch(sharedPreferencesProvider),
    ),
    mode: switch (mode) {
      NetworkMode.automatic => contracts.NetworkMode.automatic,
      NetworkMode.directOnly => contracts.NetworkMode.directOnly,
    },
  );

  // A network change (Wi-Fi↔cellular, VPN toggle, captive portal escape)
  // invalidates every learned route, pooled client and cooldown — the
  // remembered winner on the old network is frequently unreachable on the
  // new one. The identity string also keys the persisted route kinds, so
  // returning to a known network re-seeds its last-good tiers.
  var connectivityIdentity = 'initial';
  final autoSource = AutoImageSource(
    preferences: ref.watch(sharedPreferencesProvider),
  );

  /// In auto mode a network-identity change invalidates the remembered
  /// winner the same way it invalidates route memory — re-seed from the
  /// identity-scoped store, then re-race. The winner update rebuilds
  /// [imageMirrorProvider], so image URLs start rewriting through it.
  /// Concurrent calls are deduped; a failed-winner re-race is throttled so
  /// a dead candidate cannot make every scrolling image re-trigger probes.
  var autoRaceInFlight = false;
  DateTime? lastAutoRaceAt;
  void resolveAutoSource(String identity, {bool throttled = false}) {
    if (ref.read(settingsProvider).value?.imageSource !=
        ImageSourceMode.auto.host) {
      return;
    }
    if (autoRaceInFlight) return;
    final now = DateTime.now();
    if (throttled &&
        lastAutoRaceAt != null &&
        now.difference(lastAutoRaceAt!) < const Duration(seconds: 30)) {
      return;
    }
    autoRaceInFlight = true;
    lastAutoRaceAt = now;
    unawaited(() async {
      try {
        final persisted = await autoSource.winnerFor(identity);
        if (persisted != null) {
          ref.read(autoImageSourceWinnerProvider.notifier).set(persisted);
        }
        final winner = await AutoImageSource.race(policy);
        if (winner == null) return; // all candidates failed: keep current
        ref.read(autoImageSourceWinnerProvider.notifier).set(winner);
        unawaited(autoSource.remember(identity, winner));
      } finally {
        autoRaceInFlight = false;
      }
    }());
  }

  // A dead mirror winner (every ladder tier exhausted) is dropped back to
  // direct and the candidates are re-raced — the next reachable source
  // takes over without user intervention.
  policy.onImageHostExhausted = (host) {
    if (ref.read(autoImageSourceWinnerProvider) != host) return;
    ref.read(autoImageSourceWinnerProvider.notifier).set(null);
    resolveAutoSource(connectivityIdentity, throttled: true);
  };

  void onConnectivity(List<ConnectivityResult> results) {
    final identity = _connectivityIdentity(results);
    if (identity == connectivityIdentity) return;
    connectivityIdentity = identity;
    policy.advanceNetworkRevision(networkIdentity: identity);
    resolveAutoSource(identity);
  }

  StreamSubscription<List<ConnectivityResult>>? connectivitySub;
  try {
    connectivitySub = Connectivity().onConnectivityChanged.listen(
      onConnectivity,
      onError: (_) {},
    );
    unawaited(
      Connectivity().checkConnectivity().then(onConnectivity, onError: (_) {}),
    );
  } on Object {
    // The plugin is unavailable in some embedders/tests — the policy then
    // simply never sees an identity change, same as before this wiring.
  }
  // Even with no connectivity events (plugin absent/failed) auto mode still
  // gets one race under the 'initial' identity.
  resolveAutoSource(connectivityIdentity);
  ref.onDispose(() => unawaited(connectivitySub?.cancel()));
  ref.onDispose(() => unawaited(policy.dispose()));
  return policy;
});

/// Deterministic identity for a connectivity snapshot. Sorted so a VPN
/// layered over Wi-Fi differs from plain Wi-Fi — tunnel interfaces change
/// which routes actually work.
String _connectivityIdentity(List<ConnectivityResult> results) {
  if (results.isEmpty) return 'none';
  final names = results.map((r) => r.name).toList()..sort();
  return names.join('+');
}

final pixivNetworkFactoryProvider = Provider<PixivNetworkFactory>((ref) {
  final factory = PixivNetworkFactory(
    ref.watch(networkAccessPolicyProvider),
    imageUrlRewriter: ref.watch(imageMirrorProvider).rewrite,
  );
  ref.onDispose(() => unawaited(factory.dispose()));
  return factory;
});
