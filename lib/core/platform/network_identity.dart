import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/network_restore_signal.dart' show offlineNetworkIdentity;
import 'platform_caps.dart';

/// Names the network the device is on. What the network policy learns
/// about routes is kept per identity, and a new identity starts a new
/// network revision.
abstract interface class NetworkIdentitySource {
  /// The current identity, then every change.
  Stream<String> identities();
}

/// Android: `NetworkIdentityChannel` names the default network `none`,
/// `vpn`, `mobile:<mccmnc>` (the data SIM's operator) or
/// `wifi:<fingerprint>`, so two carriers, or two data SIMs, are two
/// networks.
class ChannelNetworkIdentitySource implements NetworkIdentitySource {
  const ChannelNetworkIdentitySource([
    this._channel = const EventChannel('parfait/network_identity/events'),
  ]);

  final EventChannel _channel;

  @override
  Stream<String> identities() =>
      _channel.receiveBroadcastStream().map((event) => event as String);
}

/// Windows: the kinds of link `connectivity_plus` reports. No carrier is
/// visible there.
class ConnectivityNetworkIdentitySource implements NetworkIdentitySource {
  const ConnectivityNetworkIdentitySource();

  @override
  Stream<String> identities() async* {
    final connectivity = Connectivity();
    yield _identityOf(await connectivity.checkConnectivity());
    yield* connectivity.onConnectivityChanged.map(_identityOf);
  }

  /// Sorted, so a VPN layered over Wi-Fi differs from plain Wi-Fi: tunnel
  /// interfaces change which routes actually work.
  static String _identityOf(List<ConnectivityResult> results) {
    if (results.isEmpty ||
        results.every((result) => result == ConnectivityResult.none)) {
      return offlineNetworkIdentity;
    }
    final names = results.map((r) => r.name).toList()..sort();
    return names.join('+');
  }
}

final networkIdentitySourceProvider = Provider<NetworkIdentitySource>(
  (ref) => ref.watch(platformCapsProvider).isAndroid
      ? const ChannelNetworkIdentitySource()
      : const ConnectivityNetworkIdentitySource(),
);
