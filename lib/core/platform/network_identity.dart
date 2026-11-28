import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../log.dart';
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

/// Windows/macOS/Linux: the kinds of link `connectivity_plus` reports. No
/// carrier is visible there.
class ConnectivityNetworkIdentitySource implements NetworkIdentitySource {
  const ConnectivityNetworkIdentitySource({
    Connectivity Function()? createConnectivity,
  }) : _createConnectivity = createConnectivity;

  final Connectivity Function()? _createConnectivity;

  /// Returns true when a Linux host has no `org.freedesktop.NetworkManager`
  /// DBus service (or denies access to it), where subscribing to
  /// `connectivity_plus_linux`'s `onConnectivityChanged` would leak an
  /// unhandled async exception from `StreamController.onListen`.
  static bool isMissingLinuxNetworkManagerError(Object error) {
    final text = error.toString();
    return text.contains('org.freedesktop.DBus.Error.ServiceUnknown') ||
        text.contains('org.freedesktop.DBus.Error.AccessDenied') ||
        text.contains('org.freedesktop.NetworkManager');
  }

  /// A failed first look is logged and skipped: an error inside this
  /// generator would end the stream before it follows any change. When Linux
  /// has no `org.freedesktop.NetworkManager` DBus service, stop after logging
  /// instead of subscribing; runtime stream errors are also logged via
  /// `handleError` rather than leaking out of the zone.
  @override
  Stream<String> identities() async* {
    final connectivity = (_createConnectivity ?? Connectivity.new)();
    try {
      yield _identityOf(await connectivity.checkConnectivity());
    } on Object catch (error) {
      log('network identity: $error');
      if (isMissingLinuxNetworkManagerError(error)) {
        return;
      }
    }
    yield* connectivity.onConnectivityChanged
        .handleError((Object error) => log('network identity: $error'))
        .map(_identityOf);
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
