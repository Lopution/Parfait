import 'dart:math' as math;

/// One finished image transfer's verdict on the route candidate it took.
class ImageRouteSample {
  const ImageRouteSample(
    this.candidate,
    this.cost, {
    required this.failed,
    required this.at,
  });

  /// A body that arrived in full: its time normalised to a 100 KB image, so
  /// thumbnails and originals compare.
  factory ImageRouteSample.load(
    String candidate, {
    required Duration headers,
    required Duration total,
    required int bytes,
    required DateTime at,
  }) {
    final body =
        _seconds(total - headers) * 100 * 1024 / math.max(bytes, 16 * 1024);
    final cost = (_seconds(headers) + body).clamp(0.2, 30.0);
    return ImageRouteSample(candidate, cost, failed: false, at: at);
  }

  /// A body that stalled for the idle budget, or a failure before it.
  factory ImageRouteSample.failure(String candidate, {required DateTime at}) =>
      ImageRouteSample(
        candidate,
        ImageRouteScores.failureCost,
        failed: true,
        at: at,
      );

  factory ImageRouteSample.fromJson(Map<String, Object?> json) =>
      ImageRouteSample(
        json['candidate']! as String,
        (json['cost']! as num).toDouble(),
        failed: json['failed']! as bool,
        at: DateTime.fromMillisecondsSinceEpoch(json['at']! as int),
      );

  final String candidate;

  /// Seconds.
  final double cost;
  final bool failed;
  final DateTime at;

  Map<String, Object> toJson() => {
    'candidate': candidate,
    'cost': cost,
    'failed': failed,
    'at': at.millisecondsSinceEpoch,
  };

  static double _seconds(Duration duration) =>
      duration.inMicroseconds / Duration.microsecondsPerSecond;
}

/// What a network taught about one candidate: kept per network identity,
/// and the start of a new board on that network.
class ImageRouteScore {
  const ImageRouteScore({
    required this.cost,
    required this.weight,
    required this.failureShare,
    required this.at,
    this.servesRanges = true,
  });

  /// Skips fields that are missing or of the wrong type: a damaged entry
  /// is relearned.
  static ImageRouteScore? fromJson(Object? json) {
    if (json is! Map) return null;
    final cost = json['cost'];
    final weight = json['weight'];
    final failureShare = json['failureShare'];
    final at = json['at'];
    if (cost is! num || weight is! num || failureShare is! num || at is! int) {
      return null;
    }
    return ImageRouteScore(
      cost: cost.toDouble(),
      weight: weight.toDouble(),
      failureShare: failureShare.toDouble(),
      at: DateTime.fromMillisecondsSinceEpoch(at),
      servesRanges: json['servesRanges'] != false,
    );
  }

  /// Expected seconds for a 100 KB image.
  final double cost;

  /// How many recent samples [cost] stands for.
  final double weight;
  final double failureShare;

  /// When the last sample came.
  final DateTime at;

  /// False once the candidate answered a `Range` request with the whole
  /// file.
  final bool servesRanges;

  Map<String, Object> toJson() => {
    'cost': cost,
    'weight': weight,
    'failureShare': failureShare,
    'at': at.millisecondsSinceEpoch,
    if (!servesRanges) 'servesRanges': false,
  };
}

/// One image route candidate as the network page shows it, without its
/// address.
class ImageRouteStanding {
  const ImageRouteStanding({
    this.cloudflare,
    this.colo,
    required this.cost,
    required this.failureShare,
    required this.inUse,
  });

  factory ImageRouteStanding.fromJson(Map<String, Object?> json) =>
      ImageRouteStanding(
        cloudflare: json['cloudflare'] as int?,
        colo: json['colo'] as String?,
        cost: (json['cost']! as num).toDouble(),
        failureShare: (json['failureShare']! as num).toDouble(),
        inUse: json['inUse']! as bool,
      );

  /// The Cloudflare front's number, from 1; null for pixiv's origin.
  final int? cloudflare;

  /// The Cloudflare colo the front lands in, such as `HKG`, once known.
  final String? colo;

