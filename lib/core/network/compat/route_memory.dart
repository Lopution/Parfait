import 'dart:io';

import 'network_contracts.dart';
import 'secure_resolver.dart';

/// Read/write contract for the compatibility-tier host-address memory.
///
/// The interface exists so the image worker isolate can run the same
/// route ladder with an in-memory implementation while persistence stays
/// on the main isolate (SharedPreferences is platform-channel backed and
/// therefore unavailable off the main isolate).
abstract interface class FastRouteMemory {
  /// Last known public bootstrap address for [host], or null.
  Future<InternetAddress?> addressFor(String host);

  /// Records [address] as a working address for [host].
  Future<void> remember(String host, InternetAddress address);

  /// Best-effort refresh of [host]'s address through [resolver].
  Future<void> refresh(
    String host, {
    required SecureResolver resolver,
    required NetworkRevision revision,
  });
}

/// Read/write contract for the per-network-identity route-kind hints.
abstract interface class RouteKindMemory {
  /// Group→kind map for [networkIdentity], or null when nothing was
  /// persisted for it.
  Future<Map<String, String>?> kindsFor(String networkIdentity);

  /// Remembers that [kind] won for [group] on [networkIdentity].
  Future<void> remember(String networkIdentity, String group, String kind);
}
