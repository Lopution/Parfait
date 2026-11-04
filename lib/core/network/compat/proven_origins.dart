import 'dart:io';

import 'network_fast_route_store.dart' show PixivFastRouteStore;
import 'secure_resolver.dart' show isPublicNetworkAddress;

/// Pixiv's image origin addresses beyond the built-in ten
/// ([PixivFastRouteStore.originAddresses]) that encrypted DNS named and an
/// image proved, and when DNS was last asked.
class ProvenOrigins {
  const ProvenOrigins(this.addresses, {required this.refreshedAt});

  /// A damaged record is asked again.
  static ProvenOrigins? fromJson(Object? json) {
    if (json is! Map) return null;
    final addresses = json['addresses'];
    final refreshedAt = json['refreshedAt'];
    if (addresses is! List || refreshedAt is! int) return null;
    return ProvenOrigins([
      for (final address in addresses)
        if (InternetAddress.tryParse('$address') case final parsed?
            when isPublicNetworkAddress(parsed))
          parsed,
    ], refreshedAt: DateTime.fromMillisecondsSinceEpoch(refreshedAt));
  }

  final List<InternetAddress> addresses;
  final DateTime refreshedAt;

  Map<String, Object> toJson() => {
    'addresses': [for (final address in addresses) address.address],
    'refreshedAt': refreshedAt.millisecondsSinceEpoch,
  };
}