  /// Expected seconds for a 100 KB image.
  final double cost;
  final double failureShare;

  /// Whether visible loads go to it now.
  final bool inUse;

  Map<String, Object?> toJson() => {
    'cloudflare': cloudflare,
    'colo': colo,
    'cost': cost,
    'failureShare': failureShare,
    'inUse': inUse,
  };
}

/// Learns which route loads pixiv's images best on one network, from the
/// images themselves.
///
/// Each candidate's expected cost is the mean of its recent samples,
/// blended with a prior worth half a sample. A sample loses half its
/// weight every [halfLife], and a candidate's samples together weigh at
/// most [maxWeight], so a route that turns bad is dropped after a few
/// loads however long it served well. An unseen candidate's prior is its
/// place in the default order, or what the network taught last time.
class ImageRouteScores {
  ImageRouteScores({
    Map<String, ImageRouteScore> seed = const {},
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    this.seed(seed);
  }

  static const halfLife = Duration(minutes: 10);
  static const maxWeight = 6.0;

  /// What a stall or a failure costs, in seconds: about what a stalled
  /// visible image costs its viewer.
  static const failureCost = 12.0;

  /// Another candidate takes over only when it is at least 15 % cheaper.
  static const switchRatio = 0.85;

  /// A candidate with no sample this recent is explored.
  static const exploreAfter = Duration(minutes: 10);

  /// An exploring request that never reports frees the slot after this.
  static const exploreLease = Duration(seconds: 30);

  static const _priorWeight = 0.5;
  static const _firstPrior = 2.0;
  static const _priorStep = 0.2;

  final DateTime Function() _clock;
  final Map<String, _Tally> _tallies = {};
  String? _chosen;
  String? _exploring;
  DateTime? _exploringSince;

  /// The candidate foreground requests go to, once one has been chosen.
  String? get chosen => _chosen;

  /// [candidates] in the order a request tries them. They arrive in the
  /// default order, which gives the unseen ones their prior. A background
  /// request may go first to one candidate that has no recent sample, one
  /// such request at a time; foreground requests never explore.
  List<String> order(List<String> candidates, {bool background = false}) {
    if (candidates.isEmpty) return const [];
    final now = _clock();
    final costs = {
      for (final (place, candidate) in candidates.indexed)
        candidate: _costOf(candidate, place, now),
    };
    // Ties keep the default order (`sort` is not stable).
    final ranked = [...candidates]
      ..sort((a, b) {
        final byCost = costs[a]!.compareTo(costs[b]!);
        return byCost != 0
            ? byCost
            : candidates.indexOf(a).compareTo(candidates.indexOf(b));
      });
    final current = _chosen;
    if (current != null &&
        costs.containsKey(current) &&
        costs[ranked.first]! > costs[current]! * switchRatio) {
      ranked
        ..remove(current)
        ..insert(0, current);
    }
    _chosen = ranked.first;
    if (background) {
      final explore = _toExplore(ranked.skip(1), now);
      if (explore != null) {
        _exploring = explore;
        _exploringSince = now;
        ranked
          ..remove(explore)
          ..insert(0, explore);
      }
    }
    return ranked;
  }

  void record(ImageRouteSample sample) {
    final now = _clock();
    final tally = _tallies.putIfAbsent(sample.candidate, _Tally.new)
      ..decayTo(now);
    tally
      ..weight += 1
      ..weightedCost += sample.cost
      ..weightedFailures += sample.failed ? 1 : 0
      ..lastSample = sample.at;
    if (tally.weight > maxWeight) tally.scale(maxWeight / tally.weight);
    release(sample.candidate);
  }

  /// Frees the exploring slot when [candidate] holds it and its request
  /// ended without a sample.
  void release(String candidate) {
    if (_exploring == candidate) _exploring = null;
  }

  /// Records whether [candidate] answered a `Range` request with a range.
  void noteRanges(String candidate, {required bool served}) {
    _tallies.putIfAbsent(candidate, _Tally.new).servesRanges = served;
  }

  bool servesRanges(String candidate) =>
      _tallies[candidate]?.servesRanges ?? true;

  /// What this board has learned, to persist or to seed another board:
  /// each cost as the board ranks it, so a candidate known from one sample
  /// keeps the doubt its prior adds. Candidates it knows nothing about are
  /// left out.
  Map<String, ImageRouteScore> snapshot() {
    final now = _clock();
    return {
      for (final MapEntry(key: candidate, value: tally) in _tallies.entries)
        if (tally.lastSample != null || !tally.servesRanges)
          candidate: ImageRouteScore(
            cost: tally.cost(tally.prior ?? tally.place ?? _firstPrior, now),
            weight: tally.weightAt(now),
            failureShare: tally.failureShareAt(now),
            at: tally.lastSample ?? now,
            servesRanges: tally.servesRanges,
          ),
    };
  }

  /// Adds what another board learned: its samples, at their age, and its
  /// costs as the priors of the candidates this board has not seen. An
  /// entry without weight holds only a range mark.
  void seed(Map<String, ImageRouteScore> scores) {
    final now = _clock();
    for (final MapEntry(key: candidate, value: score) in scores.entries) {
      final tally = _tallies.putIfAbsent(candidate, _Tally.new)..decayTo(now);
      final age = now.difference(score.at);
      final weight =
          score.weight * _decay(age.isNegative ? Duration.zero : age);
      tally
        ..weight += weight
        ..weightedCost += score.cost * weight
        ..weightedFailures += score.failureShare * weight
        ..prior ??= score.weight > 0 ? score.cost : null
        ..servesRanges = tally.servesRanges && score.servesRanges;
      final last = tally.lastSample;
      if (last == null || score.at.isAfter(last)) tally.lastSample = score.at;
      if (tally.weight > maxWeight) tally.scale(maxWeight / tally.weight);
    }
  }

  double _costOf(String candidate, int place, DateTime now) {
    final fallback = _firstPrior + _priorStep * place;
    final tally = _tallies[candidate];
    if (tally == null) return fallback;
    tally.place = fallback;
    return tally.cost(tally.prior ?? fallback, now);
  }

  String? _toExplore(Iterable<String> others, DateTime now) {
    final since = _exploringSince;
    if (_exploring != null &&
        since != null &&
        now.difference(since) < exploreLease) {
      return null;
    }
    _exploring = null;
    String? stalest;
    DateTime? stalestAt;
    for (final candidate in others) {
      final last = _tallies[candidate]?.lastSample;
      if (last == null) return candidate;
      if (now.difference(last) < exploreAfter) continue;
      if (stalestAt == null || last.isBefore(stalestAt)) {
        stalest = candidate;
        stalestAt = last;
      }
    }
    return stalest;
  }

  static double _decay(Duration age) =>
      math.pow(0.5, age.inMilliseconds / halfLife.inMilliseconds).toDouble();
}

class _Tally {
  double weight = 0;
  double weightedCost = 0;
  double weightedFailures = 0;
  DateTime? decayedAt;
  DateTime? lastSample;

  /// What the last network visit taught, which outranks [place].
  double? prior;

  /// The prior of the candidate's place in the last default order seen.
  double? place;
  bool servesRanges = true;

  void decayTo(DateTime now) {
    final since = decayedAt;
    decayedAt = now;
    if (since == null || !now.isAfter(since)) return;
    scale(ImageRouteScores._decay(now.difference(since)));
  }

  void scale(double factor) {
    weight *= factor;
    weightedCost *= factor;
    weightedFailures *= factor;
  }

  double weightAt(DateTime now) {
    decayTo(now);
    return weight;
  }

  double cost(double prior, DateTime now) {
    decayTo(now);
    return (weightedCost + ImageRouteScores._priorWeight * prior) /
        (weight + ImageRouteScores._priorWeight);
  }

  double failureShareAt(DateTime now) {
    decayTo(now);
    return weight == 0 ? 0 : weightedFailures / weight;
  }
}
