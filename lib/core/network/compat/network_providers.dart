import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_policy.dart';

/// App-scoped network policy. Every native Pixiv API/OAuth/image/download
/// consumer receives this same revision and diagnostics owner.
final networkAccessPolicyProvider = Provider<NetworkAccessPolicy>((ref) {
  final policy = NetworkAccessPolicy();
  ref.onDispose(() => unawaited(policy.dispose()));
  return policy;
});

final pixivNetworkFactoryProvider = Provider<PixivNetworkFactory>((ref) {
  final factory = PixivNetworkFactory(ref.watch(networkAccessPolicyProvider));
  ref.onDispose(() => unawaited(factory.dispose()));
  return factory;
});
