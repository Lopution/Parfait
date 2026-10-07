import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The connectivity identity of a device with no network at all.
const offlineNetworkIdentity = 'none';

/// Counts the moments the device regains a network after having none
/// (HCI 9). Error states caused by the lost connection listen to it and
/// retry once per restore; a retry that fails again simply shows its error.
///
/// Fed by the connectivity listener in `networkAccessPolicyProvider`. A
/// switch between two live networks (Wi-Fi to cellular, a VPN coming up)
/// is not a restore: requests on the old network did not fail for lack of
/// one.
class NetworkRestoreSignal extends Notifier<int> {
  String? _identity;

  @override
  int build() => 0;

  /// Records the current connectivity identity.
  void observe(String identity) {
    final previous = _identity;
    _identity = identity;
    if (previous == offlineNetworkIdentity &&
        identity != offlineNetworkIdentity) {
      state++;
    }
  }
}

final networkRestoreSignalProvider =
    NotifierProvider<NetworkRestoreSignal, int>(NetworkRestoreSignal.new);
