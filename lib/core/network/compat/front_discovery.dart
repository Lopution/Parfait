import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import '../pixiv_headers.dart';
import 'image_route_discovery.dart';
import 'image_route_scores.dart';
import 'network_contracts.dart' show NoImageFront;
import 'network_policy.dart';

/// Finds, for the network the image worker is on, Cloudflare fronts that
/// land in a colo serving pixiv's images better than the fronts the ECH
/// config names, and labels every front with its colo.
///
/// Which colo an address reaches differs by carrier and by prefix, and
/// some addresses do not serve the images at all, so a run proves each
/// address it samples: over ECH through it, `cdn-cgi/trace` names the
/// colo, then one real thumbnail measures the cost. It keeps the
/// [keep] best that beat the Cloudflare candidates by a fifth, or that
/// land in a colo none of them uses at a cost within a fifth more. Kept
/// fronts become candidates of that network ([ImageRouteDiscovery.fronts])
/// and are scored like the others; one that costs [worseRatio] times the
/// best other candidate for a day is dropped.
///
/// A run starts after [runAfterLoads] image samples on a network no run
/// has been on, or when every sampled Cloudflare candidate costs
/// [worseRatio] times the best other candidate or fails over
/// [failingShare] of its loads; never within [minWait] of the last run
/// (doubled after each run that kept nothing). Its probes, and the colo
/// labels, go one at a time and only while no visible image waits for a
/// lane ([idle]). A network change ends the run.
class FrontDiscovery {
  FrontDiscovery(
    this._policy, {
    required bool Function() idle,
    required Uri Function() image,
    math.Random? random,
  }) : _idle = idle,
       _image = image,
       _random = random ?? math.Random();

  static const runAfterLoads = 20;
  static const probes = 8;
  static const keep = 2;
  static const probeLimit = Duration(seconds: 10);
  static const minWait = Duration(hours: 6);
  static const maxWaitDoublings = 3;
  static const rejectFor = Duration(days: 1);
  static const labelFor = Duration(days: 1);
  static const dropAfter = Duration(days: 1);
  static const worseRatio = 1.5;
  static const failingShare = 0.3;
  static const beatRatio = 0.8;
  static const newColoRatio = 1.2;

  /// What a probe reads at most: a trace, and a thumbnail.
  static const _traceBytes = 4 * 1024;
  static const _imageBytes = 256 * 1024;

  static const imageHost = 'i.pximg.net';
  static final _trace = Uri.https(imageHost, '/cdn-cgi/trace');

  /// The probe image when the worker loaded no thumbnail lately: the
  /// auto image source's probe work (`AutoImageSource.probePath`) at a
  /// feed thumbnail's size, about 18 KB.
  static final fallbackImage = Uri.https(
    imageHost,
    '/c/360x360_70/img-master/img/2016/04/29/03/33/27/56585648_p0_square1200.jpg',
  );

  final NetworkAccessPolicy _policy;
  final bool Function() _idle;
  final Uri Function() _image;
  final math.Random _random;

  String? _identity;
  var _loads = 0;
  _Run? _run;

  /// No run before this: the last one could not reach any front.
  DateTime? _restUntil;

  /// Fronts to label, and when each was last tried on this network: a
  /// trace that failed is tried again the next day, as is a label that
  /// grew old.
  final _toLabel = <InternetAddress>[];
  final _labelTried = <String, DateTime>{};
  var _busy = false;
  var _closed = false;

  /// The work in progress, for tests.
  Future<void> _step = Future.value();

  /// Completes once no probe is in flight; tests wait on it.
  Future<void> get settled => _step;

