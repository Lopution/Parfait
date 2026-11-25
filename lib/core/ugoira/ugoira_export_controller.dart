import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../download/download_manager.dart';
import '../download/download_providers.dart';
import '../download/download_request.dart';
import '../download/download_task.dart';
import '../download/illust_download_coordinator.dart';
import '../entity/illust_store.dart';
import '../settings/settings_controller.dart';
import 'ugoira_export.dart';
import 'ugoira_limits.dart';

/// Lifecycle phase of an app-level Ugoira GIF export.
enum UgoiraExportPhase {
  preparing,
  running,
  finalizing,
  succeeded,
  canceled,
  failed,
}

/// Immutable per-work state tracked by [UgoiraExportController].
@immutable
class UgoiraExportTaskState {
  const UgoiraExportTaskState({
    required this.phase,
    this.snapshot,
    this.failureKind,
    this.error,
  });

  final UgoiraExportPhase phase;
  final UgoiraExportSnapshot? snapshot;
  final DownloadFailureKind? failureKind;
  final Object? error;

  bool get isActive =>
      phase == UgoiraExportPhase.preparing ||
      phase == UgoiraExportPhase.running ||
      phase == UgoiraExportPhase.finalizing;

  double? get progress => snapshot?.progress;
}

/// Optional encoder factory override for deterministic tests; production uses
/// [ImagePackageUgoiraGifEncoder].
final ugoiraGifEncoderFactoryProvider =
    Provider<UgoiraGifEncoder Function(UgoiraLimits limits)?>((_) => null);

/// Live facade over [DownloadManager] for `DownloadTarget.ugoiraGif` jobs.
///
/// Unifies viewer, detail action bar, card actions, multi-select, and bulk
/// author exports under one [DownloadManager] task queue so progress,
/// cancellation, retry, naming templates, captions, and `DownloadTasksPage`
/// rows share a single source of truth.
class UgoiraExportController extends Notifier<Map<int, UgoiraExportTaskState>> {
  final Map<int, Future<UgoiraExportTaskState>> _inFlight = {};
  final Map<int, Completer<UgoiraExportTaskState>> _completers = {};
  StreamSubscription<void>? _changesSub;
  StreamSubscription<DownloadEvent>? _eventsSub;

  @override
  Map<int, UgoiraExportTaskState> build() {
    final manager = ref.watch(downloadManagerProvider);
    unawaited(_changesSub?.cancel());
    unawaited(_eventsSub?.cancel());
    _changesSub = manager.changes.listen((_) => _syncFromManager(manager));
    _eventsSub = manager.events.listen(_handleEvent);
    ref.onDispose(() {
      unawaited(_changesSub?.cancel());
      unawaited(_eventsSub?.cancel());
      _changesSub = null;
      _eventsSub = null;
      for (final completer in _completers.values) {
        if (!completer.isCompleted) {
          completer.complete(
            const UgoiraExportTaskState(phase: UgoiraExportPhase.canceled),
          );
        }
      }
      _completers.clear();
      _inFlight.clear();
    });
    return _snapshotMap(manager);
  }

  /// Whether a signed-in account context is currently available for export.
  bool get isSignedIn {
    final accountState = ref.read(accountStoreProvider).asData?.value;
    return accountState?.usableCurrent != null;
  }

  /// Starts (or joins an already running) GIF export for [illustId] inside
  /// [DownloadManager].
  Future<UgoiraExportTaskState> export(int illustId) {
    final existing = _inFlight[illustId];
    if (existing != null) return existing;

    if (!isSignedIn) {
      return Future.value(
        const UgoiraExportTaskState(
          phase: UgoiraExportPhase.failed,
          failureKind: DownloadFailureKind.auth,
        ),
      );
    }

    final completer = Completer<UgoiraExportTaskState>();
    _completers[illustId] = completer;
    final future = _trackInFlight(illustId, completer);
    _inFlight[illustId] = future;
    unawaited(_submit(illustId, completer));
    return future;
  }

  Future<UgoiraExportTaskState> _trackInFlight(
    int illustId,
    Completer<UgoiraExportTaskState> completer,
  ) async {
    try {
      return await completer.future;
    } finally {
      if (identical(_completers[illustId], completer)) {
        _completers.remove(illustId);
        unawaited(_inFlight.remove(illustId));
      }
    }
  }

