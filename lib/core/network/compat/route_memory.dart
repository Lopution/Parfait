import 'dart:io';

import 'image_route_discovery.dart';
import 'image_route_scores.dart';
import 'proven_origins.dart';

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

  /// What the last origin refresh came to; null before the first.
  Future<ProvenOrigins?> provenOrigins();

  /// An origin refresh came to [origins].
  void proveOrigins(ProvenOrigins origins);
}

/// Read/write contract for the per-network-identity route-kind hints.
abstract interface class RouteKindMemory {
  /// Group→kind map for [networkIdentity], or null when nothing was
  /// persisted for it.
  Future<Map<String, String>?> kindsFor(String networkIdentity);

  /// Remembers that [kind] won for [group] on [networkIdentity].
  Future<void> remember(String networkIdentity, String group, String kind);
}

/// Read/write contract for what pixiv's image route candidates scored per
/// network identity.
abstract interface class ImageRouteScoreMemory {
  /// What [networkIdentity] taught about each candidate; empty when it
  /// taught nothing yet.
  Future<Map<String, ImageRouteScore>> scoresFor(String networkIdentity);

  /// [sample] was taken on [networkIdentity].
  void record(String networkIdentity, ImageRouteSample sample);

  /// [candidate] answered a `Range` request on [networkIdentity] with a
  /// range, or with the whole file.
  void noteRanges(
    String networkIdentity,
    String candidate, {
    required bool served,
  });

  /// What front discovery last came to on [networkIdentity]; null when no
  /// run or label was ever kept there.
  Future<ImageRouteDiscovery?> discoveryFor(String networkIdentity);

  /// Front discovery on [networkIdentity] came to [discovery].
  void discovered(String networkIdentity, ImageRouteDiscovery discovery);
}