  /// Called for each sample the policy records: it counts the load, may
  /// queue a colo label or start a run, and lets queued work go on once
  /// the worker is [idle].
  void noteSample(String networkIdentity, ImageRouteSample sample) {
    if (_closed || networkIdentity != _policy.revision.networkIdentity) return;
    if (networkIdentity != _identity) {
      _identity = networkIdentity;
      _loads = 0;
      _run = null;
      _restUntil = null;
      _toLabel.clear();
      _labelTried.clear();
    }
    final now = clock.now();
    var state = _policy.imageRouteDiscovery;
    if (state.lastRunAt == null) _loads++;
    final candidate = sample.candidate;
    if (candidate.startsWith('ech:')) {
      final address = InternetAddress.tryParse(candidate.substring(4));
      final label = address == null ? null : state.colos[address.address];
      final tried = address == null ? null : _labelTried[address.address];
      if (address != null &&
          (label == null || now.difference(label.at) >= labelFor) &&
          (tried == null || now.difference(tried) >= labelFor)) {
        _labelTried[address.address] = now;
        _toLabel.add(address);
      }
    }
    final scores = _policy.currentImageRouteScores();
    final fronts = judge(state.fronts, scores, now);
    if (fronts != null) {
      state = state.copyWith(fronts: fronts);
      _policy.updateImageRouteDiscovery(networkIdentity, state);
    }
    final rest = _restUntil;
    if (_run == null &&
        (rest == null || !now.isBefore(rest)) &&
        due(state, loads: _loads, scores: scores, now: now)) {
      final exclude = {
        for (final front in state.fronts) front.address.address,
        ImageRouteDiscovery.seedFront.address,
        for (final MapEntry(:key, :value) in state.rejected.entries)
          if (now.difference(value) < rejectFor) key,
      };
      _run = _Run(
        networkIdentity,
        now,
        CloudflarePrefixes.sample(_random, probes, exclude: exclude),
      );
    }
    _pump();
  }

  /// Stops queued work; a probe in flight ends without effect.
  void close() {
    _closed = true;
    _run = null;
    _toLabel.clear();
  }

  /// Whether a run is due on a network with [state] after [loads] samples.
  static bool due(
    ImageRouteDiscovery state, {
    required int loads,
    required Map<String, ImageRouteScore> scores,
    required DateTime now,
  }) {
    final last = state.lastRunAt;
    if (last == null) {
      if (loads >= runAfterLoads) return true;
    } else {
      final doublings = math.min(state.fruitless, maxWaitDoublings);
      if (now.difference(last) < minWait * (1 << doublings)) return false;
    }
    final cloudflare = [
      for (final MapEntry(:key, :value) in scores.entries)
        if (key.startsWith('ech:') && value.weight > 0) value,
    ];
    final others = [
      for (final MapEntry(:key, :value) in scores.entries)
        if (!key.startsWith('ech:') && value.weight > 0) value.cost,
    ];
    if (cloudflare.isEmpty) return false;
    final bestOther = others.isEmpty ? null : others.reduce(math.min);
    return cloudflare.every(
      (score) =>
          (bestOther != null && score.cost >= worseRatio * bestOther) ||
          (score.weight >= 2 && score.failureShare > failingShare),
    );
  }

  /// The fronts after a run whose [probed] fronts passed: the [keep] best
  /// qualifiers join [current], and the best of them all fill the room
  /// the [named] fronts leave.
  static List<ExtraFront> chooseFronts({
    required List<InternetAddress> named,
    required List<ExtraFront> current,
    required List<FrontProbe> probed,
    required Map<String, ImageRouteScore> scores,
    required Map<String, FrontColo> colos,
    required DateTime now,
  }) {
    final int room =
        ImageRouteDiscovery.maxFronts -
        math.min<int>(named.length, ImageRouteDiscovery.maxNamedFronts);
    double? costOf(InternetAddress front) {
      final score = scores[echCandidate(front)];
      return score != null && score.weight > 0 ? score.cost : null;
    }

    final inUse = [
      ...named.take(ImageRouteDiscovery.maxNamedFronts),
      ...current.take(room).map((front) => front.address),
    ];
    final costs = [for (final front in inUse) ?costOf(front)];
    final best = costs.isEmpty ? null : costs.reduce(math.min);
    final usedColos = {for (final front in inUse) ?colos[front.address]?.colo};
    final qualified =
        probed
            .where(
              (probe) =>
                  best == null ||
                  probe.cost < beatRatio * best ||
                  (!usedColos.contains(probe.colo) &&
                      probe.cost <= newColoRatio * best),
            )
            .toList()
          ..sort((a, b) => a.cost.compareTo(b.cost));
    final ranked = [
      for (final front in current)
        (front, costOf(front.address) ?? double.infinity),
      for (final probe in qualified.take(keep))
        (ExtraFront(probe.address, at: now), probe.cost),
    ];
    // Ties keep the current fronts first (`sort` is not stable).
    final order = [...ranked]
      ..sort((a, b) {
        final byCost = a.$2.compareTo(b.$2);
        return byCost != 0
            ? byCost
            : ranked.indexOf(a).compareTo(ranked.indexOf(b));
      });
    return [for (final (front, _) in order.take(room)) front];
  }

