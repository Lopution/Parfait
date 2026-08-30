import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import 'network_policy.dart';

/// App-scoped network policy. Every native Pixiv API/OAuth/image/download
/// consumer receives this same revision and diagnostics owner.
///
/// DoH settings are watched so an enable/endpoint change rebuilds the
/// policy's resolver; pooled clients are closed by the old policy's dispose.
final networkAccessPolicyProvider = Provider<NetworkAccessPolicy>((ref) {
  final dohEnabled = ref.watch(dohEnabledProvider);
  final endpoints = ref.watch(dohEndpointsProvider);
  final echFrontHost = ref.watch(echFrontHostProvider);
  final insecureNoSni = ref.watch(insecureNoSniEnabledProvider);
  final policy = NetworkAccessPolicy(
    dohEndpoints: dohEnabled ? endpoints : const [],
    echFrontHost: echFrontHost,
    insecureNoSniEnabled: insecureNoSni,
  );
  ref.onDispose(() => unawaited(policy.dispose()));
  return policy;
});

final pixivNetworkFactoryProvider = Provider<PixivNetworkFactory>((ref) {
  final factory = PixivNetworkFactory(ref.watch(networkAccessPolicyProvider));
  ref.onDispose(() => unawaited(factory.dispose()));
  return factory;
});
