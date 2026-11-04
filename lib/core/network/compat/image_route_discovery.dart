import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'image_route_scores.dart';

/// Cloudflare's IPv4 prefixes, from `https://www.cloudflare.com/ips-v4` on
/// 2026-11-03. They change rarely; a stale list only narrows the sample.
abstract final class CloudflarePrefixes {
  static const all = [
    '173.245.48.0/20',
    '103.21.244.0/22',
    '103.22.200.0/22',
    '103.31.4.0/22',
    '141.101.64.0/18',
    '108.162.192.0/18',
    '190.93.240.0/20',
    '188.114.96.0/20',
    '197.234.240.0/22',
    '198.41.128.0/17',
    '162.158.0.0/15',
    '104.16.0.0/13',
    '104.24.0.0/14',
    '172.64.0.0/13',
    '131.0.72.0/22',
  ];

  static final List<(int base, int size)> _ranges = [
    for (final prefix in all) _parse(prefix),
  ];

  static final int _total = _ranges.fold(0, (sum, range) => sum + range.$2);

  /// [count] distinct host addresses (no network or broadcast address) at
  /// random, each prefix chosen in proportion to its size, none of them
  /// in [exclude].
  static List<InternetAddress> sample(
    math.Random random,
    int count, {
    Set<String> exclude = const {},
  }) {
    final picked = <String, InternetAddress>{};
    while (picked.length < count) {
      var pick = random.nextInt(_total);
      for (final (base, size) in _ranges) {
        if (pick >= size) {
          pick -= size;
          continue;
        }
        final value = base + 1 + random.nextInt(size - 2);
        final address = InternetAddress.fromRawAddress(
          Uint8List(4)..buffer.asByteData().setUint32(0, value),
        );
        if (!exclude.contains(address.address)) {
          picked[address.address] = address;
        }
        break;
      }
    }
    return picked.values.toList(growable: false);
  }

  static (int, int) _parse(String prefix) {
    final [address, bits] = prefix.split('/');
    final raw = InternetAddress(address).rawAddress;
    return (
      ByteData.sublistView(raw).getUint32(0),
      1 << (32 - int.parse(bits)),
    );
  }
}

/// A Cloudflare front beyond those the ECH config names: the seed, or one
/// a discovery run kept.
class ExtraFront {
  const ExtraFront(this.address, {required this.at, this.worseSince});

  static ExtraFront? fromJson(Object? json) {
    if (json is! Map) return null;
    final address = InternetAddress.tryParse('${json['address']}');
    final at = json['at'];
    final worseSince = json['worseSince'];
    if (address == null || at is! int) return null;
    return ExtraFront(
      address,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      worseSince: worseSince is int
          ? DateTime.fromMillisecondsSinceEpoch(worseSince)
          : null,
    );
  }

  final InternetAddress address;

  /// When it was kept; the seed's is the epoch.
  final DateTime at;

  /// Since when it has cost [FrontDiscovery.worseRatio] times the best
  /// other candidate, without a sample in between that did better.
  final DateTime? worseSince;

  ExtraFront worse(DateTime? since) =>
      ExtraFront(address, at: at, worseSince: since);

  Map<String, Object> toJson() => {
    'address': address.address,
    'at': at.millisecondsSinceEpoch,
    'worseSince': ?worseSince?.millisecondsSinceEpoch,
  };
}

/// The Cloudflare colo a front lands in on one network, and when it was
/// read.
class FrontColo {
  const FrontColo(this.colo, {required this.at});

  static FrontColo? fromJson(Object? json) {
    if (json is! Map) return null;
    final colo = json['colo'];
    final at = json['at'];
    if (colo is! String || at is! int) return null;
    return FrontColo(colo, at: DateTime.fromMillisecondsSinceEpoch(at));
  }

  /// An IATA code, such as `HKG`.
  final String colo;
  final DateTime at;

  Map<String, Object> toJson() => {
    'colo': colo,
    'at': at.millisecondsSinceEpoch,
  };
}

/// What front discovery learned on one network: the Cloudflare fronts
/// pixiv's image hosts route through beside those the ECH config names,
/// and where each front lands.
class ImageRouteDiscovery {
  const ImageRouteDiscovery({
    required this.fronts,
    this.rejected = const {},
    this.lastRunAt,
    this.fruitless = 0,
    this.colos = const {},
  });

