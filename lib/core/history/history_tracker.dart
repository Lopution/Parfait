import 'history_models.dart';
import 'history_repository.dart';

/// Small clock boundary that lets tests advance time deterministically while
/// production uses a real [Stopwatch].
abstract interface class HistoryElapsedClock {
  Duration get elapsed;

  void start();

  void stop();

  void reset();
}

class StopwatchHistoryClock implements HistoryElapsedClock {
  final Stopwatch _stopwatch = Stopwatch();

  @override
  Duration get elapsed => _stopwatch.elapsed;

  @override
  void start() => _stopwatch.start();

  @override
  void stop() => _stopwatch.stop();

  @override
  void reset() => _stopwatch.reset();
}

/// Tracks only foreground-visible time for one content route.
///
/// A route can pause and resume several times. Local rows are upserted at the
/// first visible event and at every leave; Pixiv work is added only once per
/// newly observed duration and is then flushed through the account-scoped
/// outbox. No periodic timer is involved.
class HistoryTracker {
  HistoryTracker({
    required HistoryRepository repository,
    required String accountId,
    required HistoryContentType contentType,
    required int contentId,
    required HistorySnapshot snapshot,
    required bool localHistoryEnabled,
    required bool pixivHistoryEnabled,
    PixivHistoryRemote? remote,
    bool Function()? isAccountCurrent,
    HistoryElapsedClock? clock,
    DateTime Function()? now,
  }) : _repository = repository,
       _accountId = accountId,
       _contentType = contentType,
       _contentId = contentId,
       _snapshot = snapshot,
       _localHistoryEnabled = localHistoryEnabled,
       _pixivHistoryEnabled = pixivHistoryEnabled,
       _remote = remote,
       _isAccountCurrent = isAccountCurrent,
       _clock = clock ?? StopwatchHistoryClock(),
       _now = now ?? DateTime.now;

  static const pixivMinimumDuration = HistoryRepository.pixivMinimumDuration;

  final HistoryRepository _repository;
  final String _accountId;
  final HistoryContentType _contentType;
  final int _contentId;
  final HistoryElapsedClock _clock;
  final DateTime Function() _now;

  HistorySnapshot _snapshot;
  PixivHistoryRemote? _remote;
  bool Function()? _isAccountCurrent;
  bool _localHistoryEnabled;
  bool _pixivHistoryEnabled;
  bool _active = false;
  bool _finished = false;
  Duration _visibleDuration = Duration.zero;
  Duration _pixivCommittedDuration = Duration.zero;
  Future<void> _operationTail = Future<void>.value();

  bool get isActive => _active;
  Duration get visibleDuration => _visibleDuration + _clock.elapsed;
  HistorySnapshot get snapshot => _snapshot;

  void updateSnapshot(HistorySnapshot snapshot) => _snapshot = snapshot;

  void updateSettings({
    required bool localHistoryEnabled,
    required bool pixivHistoryEnabled,
    PixivHistoryRemote? remote,
    bool Function()? isAccountCurrent,
  }) {
    _localHistoryEnabled = localHistoryEnabled;
    _pixivHistoryEnabled = pixivHistoryEnabled;
    _remote = remote ?? _remote;
    _isAccountCurrent = isAccountCurrent ?? _isAccountCurrent;
  }

  Future<void> start() {
    if (_finished || _active) return Future<void>.value();
    _active = true;
    _clock.start();
    // This initial commit provides crash/force-stop resilience even if the
    // route never gets a later pop callback.
    return _enqueueCommit();
  }

  Future<void> pauseAndCommit() {
    if (_active) {
      _clock.stop();
      _visibleDuration += _clock.elapsed;
      _clock.reset();
      _active = false;
    }
    return _enqueueCommit();
  }

  Future<void> finish() {
    if (_finished) return Future<void>.value();
    _finished = true;
    return pauseAndCommit();
  }

  Future<void> _enqueueCommit() {
    final operation = _operationTail.then<void>((_) => _commit());
    // A failed operation must not poison the next lifecycle event. The
    // original future remains returned to the caller for visible reporting.
    _operationTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _commit() async {
    final duration = _visibleDuration;
    final unsubmitted = duration - _pixivCommittedDuration;
    final shouldEnqueuePixiv =
        _pixivHistoryEnabled &&
        _contentType == HistoryContentType.illust &&
        duration >= pixivMinimumDuration &&
        unsubmitted > Duration.zero;
    final shouldFlush = _pixivHistoryEnabled && _remote != null;
    if (!_localHistoryEnabled && !shouldEnqueuePixiv && !shouldFlush) return;

    await _repository.commitView(
      record: HistoryRecord(
        accountId: _accountId,
        contentType: _contentType,
        contentId: _contentId,
        lastViewedAt: _now().toUtc(),
        snapshot: _snapshot,
        visibleDuration: duration,
      ),
      writeLocal: _localHistoryEnabled,
      enqueuePixiv: shouldEnqueuePixiv,
      unsubmittedPixivDuration: shouldEnqueuePixiv
          ? unsubmitted
          : Duration.zero,
    );
    if (shouldEnqueuePixiv) _pixivCommittedDuration = duration;
    if (shouldFlush) {
      await _repository.flushOutbox(
        accountId: _accountId,
        remote: _remote!,
        isAccountCurrent: _isAccountCurrent,
      );
    }
  }
}
