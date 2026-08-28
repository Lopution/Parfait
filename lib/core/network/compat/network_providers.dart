import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network_policy.dart';
import '../../platform/webkit_capabilities_channel.dart';
import 'webview_route.dart';

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

/// WebView direct navigation is allowed only after exact destination
/// validation. Compatibility loopback remains unavailable until a concrete
/// AndroidX WebKit implementation and its capability evidence are present.
final webViewRoutePolicyProvider = Provider<WebViewRoutePolicy>((ref) {
  final policy = ref.watch(networkAccessPolicyProvider);
  return WebViewRoutePolicy(
    registry: policy.registry,
    capabilities: MethodChannelWebKitCapabilities(),
    revisionProvider: () => policy.revision,
  );
});