  /// A network no run has been on: the seed front alone.
  static final initial = ImageRouteDiscovery(
    fronts: [ExtraFront(seedFront, at: DateTime.fromMillisecondsSinceEpoch(0))],
  );

  /// A Cloudflare address that served the ECH front from Hong Kong where
  /// the fronts the ECH config names were routed to Los Angeles (Unicom,
  /// 2026-11-03).
  static final seedFront = InternetAddress('162.159.152.4');

  /// ECH candidates per image host: the config's fronts (at most
  /// [maxNamedFronts]), then [fronts] while there is room.
  static const maxFronts = 4;
  static const maxNamedFronts = 3;

  /// A damaged entry starts over.
  static ImageRouteDiscovery fromJson(Object? json) {
    if (json is! Map) return initial;
    final fronts = json['fronts'];
    final rejected = json['rejected'];
    final lastRunAt = json['lastRunAt'];
    final fruitless = json['fruitless'];
    final colos = json['colos'];
    if (fronts is! List) return initial;
    return ImageRouteDiscovery(
      fronts: [for (final front in fronts) ?ExtraFront.fromJson(front)],
      rejected: {
        if (rejected is Map)
          for (final MapEntry(:key, :value) in rejected.entries)
            if (key is String && value is int)
              key: DateTime.fromMillisecondsSinceEpoch(value),
      },
      lastRunAt: lastRunAt is int
          ? DateTime.fromMillisecondsSinceEpoch(lastRunAt)
          : null,
      fruitless: fruitless is int ? fruitless : 0,
      colos: {
        if (colos is Map)
          for (final MapEntry(:key, :value) in colos.entries)
            if (key is String) key: ?FrontColo.fromJson(value),
      },
    );
  }

  /// Best first; the ladder takes as many as there is room for.
  final List<ExtraFront> fronts;

  /// Addresses a run found unfit, and when: none is sampled again for a
  /// day.
  final Map<String, DateTime> rejected;
  final DateTime? lastRunAt;

  /// Runs in a row that kept no front: each doubles the wait before the
  /// next.
  final int fruitless;

  /// By address: every front's, those the ECH config names included.
  final Map<String, FrontColo> colos;

  ImageRouteDiscovery copyWith({
    List<ExtraFront>? fronts,
    Map<String, DateTime>? rejected,
    DateTime? lastRunAt,
    int? fruitless,
    Map<String, FrontColo>? colos,
  }) => ImageRouteDiscovery(
    fronts: fronts ?? this.fronts,
    rejected: rejected ?? this.rejected,
    lastRunAt: lastRunAt ?? this.lastRunAt,
    fruitless: fruitless ?? this.fruitless,
    colos: colos ?? this.colos,
  );

  Map<String, Object> toJson() => {
    'fronts': [for (final front in fronts) front.toJson()],
    'rejected': {
      for (final MapEntry(:key, :value) in rejected.entries)
        key: value.millisecondsSinceEpoch,
    },
    'lastRunAt': ?lastRunAt?.millisecondsSinceEpoch,
    'fruitless': fruitless,
    'colos': {
      for (final MapEntry(:key, :value) in colos.entries) key: value.toJson(),
    },
  };

  /// The ECH fronts of pixiv's image hosts: those [named] by the ECH
  /// config, then [fronts], at most [maxFronts].
  List<InternetAddress> frontsAfter(Iterable<InternetAddress> named) {
    final all = <String, InternetAddress>{};
    for (final front in named.take(maxNamedFronts)) {
      all[front.address] = front;
    }
    for (final front in fronts) {
      if (all.length >= maxFronts) break;
      all.putIfAbsent(front.address.address, () => front.address);
    }
    return all.values.toList(growable: false);
  }
}

/// A Cloudflare address a discovery run fetched an image through.
class FrontProbe {
  const FrontProbe(this.address, {required this.colo, required this.cost});

  final InternetAddress address;
  final String colo;

  /// Seconds for 100 KB, as [ImageRouteSample.load] counts it.
  final double cost;
}

/// The route candidate key of the ECH route through [front].
String echCandidate(InternetAddress front) => 'ech:${front.address}';
