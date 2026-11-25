/// In-memory route and origin tracking helpers owned by `NetworkAccessPolicy`.
library;

import 'dart:io';

import 'network_fast_route_store.dart';
import 'network_contracts.dart';

/// A pixiv image host's failing origin addresses: an address other than
/// the built-in ones that fails [skipAfter] loads in a row is skipped for
/// [skipFor].
class OriginHealth {
  static const skipAfter = 3;
  static const skipFor = Duration(days: 1);

  final _failures = <String, int>{};
  final _skipped = <String, DateTime>{};

  void failed(String address, DateTime now) {
    final builtIn = PixivFastRouteStore.originAddresses.any(
      (origin) => origin.address == address,
    );
    if (builtIn) return;
    final failures = (_failures[address] ?? 0) + 1;
    if (failures >= skipAfter) {
      _failures.remove(address);
      _skipped[address] = now;
    } else {
      _failures[address] = failures;
    }
  }

  void served(String address) => _failures.remove(address);

  bool skips(String address, DateTime now) {
    final since = _skipped[address];
    return since != null && now.difference(since) < skipFor;
  }
}

/// A pixiv image host's origin addresses and the one in use, which moves
/// on after a failure there, past the addresses [_health] skips.
class OriginBook {
  OriginBook(
    this.addresses, {
    required OriginHealth health,
    required DateTime Function() clock,
  }) : _health = health,
       _clock = clock {
    if (_health.skips(current.address, _clock())) _moveOn();
  }

  final List<InternetAddress> addresses;
  final OriginHealth _health;
  final DateTime Function() _clock;
  int _index = 0;

  InternetAddress get current => addresses[_index];

  void movedOff(InternetAddress address) {
    if (address.address == current.address) _moveOn();
  }

  void _moveOn() {
    final now = _clock();
    for (var i = 0; i < addresses.length; i++) {
      _index = (_index + 1) % addresses.length;
      if (!_health.skips(current.address, now)) break;
    }
  }
}

class HostRouteMemory {
  HostRouteMemory(
    this.address, {
    required this.kind,
    required this.dnsSource,
    required this.ttl,
    required this.createdAt,
    required this.networkIdentity,
    this.echConfig,
  });

  final InternetAddress? address;
  final NetworkRouteKind kind;
  final DnsSource dnsSource;
  final Duration ttl;
  final DateTime createdAt;
  final String networkIdentity;
  final List<int>? echConfig;

  bool isFresh(DateTime now) =>
      !now.isBefore(createdAt) && now.difference(createdAt) < ttl;

  bool isUsable(DateTime now, String currentNetworkIdentity) =>
      networkIdentity == currentNetworkIdentity && isFresh(now);

  /// Rebuilds the route at the [revision] seen by [NetworkRoute.kind].
  NetworkRoute routeFor(NetworkRevision revision) => NetworkRoute.remembered(
    revision,
    kind,
    address,
    dnsSource: dnsSource,
    ttl: ttl,
    echConfig: echConfig,
  );

  HostRouteMemory withIdentity(String identity) => HostRouteMemory(
    address,
    kind: kind,
    dnsSource: dnsSource,
    ttl: ttl,
    createdAt: createdAt,
    networkIdentity: identity,
    echConfig: echConfig,
  );
}

class RouteGroupMemory {
  const RouteGroupMemory({
    required this.kind,
    required this.ttl,
    required this.createdAt,
    required this.networkIdentity,
  });

  final NetworkRouteKind kind;
  final Duration ttl;
  final DateTime createdAt;
  final String networkIdentity;

  bool isUsable(DateTime now, String currentNetworkIdentity) =>
      networkIdentity == currentNetworkIdentity &&
      !now.isBefore(createdAt) &&
      now.difference(createdAt) < ttl;

  RouteGroupMemory withIdentity(String identity) => RouteGroupMemory(
    kind: kind,
    ttl: ttl,
    createdAt: createdAt,
    networkIdentity: identity,
  );
}