  /// [fronts] with each one's worse spell brought up to date and those
  /// worse for [dropAfter] gone; null when nothing changed.
  static List<ExtraFront>? judge(
    List<ExtraFront> fronts,
    Map<String, ImageRouteScore> scores,
    DateTime now,
  ) {
    var changed = false;
    final next = <ExtraFront>[];
    for (final front in fronts) {
      final key = echCandidate(front.address);
      final score = scores[key];
      final others = [
        for (final MapEntry(key: other, value: score) in scores.entries)
          if (other != key && score.weight > 0) score.cost,
      ];
      if (score == null || score.weight == 0 || others.isEmpty) {
        next.add(front);
        continue;
      }
      final worse = score.cost >= worseRatio * others.reduce(math.min);
      final since = worse ? front.worseSince ?? now : null;
      if (since != null && now.difference(since) >= dropAfter) {
        changed = true;
        continue;
      }
      if (since != front.worseSince) changed = true;
      next.add(front.worse(since));
    }
    return changed ? next : null;
  }

  void _pump() {
    if (_closed || _busy || !_idle()) return;
    final Future<void> Function()? work;
    if (_toLabel.isNotEmpty) {
      final front = _toLabel.removeAt(0);
      work = () => _label(front);
    } else if (_run case final run? when run.left.isNotEmpty) {
      final front = run.left.removeAt(0);
      work = () => _probeFor(run, front);
    } else {
      work = null;
    }
    if (work == null) return;
    _busy = true;
    _step = work().whenComplete(() {
      _busy = false;
      _pump();
    });
  }

  Future<void> _label(InternetAddress front) async {
    final identity = _identity;
    final String? colo;
    try {
      colo = (await _probe(front, image: false))?.$1;
    } on NoImageFront {
      return;
    }
    if (colo == null || !_current(identity)) return;
    final state = _policy.imageRouteDiscovery;
    _policy.updateImageRouteDiscovery(
      identity!,
      state.copyWith(
        colos: _fresh({
          ...state.colos,
          front.address: FrontColo(colo, at: clock.now()),
        }),
      ),
    );
  }

  Future<void> _probeFor(_Run run, InternetAddress front) async {
    final (String?, double?)? result;
    try {
      result = await _probe(front, image: true);
    } on NoImageFront {
      // No ECH config, or direct-only mode: nothing to probe through.
      if (identical(_run, run)) {
        _run = null;
        _restUntil = clock.now().add(minWait);
      }
      return;
    }
    if (!identical(_run, run) || !_current(run.identity)) return;
    if (result case (final colo?, final cost?)) {
      run.passed.add(FrontProbe(front, colo: colo, cost: cost));
    } else {
      run.failed.add(front.address);
    }
    if (run.left.isEmpty) await _finish(run);
  }

