import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../log.dart';
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

  /// The persisted winner for [networkIdentity] and when it was measured,
  /// or null when none applies (never raced on this network, or a corrupted
  /// blob). Winners are kept per identity — switching back to a known
  /// network reuses its measured source instead of re-racing.
  Future<({String host, DateTime? measuredAt})?> winnerFor(
    String networkIdentity,
  ) async {
    try {
      final winners = await _readWinners();
      // A plain string, and a map without `at` (the short-lived {host, bps}
      // form), were written before the time was kept: they read as stale.
      final (host, at) = switch (winners[networkIdentity]) {
        final String host => (host, null),
        final Map<String, dynamic> record => (record['host'], record['at']),
        _ => (null, null),
      };
      if (host is! String || !ImageMirror.autoCandidates.contains(host)) {
        return null;
      }
      return (
        host: host,
        measuredAt: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      );
    } on Object {
      return null;
    }
  }

  /// Serialized writes — a race completes at the same moment other network
  /// state is being persisted. Callers do not wait: a failed write is
  /// logged.
  Future<void> remember(
    String networkIdentity,
    String host, {
    required DateTime measuredAt,
  }) {
    return _writeTail = _writeTail.then<void>((_) async {
      final winners = await _readWinners();
      winners[networkIdentity] = {
        'host': host,
        'at': measuredAt.millisecondsSinceEpoch,
      };
      try {
        await _preferences.setString(storageKey, jsonEncode(winners));
      } on Object catch (error) {
        log('auto image source not remembered: $error');
      }
    });
  }

  /// A damaged or unreadable blob reads as empty; the next winner rewrites
  /// it.
  Future<Map<String, dynamic>> _readWinners() async {
    try {
      final raw = await _preferences.getString(storageKey);
      if (raw == null || raw.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, dynamic>{};
      return decoded;
    } on Object {
      return <String, dynamic>{};
    }
  }

  /// Races a bounded image GET to every candidate through the image ladder
  /// and resolves to the host with the highest measured throughput, with
  /// what every candidate measured. Returns null when every candidate fails
  /// — callers keep the previous winner/direct then rather than degrading
  /// to an untested source.
  static Future<AutoSourceRace?> race(
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
    return AutoSourceRace(
      host: best.host,
      bps: best.bytesPerSec,
      answered: {
        for (final sample in samples.whereType<_ProbeSample>())
          sample.host: sample.bytesPerSec,
      },
    );
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

/// One race: the best candidate and what every candidate that answered
/// measured.
class AutoSourceRace {
  const AutoSourceRace({
    required this.host,
    required this.bps,
    required this.answered,
  });

  final String host;

  /// Null when no candidate's body was large enough to rank by throughput.
  final double? bps;

  /// Bytes/second of every candidate that answered; null where the body was
  /// too small to measure. A candidate missing here failed.
  final Map<String, double?> answered;
}

/// When the auto source races, and whether a race result replaces the
/// winner in use (NET-22). A race costs four image downloads and competes
/// with the first screen for bandwidth, and one sample per candidate is
/// noisy, so each network is measured rarely and a working source is not
/// switched for a small or one-off difference:
///
/// - the winner remembered for a network applies at once;
/// - none remembered: race now and apply the result;
/// - measured within [freshFor]: no race;
/// - older: race once, [deferral] after the network is seen, so the first
///   screen is not contended and the probes run warm;
/// - a race replaces the winner in use only when its best candidate is at
///   least 1/[replaceRatio] as fast as that winner in the same race, or the
///   winner failed in it;
/// - an exhausted winner drops to direct and re-races at once, at most once
///   per [throttle].
class AutoSourceSelector {
  AutoSourceSelector({
    required AutoImageSource store,
    required Future<AutoSourceRace?> Function() race,
    required bool Function() enabled,
    required String? Function() current,
    required void Function(String? host) apply,
  }) : _store = store,
       _race = race,
       _enabled = enabled,
       _current = current,
       _apply = apply;

  static const freshFor = Duration(hours: 24);
  static const deferral = Duration(seconds: 30);
  static const throttle = Duration(seconds: 30);

  /// A challenger must reach the winner's bytes/second divided by this —
  /// about 15 % faster, the margin route scores use (NET-04).
  static const replaceRatio = 0.85;

  final AutoImageSource _store;
  final Future<AutoSourceRace?> Function() _race;
  final bool Function() _enabled;
  final String? Function() _current;
  final void Function(String? host) _apply;

  String? _identity;
  Timer? _deferred;
  bool _racing = false;
  String? _pendingIdentity;
  DateTime? _lastRaceAt;
  bool _disposed = false;

  /// The network [identity] became current (the first one included).
  void networkSeen(String identity) {
    _deferred?.cancel();
    _deferred = null;
    _identity = identity;
    if (!_enabled()) return;
    unawaited(_seen(identity));
  }

  Future<void> _seen(String identity) async {
    final remembered = await _store.winnerFor(identity);
    if (_disposed || identity != _identity) return;
    if (remembered == null) {
      _raceNow(identity);
      return;
    }
    _apply(remembered.host);
    final measuredAt = remembered.measuredAt;
    if (measuredAt != null && clock.now().difference(measuredAt) < freshFor) {
      return;
    }
    _deferred = Timer(deferral, () {
      _deferred = null;
      _raceNow(identity);
    });
  }

  /// Every ladder tier of [host] failed. The winner in use drops to direct
  /// and the candidates are raced again.
  void winnerExhausted(String host) {
    final identity = _identity;
    if (identity == null || _current() != host) return;
    _deferred?.cancel();
    _deferred = null;
    _apply(null);
    _raceNow(identity, throttled: true);
  }

  void dispose() {
    _disposed = true;
    _deferred?.cancel();
  }

  void _raceNow(String identity, {bool throttled = false}) {
    if (_disposed || !_enabled()) return;
    if (_racing) {
      // A race is running, perhaps for an older network: one more runs for
      // the latest identity once it ends.
      _pendingIdentity = identity;
      return;
    }
    final now = clock.now();
    if (throttled &&
        _lastRaceAt != null &&
        now.difference(_lastRaceAt!) < throttle) {
      return;
    }
    _racing = true;
    _lastRaceAt = now;
    unawaited(() async {
      try {
        final result = await _race();
        // A result measured on a network that is no longer current is
        // meaningless here.
        if (_disposed || result == null || identity != _identity) return;
        final held = _current();
        final winner = held != null && !_replaces(result, held)
            ? held
            : result.host;
        if (winner != held) _apply(winner);
        unawaited(_store.remember(identity, winner, measuredAt: clock.now()));
      } on Object catch (error) {
        log('auto image source race failed: $error');
      } finally {
        _racing = false;
        final pending = _pendingIdentity;
        _pendingIdentity = null;
        if (pending != null && pending == _identity) _raceNow(pending);
      }
    }());
  }

  /// Whether [race]'s best candidate should replace [held]: [held] failed,
  /// or the best transferred at least 1/[replaceRatio] as fast. A best that
  /// could not be measured never replaces a winner that answered.
  static bool _replaces(AutoSourceRace race, String held) {
    if (!race.answered.containsKey(held)) return true;
    final heldBps = race.answered[held];
    final bestBps = race.bps;
    if (bestBps == null) return false;
    if (heldBps == null) return true;
    return bestBps * replaceRatio >= heldBps;
  }
}