  /// Cancels an active ugoira GIF task for [illustId] in [DownloadManager].
  void cancel(int illustId) {
    final manager = ref.read(downloadManagerProvider);
    for (final task in manager.tasks) {
      if (task.illustId == illustId &&
          task.target == DownloadTarget.ugoiraGif.name &&
          !isTerminal(task.status)) {
        unawaited(manager.cancel(task.id));
        return;
      }
    }
  }

  Future<void> _submit(
    int illustId,
    Completer<UgoiraExportTaskState> completer,
  ) async {
    try {
      final manager = ref.read(downloadManagerProvider);
      final work = ref.read(illustStoreProvider).get(illustId);
      final DownloadTaskSnapshot snapshot;
      if (work != null) {
        snapshot = await ref
            .read(illustDownloadCoordinatorProvider)
            .downloadUgoiraGif(
              work: work,
              namingRule: ref.read(namingRuleProvider),
            );
      } else {
        snapshot = manager.submit(
          DownloadRequest(
            illustId: illustId,
            pageIndex: 0,
            url: Uri.parse('https://i.pximg.net/ugoira/$illustId.gif'),
            target: DownloadTarget.ugoiraGif,
            namingRule: ref.read(namingRuleProvider),
            padPageNumbers: ref.read(downloadPadPageNumbersProvider),
          ),
        );
      }
      _syncFromManager(manager);
      if (isTerminal(snapshot.status) && !completer.isCompleted) {
        completer.complete(_stateFromTask(snapshot));
      }
    } catch (error) {
      final failed = UgoiraExportTaskState(
        phase: UgoiraExportPhase.failed,
        failureKind: classifyDownloadFailure(error),
        error: error.toString(),
      );
      if (ref.mounted) {
        state = {...state, illustId: failed};
      }
      if (!completer.isCompleted) completer.complete(failed);
    }
  }

  void _syncFromManager(DownloadManager manager) {
    if (!ref.mounted) return;
    state = _snapshotMap(manager);
  }

  void _handleEvent(DownloadEvent event) {
    final task = event.snapshot;
    if (task.target != DownloadTarget.ugoiraGif.name) return;
    final mapped = _stateFromTask(task);
    if (ref.mounted) {
      state = {...state, task.illustId: mapped};
    }
    final completer = _completers[task.illustId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(mapped);
    }
  }

  static Map<int, UgoiraExportTaskState> _snapshotMap(DownloadManager manager) {
    final next = <int, UgoiraExportTaskState>{};
    for (final task in manager.tasks) {
      if (task.target == DownloadTarget.ugoiraGif.name) {
        next[task.illustId] = _stateFromTask(task);
      }
    }
    return next;
  }

  static UgoiraExportTaskState _stateFromTask(DownloadTaskSnapshot task) {
    final total = task.totalBytes ?? 0;
    final processed = task.receivedBytes;
    final phase = switch (task.status) {
      DownloadStatus.queued => UgoiraExportPhase.preparing,
      DownloadStatus.running =>
        total == 0 ? UgoiraExportPhase.preparing : UgoiraExportPhase.running,
      DownloadStatus.finalizing => UgoiraExportPhase.finalizing,
      DownloadStatus.succeeded => UgoiraExportPhase.succeeded,
      DownloadStatus.canceling ||
      DownloadStatus.canceled => UgoiraExportPhase.canceled,
      DownloadStatus.failed ||
      DownloadStatus.retryable ||
      DownloadStatus.orphaned => UgoiraExportPhase.failed,
    };
    final exportStatus = switch (task.status) {
      DownloadStatus.queued => UgoiraExportStatus.queued,
      DownloadStatus.running => UgoiraExportStatus.running,
      DownloadStatus.finalizing => UgoiraExportStatus.finalizing,
      DownloadStatus.succeeded => UgoiraExportStatus.succeeded,
      DownloadStatus.canceling ||
      DownloadStatus.canceled => UgoiraExportStatus.canceled,
      DownloadStatus.failed ||
      DownloadStatus.retryable ||
      DownloadStatus.orphaned => UgoiraExportStatus.failed,
    };
    return UgoiraExportTaskState(
      phase: phase,
      snapshot: UgoiraExportSnapshot(
        status: exportStatus,
        processedFrames: processed,
        totalFrames: total,
        uri: task.finalUri,
        error: task.error,
        failureKind: task.failureKind,
      ),
      failureKind: task.failureKind,
      error: task.error,
    );
  }
}

final ugoiraExportControllerProvider =
    NotifierProvider<UgoiraExportController, Map<int, UgoiraExportTaskState>>(
      UgoiraExportController.new,
    );