  Future<void> _finish(_Run run) async {
    final named = await _policy.imageFrontsNamed();
    if (!identical(_run, run) || !_current(run.identity)) return;
    _run = null;
    final now = clock.now();
    final state = _policy.imageRouteDiscovery;
    final fronts = chooseFronts(
      named: named ?? const [],
      current: state.fronts,
      probed: run.passed,
      scores: _policy.currentImageRouteScores(),
      colos: state.colos,
      now: now,
    );
    final passed = {for (final probe in run.passed) probe.address.address};
    final added = fronts.any((front) => passed.contains(front.address.address));
    _policy.updateImageRouteDiscovery(
      run.identity,
      state.copyWith(
        fronts: fronts,
        rejected: {
          for (final MapEntry(:key, :value) in state.rejected.entries)
            if (now.difference(value) < rejectFor) key: value,
          for (final address in run.failed) address: now,
        },
        lastRunAt: run.started,
        fruitless: added ? 0 : state.fruitless + 1,
        colos: _fresh({
          ...state.colos,
          for (final probe in run.passed)
            if (fronts.any(
              (front) => front.address.address == probe.address.address,
            ))
              probe.address.address: FrontColo(probe.colo, at: now),
        }),
      ),
    );
  }

  bool _current(String? identity) =>
      !_closed &&
      identity == _identity &&
      identity == _policy.revision.networkIdentity;

  /// Labels read within two days: a front not in use for that long loses
  /// its label.
  static Map<String, FrontColo> _fresh(Map<String, FrontColo> colos) {
    final now = clock.now();
    return {
      for (final MapEntry(:key, :value) in colos.entries)
        if (now.difference(value.at) < labelFor * 2) key: value,
    };
  }

  /// [front]'s colo and, for an [image] probe, its cost; null when it
  /// failed. Throws [NoImageFront] when no ECH route can be built.
  Future<(String?, double?)?> _probe(
    InternetAddress front, {
    required bool image,
  }) async {
    final abort = Completer<void>();
    final limit = Timer(probeLimit, abort.complete);
    try {
      return await _policy.throughImageFront(front, (client) async {
        final trace = await _get(client, _trace, abort.future, _traceBytes);
        if (trace.status != 200) return null;
        final colo = _coloOf(trace.bytes);
        if (colo == null) return null;
        if (!image) return (colo, null);
        final thumbnail = await _get(
          client,
          _image(),
          abort.future,
          _imageBytes,
        );
        if (thumbnail.status != 200 || thumbnail.bytes.isEmpty) return null;
        final cost = ImageRouteSample.load(
          '',
          headers: thumbnail.headers,
          total: thumbnail.total,
          bytes: thumbnail.bytes.length,
          at: clock.now(),
        ).cost;
        return (colo, cost);
      });
    } on NoImageFront {
      rethrow;
    } on Object {
      return null;
    } finally {
      limit.cancel();
    }
  }

  static Future<_Answer> _get(
    http.Client client,
    Uri url,
    Future<void> abort,
    int limit,
  ) async {
    final watch = clock.stopwatch()..start();
    final request = http.AbortableRequest('GET', url, abortTrigger: abort)
      ..headers.addAll(PixivHeaders.image());
    final response = await client.send(request);
    final headers = watch.elapsed;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length >= limit) break;
    }
    return _Answer(
      response.statusCode,
      bytes.takeBytes(),
      headers,
      watch.elapsed,
    );
  }

  static String? _coloOf(List<int> trace) {
    for (final line in String.fromCharCodes(trace).split('\n')) {
      if (line.startsWith('colo=')) {
        final colo = line.substring(5).trim();
        if (RegExp(r'^[A-Z]{3}$').hasMatch(colo)) return colo;
      }
    }
    return null;
  }
}

class _Run {
  _Run(this.identity, this.started, List<InternetAddress> addresses)
    : left = [...addresses];

  final String identity;
  final DateTime started;
  final List<InternetAddress> left;
  final passed = <FrontProbe>[];
  final failed = <String>[];
}

class _Answer {
  const _Answer(this.status, this.bytes, this.headers, this.total);

  final int status;
  final Uint8List bytes;
  final Duration headers;
  final Duration total;
}
