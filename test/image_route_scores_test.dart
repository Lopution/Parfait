import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/compat/image_route_scores.dart';

const _front1 = 'ech:104.18.1.1';
const _front2 = 'ech:104.18.2.2';
const _seed = 'ech:162.159.152.4';
const _origin = 'origin';
const _candidates = [_front1, _front2, _seed, _origin];

/// Seconds a candidate's n-th body takes for 100 KB, or null for a stall.
typedef _Profile = Map<String, double? Function(int n)>;

double? _good(int _) => 0.4;
double? _stallsHalf(int n) => n.isOdd ? null : 0.4;

/// Measured 2026-11-03: on Unicom the default fronts (colo LAX) stall about
/// half the bodies; on Telecom the origin crawls at 25 KB/s.
final _unicom = <String, double? Function(int)>{
  _front1: _stallsHalf,
  _front2: _stallsHalf,
  _seed: _good,
  _origin: _good,
};
final _telecom = <String, double? Function(int)>{
  _front1: _good,
  _front2: _good,
  _seed: _good,
  _origin: (_) => 4.0,
};

class _Network {
  _Network(this.profile);

  _Profile profile;
  var now = DateTime(2026, 11, 3);
  final served = <String, int>{};
  late final scores = ImageRouteScores(clock: () => now);

  /// Sends [loads] requests 10 s apart, every third one a prefetch, and
  /// returns where the visible ones went.
  List<String> load(int loads) {
    final visible = <String>[];
    for (var i = 0; i < loads; i++) {
      final background = i % 3 == 2;
      final candidate = scores.order(_candidates, background: background).first;
      if (!background) visible.add(candidate);
      final n = served.update(candidate, (n) => n + 1, ifAbsent: () => 0);
      final body = profile[candidate]!(n);
      scores.record(
        body == null
            ? ImageRouteSample.failure(candidate, at: now)
            : ImageRouteSample.load(
                candidate,
                headers: const Duration(milliseconds: 300),
                total: Duration(milliseconds: 300 + (body * 1000).round()),
                bytes: 100 * 1024,
                at: now,
              ),
      );
      now = now.add(const Duration(seconds: 10));
    }
    return visible;
  }
}

ImageRouteScore _score(double cost, {DateTime? at}) => ImageRouteScore(
  cost: cost,
  weight: ImageRouteScores.maxWeight,
  failureShare: 0,
  at: at ?? DateTime(2026, 11, 3),
);

void main() {
  test('visible loads settle on a good route within six and stay there', () {
    for (final (name, profile, good) in [
      ('unicom', _unicom, {_seed, _origin}),
      ('telecom', _telecom, {_front1, _front2, _seed}),
    ]) {
      // Long enough for every candidate to be explored again.
      final visible = _Network(profile).load(300);
      expect(visible.skip(6).toSet(), hasLength(1), reason: name);
      expect(good, contains(visible.last), reason: name);
    }
  });

  test('a route that turns slow loses the choice within minutes', () {
    final network = _Network({
      _front1: (_) => 1.5,
      _front2: (_) => 1.5,
      _seed: (_) => 1.5,
      _origin: (_) => 0.4,
    });
    expect(network.load(30).last, _origin);

    network.profile = _telecom;
    // Ten minutes at one load every 10 s.
    final visible = network.load(60);
    expect(visible.indexWhere((c) => c != _origin), lessThan(8));
    expect(visible.last, isNot(_origin));
  });

  test('another route takes over only when 15 % cheaper', () {
    for (final (cost, first) in [(0.9, 'a'), (0.84, 'b')]) {
      final scores = ImageRouteScores(
        seed: {'a': _score(1), 'b': _score(cost)},
        clock: () => DateTime(2026, 11, 3),
      );
      scores.order(['a']);
      expect(scores.order(['a', 'b']).first, first, reason: '$cost');
    }
  });

  test('prefetches explore one stale route at a time, visible loads never', () {
    var now = DateTime(2026, 11, 3);
    final scores = ImageRouteScores(clock: () => now);
    List<String> visible() => scores.order(_candidates);
    String prefetch() => scores.order(_candidates, background: true).first;
    // Slower than every prior, so no sample changes the route in use.
    void slow(String candidate) => scores.record(
      ImageRouteSample.load(
        candidate,
        headers: const Duration(milliseconds: 300),
        total: const Duration(seconds: 3),
        bytes: 100 * 1024,
        at: now,
      ),
    );

    expect(visible(), _candidates);
    expect(prefetch(), _front2);
    expect(prefetch(), _front1, reason: 'one exploration at a time');
    expect(visible().first, _front1);
    slow(_front2);
    expect(prefetch(), _seed);
    now = now.add(ImageRouteScores.exploreLease);
    expect(prefetch(), _seed, reason: 'an unreported one frees its slot');
    slow(_seed);
    slow(_origin);
    slow(_front1);
    expect(prefetch(), _front1, reason: 'every route sampled lately');

    now = now.add(ImageRouteScores.exploreAfter);
    expect(prefetch(), _front2, reason: 'the stalest sample is retried');
  });

  test('a snapshot seeds the next visit to the network', () {
    final network = _Network(_unicom)..load(30);
    network.scores.noteRanges(_seed, served: false);
    final stored =
        jsonDecode(
              jsonEncode({
                for (final e in network.scores.snapshot().entries)
                  e.key: e.value.toJson(),
              }),
            )
            as Map<String, Object?>;

    final next = ImageRouteScores(
      seed: {
        for (final e in stored.entries)
          e.key: ImageRouteScore.fromJson(e.value)!,
      },
      // A day later every sample has decayed; the costs still rank.
      clock: () => network.now.add(const Duration(days: 1)),
    );
    expect(next.order(_candidates).first, network.scores.chosen);
    expect(next.servesRanges(_seed), isFalse);
    expect(next.servesRanges(_origin), isTrue);
  });
}
