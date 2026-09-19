import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/image_mirror.dart';
import '../../settings/preference_keys.dart';
import '../pixiv_headers.dart';
import 'network_contracts.dart';
import 'network_policy.dart';

/// Auto image-source selection (`ImageSourceMode.auto`): races a bounded
/// real-image GET to every candidate host through the *real* image ladder —
/// the same resolver, route memory and client pool the visible image
/// pipeline uses — and persists the winner scoped to the current network
/// identity.
///
/// The race measures sustained transfer, not just TTFB: every candidate
/// fetches the same thumbnail and downloads up to [_probeBytes] of its body,
/// and the host with the highest bytes/second wins. A candidate that only
/// answers quickly but transfers poorly (fast TLS, starved pipe) no longer
/// takes the win over a genuinely fast one.
class AutoImageSource {
  AutoImageSource({required SharedPreferencesAsync preferences})
    : _preferences = preferences;

  static const storageKey = PreferenceKeys.autoImageSource;

  /// A probe that gets no response inside this window loses the race.
  static const probeTimeout = Duration(seconds: 8);

  /// Upper bound of body bytes a probe reads — enough to average out the
  /// handshake tail, small enough that racing four candidates stays cheap
  /// (~64KB each worst case).
  static const probeBytes = 64 * 1024;

  /// Minimum body bytes before a measurement counts toward the throughput
  /// ranking; below it the elapsed is dominated by latency, not bandwidth.
  static const minMeasuredBytes = 8 * 1024;

  /// The thumbnail every candidate fetches. It is the same well-known pximg
  /// image PixEz uses for its mirror check — stable for years and served by
  /// every mirror host, so the measurement compares hosts, not objects.
  static const probePath =
      '/c/360x360_70/img-master/img/2016/04/29/03/33/27/'
      '56585648_p0_square1200.jpg';

  final SharedPreferencesAsync _preferences;
  Future<void> _writeTail = Future<void>.value();

  /// The persisted winner for [networkIdentity], or null when none applies
  /// (never raced on this network, or a corrupted blob). Winners are kept
  /// per identity — switching back to a known network reuses its measured
  /// source instead of re-racing.
  Future<String?> winnerFor(String networkIdentity) async =>
      (await measurementFor(networkIdentity))?.host;

  /// The persisted winner plus its measured bytes/second for
  /// [networkIdentity]. Accepts the legacy plain-string winner form written
  /// before throughput was recorded (bps reports null then).
  Future<({String host, double? bps})?> measurementFor(
    String networkIdentity,
  ) async {
    try {
      final winners = await _readWinners();
      final entry = winners[networkIdentity];
      final host = switch (entry) {
        String() => entry,
        Map<String, dynamic>() => entry['host'] as String?,
        _ => null,
      };
      if (host == null || !ImageMirror.autoCandidates.contains(host)) {
        return null;
      }
      final bps = entry is Map<String, dynamic>
          ? (entry['bps'] as num?)?.toDouble()
          : null;
      return (host: host, bps: bps);
    } on Object {
      return null;
    }
  }

  /// Serialized writes — a race completes at the same moment other network
  /// state is being persisted.
  Future<void> remember(String networkIdentity, String host, {double? bps}) {
    final operation = _writeTail.then<void>((_) async {
      final winners = await _readWinners();
      winners[networkIdentity] = <String, dynamic>{'host': host, 'bps': ?bps};
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

  /// Races a bounded image GET to every candidate through the image ladder
  /// and resolves to the host with the highest measured throughput plus the
  /// winning measurement itself. Returns null when every candidate fails —
  /// callers keep the previous winner/direct then rather than degrading to
  /// an untested source.
  static Future<({String host, double? bps})?> race(
    NetworkAccessPolicy policy, {
    NetworkCancelSignal? cancelSignal,
  }) async {
    final samples = await Future.wait(
      ImageMirror.autoCandidates.map(
        (host) => _probe(policy, host, cancelSignal),
      ),
    );
    _ProbeSample? best;
    for (final sample in samples) {
      if (sample == null) continue;
      if (sample.bytesPerSec != null &&
          (best?.bytesPerSec == null ||
              sample.bytesPerSec! > best!.bytesPerSec!)) {
        best = sample;
      }
    }
    // No usable throughput measurement (tiny/empty bodies everywhere): fall
    // back to the first reachable candidate — reachability still beats a
    // dead host.
    best ??= samples.whereType<_ProbeSample>().firstOrNull;
    if (best == null) return null;
    return (host: best.host, bps: best.bytesPerSec);
  }

  static Future<_ProbeSample?> _probe(
    NetworkAccessPolicy policy,
    String host,
    NetworkCancelSignal? cancelSignal,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final destination = policy.registry.require(
        Uri.https(host, probePath),
        PixivDestinationPurpose.image,
      );
      var bytes = 0;
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
              final request = http.Request('GET', routeUrl)
                ..headers.addAll(PixivHeaders.image());
              return client.send(request).timeout(probeTimeout);
            },
          )
          .timeout(probeTimeout);
      try {
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          return _ProbeSample(host, null);
        }
        await for (final chunk in response.stream.timeout(probeTimeout)) {
          bytes += chunk.length;
          if (bytes >= probeBytes) break;
        }
      } finally {
        stopwatch.stop();
      }
      if (bytes == 0) return _ProbeSample(host, null);
      final seconds = stopwatch.elapsedMicroseconds / 1e6;
      final bps = bytes >= minMeasuredBytes ? bytes / seconds : null;
      return _ProbeSample(host, bps);
    } on Object {
      return null;
    }
  }
}

class _ProbeSample {
  const _ProbeSample(this.host, this.bytesPerSec);

  final String host;

  /// Null when the host answered but the body was too small to rank by
  /// throughput — it still counts as reachable.
  final double? bytesPerSec;
}
