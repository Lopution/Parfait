import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../settings/shared_preferences.dart';

import '../../settings/app_settings.dart';
import '../../settings/settings_controller.dart';
import 'network_contracts.dart' as contracts;
import 'network_policy.dart';
import 'network_fast_route_store.dart';

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
  // PixEz's compatibility transport is an internal performance tier, not a
  // user-facing security switch. It uses persisted/bootstrap host addresses
  // and remains behind the explicit directOnly escape hatch.
  final policy = NetworkAccessPolicy(
    dohEndpoints: dohEnabled ? endpoints : const [],
    echFrontHost: echFrontHost,
    insecureNoSniEnabled: true,
    fastRouteStore: PixivFastRouteStore(
      preferences: ref.watch(sharedPreferencesProvider),
    ),
    mode: switch (mode) {
      NetworkMode.automatic => contracts.NetworkMode.automatic,
      NetworkMode.directOnly => contracts.NetworkMode.directOnly,
    },
  );
  ref.onDispose(() => unawaited(policy.dispose()));
  return policy;
});

final pixivNetworkFactoryProvider = Provider<PixivNetworkFactory>((ref) {
  final factory = PixivNetworkFactory(ref.watch(networkAccessPolicyProvider));
  ref.onDispose(() => unawaited(factory.dispose()));
  return factory;
});
