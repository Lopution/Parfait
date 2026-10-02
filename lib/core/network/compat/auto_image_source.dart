import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
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
/// The race measures how long one feed-sized image takes, not TTFB: every
/// candidate fetches the same image and downloads up to [probeBytes] of its
/// body, and the host with the highest bytes/second — timed from the request,
/// first byte included — wins. A candidate that only answers quickly but
/// transfers poorly (fast TLS, throttled pipe) no longer takes the win over
/// a genuinely fast one.
class AutoImageSource {
  AutoImageSource({required SharedPreferencesAsync preferences})
    : _preferences = preferences;

  static const storageKey = PreferenceKeys.autoImageSource;

  /// Total budget of one probe, headers and body. A candidate without a
  /// response inside it loses; one still mid-body is ranked on what it
  /// delivered. At 32 KB/s a throttled host still fills [minMeasuredBytes].
  static const probeTimeout = Duration(seconds: 10);

  /// Upper bound of body bytes a probe reads — the size of a typical feed
  /// thumbnail (~240 KB measured), so the ranking reflects what loading one
  /// image costs. Racing four candidates reads at most ~1 MB.
  static const probeBytes = 256 * 1024;

  /// Minimum body bytes before a measurement counts toward the throughput
  /// ranking; below it the elapsed is dominated by latency, not bandwidth.
  static const minMeasuredBytes = 32 * 1024;

  /// The image every candidate fetches: a 1200px master (480,607 bytes) of a
  /// well-known pximg work commonly used for mirror checks — stable since
  /// 2016 and served by every mirror host, so the measurement compares
  /// hosts, not objects. It is larger than [probeBytes] on purpose.
  static const probePath =
      '/img-master/img/2016/04/29/03/33/27/56585648_p0_master1200.jpg';

  final SharedPreferencesAsync _preferences;
  Future<void> _writeTail = Future<void>.value();

  /// The persisted winner for [networkIdentity], or null when none applies
  /// (never raced on this network, or a corrupted blob). Winners are kept
  /// per identity — switching back to a known network reuses its measured
  /// source instead of re-racing.
  Future<String?> winnerFor(String networkIdentity) async {
    try {
      final winners = await _readWinners();
      // Accepts the plain-string form and the short-lived {host, bps} map
      // written while throughput was persisted — the extra field is simply
      // ignored now that nothing consumes it.
      final host = switch (winners[networkIdentity]) {
        String() => winners[networkIdentity] as String,
        Map<String, dynamic>() =>
          (winners[networkIdentity] as Map<String, dynamic>)['host'] as String?,
        _ => null,
      };
      if (host == null || !ImageMirror.autoCandidates.contains(host)) {
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

  /// Races a bounded image GET to every candidate through the image ladder
  /// and resolves to the host with the highest measured throughput plus the
  /// winning measurement itself. Returns null when every candidate fails —
  /// callers keep the previous winner/direct then rather than degrading to
  /// an untested source.
  static Future<({String host, double? bps})?> race(
    NetworkAccessPolicy policy, {
    NetworkCancelSignal? cancelSignal,
    @visibleForTesting Duration timeout = probeTimeout,
  }) async {
    final samples = await Future.wait(
      ImageMirror.autoCandidates.map(
        (host) => _probe(policy, host, cancelSignal, timeout),
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
    Duration timeout,
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
              return client.send(request).timeout(timeout);
            },
          )
          .timeout(timeout);
      try {
        // A non-200 answer (mirror offline, auth wall, captive portal) is
        // not a reachable source — drain-and-rank treated it as one and a
        // dead host could win whenever no candidate produced a measurement.
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          return null;
        }
        // One total deadline for the body, not a per-chunk one: a host
        // dribbling a byte at a time previously kept every timeout promise
        // while Future.wait held the race open. On expiry the subscription
        // is cancelled (closing the connection) and the bytes received so
        // far are the measurement — a slow host still ranks, just low.
        final remaining = timeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) return null;
        final done = Completer<void>();
        late final StreamSubscription<List<int>> sub;
        sub = response.stream.listen(
          (chunk) {
            bytes += chunk.length;
            if (bytes >= probeBytes) {
              unawaited(sub.cancel());
              if (!done.isCompleted) done.complete();
            }
          },
          onError: (Object e, _) {
            if (!done.isCompleted) done.completeError(e);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        try {
          await done.future.timeout(remaining);
        } on TimeoutException {
          // Too little data to measure: as good as no answer at all.
          if (bytes < minMeasuredBytes) return null;
        } finally {
          await sub.cancel();
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
