import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/image_mirror.dart';
import '../../settings/preference_keys.dart';
import '../pixiv_headers.dart';
import 'network_contracts.dart';
import 'network_policy.dart';

/// Auto image-source selection (`ImageSourceMode.auto`): races a cheap HEAD
/// probe to every candidate host through the *real* image ladder — the same
/// resolver, route memory and client pool the visible image pipeline uses —
/// and persists the winner scoped to the current network identity.
///
/// The race is the measurement: an unreachable candidate (e.g. pixiv.cat
/// inside the mainland) simply loses, and a stored winner from a different
/// network is ignored because the identity no longer matches.
class AutoImageSource {
  AutoImageSource({required SharedPreferencesAsync preferences})
    : _preferences = preferences;

  static const storageKey = PreferenceKeys.autoImageSource;

  /// A probe that gets no response inside this window loses the race.
  static const probeTimeout = Duration(seconds: 8);

  final SharedPreferencesAsync _preferences;
  Future<void> _writeTail = Future<void>.value();

  /// The persisted winner for [networkIdentity], or null when none applies
  /// (never raced on this network, or a corrupted blob). Winners are kept
  /// per identity — switching back to a known network reuses its measured
  /// source instead of re-racing.
  Future<String?> winnerFor(String networkIdentity) async {
    try {
      final winners = await _readWinners();
      final host = winners[networkIdentity];
      if (host is! String || !ImageMirror.autoCandidates.contains(host)) {
        return null;
      }
      return host;
    } on Object {
      return null;
    }
  }

  /// Serialized writes — a race completes at the same moment other network
  /// state is being persisted.
  Future<void> remember(String networkIdentity, String host) {
    final operation = _writeTail.then<void>((_) async {
      final winners = await _readWinners();
      winners[networkIdentity] = host;
      await _preferences.setString(storageKey, jsonEncode(winners));
    });
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<Map<String, dynamic>> _readWinners() async {
    final raw = await _preferences.getString(storageKey);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return <String, dynamic>{};
    return decoded;
  }

  /// Races a HEAD probe to every candidate through the image ladder and
  /// resolves to the first host that answers. Returns null when every
  /// candidate fails — callers keep the previous winner/direct then rather
  /// than degrading to an untested source.
  static Future<String?> race(
    NetworkAccessPolicy policy, {
    NetworkCancelSignal? cancelSignal,
  }) async {
    final completer = Completer<String?>();
    var pending = ImageMirror.autoCandidates.length;
    for (final host in ImageMirror.autoCandidates) {
      unawaited(
        _probe(policy, host, cancelSignal).then((ok) {
          if (ok) {
            if (!completer.isCompleted) completer.complete(host);
          } else if (--pending == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        }),
      );
    }
    return completer.future.timeout(probeTimeout, onTimeout: () => null);
  }

  static Future<bool> _probe(
    NetworkAccessPolicy policy,
    String host,
    NetworkCancelSignal? cancelSignal,
  ) async {
    try {
      final destination = policy.registry.require(
        Uri.https(host, '/'),
        PixivDestinationPurpose.image,
      );
      final response = await policy
          .runLadder<http.StreamedResponse>(
            destination: destination,
            cancelSignal: cancelSignal,
            canReplay: true,
            attempt: (route, routeUrl) async {
              final client = policy.clientFor(
                PixivDestinationPurpose.image,
                route,
                destination.canonicalHost,
              );
              final request = http.Request('HEAD', routeUrl)
                ..headers.addAll(PixivHeaders.image());
              final response = await client.send(request).timeout(probeTimeout);
              await response.stream.drain<void>();
              return response;
            },
          )
          .timeout(probeTimeout);
      // Any HTTP status counts: the goal is reachability, not a 200.
      return response.statusCode > 0;
    } on Object {
      return false;
    }
  }
}
