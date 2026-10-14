import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/crash_log.dart';
import '../network/local_network_address.dart';
import '../settings/image_mirror.dart';
import '../settings/settings_controller.dart';
import 'platform_caps.dart';

abstract final class _LocalNetworkMethods {
  static const channel = 'parfait/local_network';
  static const isGranted = 'isGranted';
  static const request = 'request';
  static const proxyHost = 'proxyHost';
}

/// Android 17's local network permission ("nearby devices").
abstract interface class LocalNetworkPermission {
  /// True when the app may reach the local network: granted, or a system
  /// without the restriction.
  Future<bool> isGranted();

  /// Shows the system permission dialog; true when granted. Once the user
  /// has denied it for good the system answers no without a dialog.
  Future<bool> request();

  /// Host of the system HTTP proxy, which WebView connects through; null
  /// when there is none.
  Future<String?> proxyHost();
}

class MethodChannelLocalNetworkPermission implements LocalNetworkPermission {
  const MethodChannelLocalNetworkPermission([
    this._channel = const MethodChannel(_LocalNetworkMethods.channel),
  ]);

  final MethodChannel _channel;

  @override
  Future<bool> isGranted() async =>
      await _channel.invokeMethod<bool>(_LocalNetworkMethods.isGranted) ??
      false;

  @override
  Future<bool> request() async =>
      await _channel.invokeMethod<bool>(_LocalNetworkMethods.request) ?? false;

  @override
  Future<String?> proxyHost() =>
      _channel.invokeMethod<String>(_LocalNetworkMethods.proxyHost);
}

/// Desktop and test fallback: nothing restricts the local network.
class UnrestrictedLocalNetwork implements LocalNetworkPermission {
  const UnrestrictedLocalNetwork();

  @override
  Future<bool> isGranted() async => true;

  @override
  Future<bool> request() async => true;

  @override
  Future<String?> proxyHost() async => null;
}

/// Tells which hosts the app may not reach, and asks for the permission
/// with the system dialog when a request needs it.
class LocalNetworkGate {
  LocalNetworkGate(
    this.permission, {
    @visibleForTesting
    Future<List<InternetAddress>> Function(String host) lookup =
        InternetAddress.lookup,
  }) : _lookup = lookup;

  final LocalNetworkPermission permission;
  final Future<List<InternetAddress>> Function(String host) _lookup;
  Future<bool>? _request;

  static const _lookupTimeout = Duration(seconds: 3);

  /// An IP literal is classified as is and a `.local` name is always local;
  /// any other name is looked up through the system resolver, which the
  /// restriction leaves alone (port 53). A name that does not resolve is
  /// not called local: the request itself reports that failure.
  Future<bool> isLocalHost(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return isLocalNetworkAddress(literal);
    if (host.toLowerCase().endsWith('.local')) return true;
    try {
      final addresses = await _lookup(host).timeout(_lookupTimeout);
      return addresses.any(isLocalNetworkAddress);
    } on Object {
      return false;
    }
  }

  /// The [hosts] the app may not reach now.
  Future<Set<String>> blocked(Iterable<String> hosts) async {
    if (await permission.isGranted()) return const {};
    final blocked = <String>{};
    for (final host in hosts) {
      if (await isLocalHost(host)) blocked.add(host);
    }
    return blocked;
  }

  /// Shows the system dialog; callers waiting at the same time share it.
  Future<bool> request() =>
      _request ??= permission.request().whenComplete(() => _request = null);

  /// Runs before a request to [host]: when the app may not reach it, asks
  /// with the system dialog and throws [LocalNetworkBlocked] if the answer
  /// is no, instead of letting the connect hang until it times out.
  Future<void> ensure(String host) async {
    if ((await blocked([host])).isEmpty) return;
    if (await request()) return;
    throw LocalNetworkBlocked(host);
  }

  /// [ensure] for the system proxy, before a WebView loads a page.
  Future<void> ensureProxy() async {
    final proxy = await permission.proxyHost();
    if (proxy != null) await ensure(proxy);
  }
}

final localNetworkGateProvider = Provider<LocalNetworkGate>(
  (ref) => LocalNetworkGate(
    ref.watch(platformCapsProvider).isAndroid
        ? const MethodChannelLocalNetworkPermission()
        : const UnrestrictedLocalNetwork(),
  ),
);

/// Hosts the network policy connects to that the user typed in, so may sit
/// on the local network: a custom image source and DoH endpoints. Built-in
/// hosts are public. The system proxy joins them when evaluated. Null until
/// the settings load, so startup evaluates (and asks) once.
final _configuredHostsProvider = Provider<Set<String>?>((ref) {
  final loaded = ref.watch(
    settingsProvider.select((async) => async.value != null),
  );
  if (!loaded) return null;
  final source = ref.watch(
    settingsProvider.select((async) => async.value?.imageSource),
  );
  final dohOverride = ref.watch(
    settingsProvider.select((async) => async.value?.dohEndpointOverride),
  );
  return {
    if (source != null && ImageSourceMode.fromHost(source) == null)
      ?Uri.tryParse(source)?.host,
    if (dohOverride != null && ref.watch(dohEnabledProvider))
      for (final endpoint in ref.watch(dohEndpointsProvider))
        ?Uri.tryParse(endpoint)?.host,
  }..remove('');
});

/// The configured hosts the network policy must not connect to: requests
/// to them fail at once with [LocalNetworkBlocked] instead of hanging. The
/// system proxy is evaluated too: WebView pages connect through it.
///
/// When the set gains a host, the system dialog asks for the permission
/// once; a grant empties it. Re-evaluated when the hosts change and on
/// [refresh] (the app returning to the foreground: the user may have
/// changed the permission in the system settings meanwhile).
class LocalNetworkBlockedHosts extends Notifier<Set<String>> {
  final Set<String> _asked = {};
  int _generation = 0;

  @override
  Set<String> build() {
    final configured = ref.watch(_configuredHostsProvider);
    if (configured != null) unawaited(_evaluate(configured));
    return stateOrNull ?? const {};
  }

  void refresh() {
    final configured = ref.read(_configuredHostsProvider);
    if (configured != null) unawaited(_evaluate(configured));
  }

  Future<void> _evaluate(Set<String> configured) async {
    final generation = ++_generation;
    final gate = ref.read(localNetworkGateProvider);
    try {
      final proxy = await gate.permission.proxyHost();
      var blocked = await gate.blocked({...configured, ?proxy});
      if (!ref.mounted || generation != _generation) return;
      if (!_asked.containsAll(blocked)) {
        _asked.addAll(blocked);
        // Requests made while the dialog is up must fail too, not hang.
        _apply(generation, blocked);
        if (await gate.request()) blocked = const {};
      }
      _apply(generation, blocked);
    } on Exception catch (error, stack) {
      // The channel failed: the set stays as it was and requests run as
      // they would without the check.
      CrashLog.record(error, stack);
    }
  }

  void _apply(int generation, Set<String> blocked) {
    if (!ref.mounted || generation != _generation) return;
    if (!setEquals(blocked, stateOrNull)) state = blocked;
  }
}

final localNetworkBlockedHostsProvider =
    NotifierProvider<LocalNetworkBlockedHosts, Set<String>>(
      LocalNetworkBlockedHosts.new,
    );
