import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../download/download_manager.dart' show classifyDownloadFailure;
import '../download/download_providers.dart';
import '../download/download_recovery.dart';
import '../network/api_error.dart';
import '../network/pixiv_http_client.dart';
import '../settings/settings_controller.dart';
import 'ugoira_export.dart';
import 'ugoira_limits.dart';
import 'ugoira_providers.dart';
import 'ugoira_repository.dart';

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

class _ActiveUgoiraExport {
  _ActiveUgoiraExport({required this.loadCancelToken});

  final CancelToken loadCancelToken;
  UgoiraExportJob? job;
  Future<UgoiraExportTaskState>? future;
  bool canceled = false;

  void cancel() {
    canceled = true;
    loadCancelToken.cancel();
    job?.cancel();
  }
}

/// Optional encoder factory override for deterministic tests; production uses
/// [ImagePackageUgoiraGifEncoder].
final ugoiraGifEncoderFactoryProvider =
    Provider<UgoiraGifEncoder Function(UgoiraLimits limits)?>((_) => null);

/// App-level owner for Ugoira GIF exports.
///
/// Each export independently loads and owns its own [UgoiraAsset] and
/// temporary ZIP archive (never borrowing [UgoiraViewer]'s playback asset per
/// `IMG-10`), survives navigating away from the detail page, reports live
/// progress/cancellation on same-process re-entry, and disposes its job and
/// temporary archive on every terminal path.
class UgoiraExportController extends Notifier<Map<int, UgoiraExportTaskState>> {
  final Map<int, _ActiveUgoiraExport> _active = {};

  @override
  Map<int, UgoiraExportTaskState> build() {
    ref.onDispose(_disposeAll);
    return const {};
  }

  /// Whether a signed-in account context is currently available for export.
  bool get isSignedIn => _currentDownloadContext() != null;

  DownloadSubmissionContext? _currentDownloadContext() {
    final accountState = ref.read(accountStoreProvider).asData?.value;
    final account = accountState?.usableCurrent;
    if (accountState == null || account == null) return null;
    // C4: a token refresh must not change the stable owner identity.
    return DownloadSubmissionContext(
      accountId: account.id,
      destination: ref.read(downloadDestinationProvider),
    );
  }

  /// Starts (or joins an already running) GIF export for [illustId].
  Future<UgoiraExportTaskState> export(int illustId) {
    final existing = _active[illustId];
    if (existing?.future case final future?) return future;

    final submissionContext = _currentDownloadContext();
    if (submissionContext == null) {
      return Future.value(
        const UgoiraExportTaskState(
          phase: UgoiraExportPhase.failed,
          failureKind: DownloadFailureKind.auth,
        ),
      );
    }

    final handle = _ActiveUgoiraExport(loadCancelToken: CancelToken());
    _active[illustId] = handle;
    _setEntry(
      illustId,
      const UgoiraExportTaskState(phase: UgoiraExportPhase.preparing),
    );
    final future = _run(illustId, handle, submissionContext);
    handle.future = future;
    return future;
  }

  /// Cancels an active archive download or GIF quantization for [illustId].
  void cancel(int illustId) {
    _active[illustId]?.cancel();
  }

  void _setEntry(int illustId, UgoiraExportTaskState entry) {
    if (!ref.mounted) return;
    state = {...state, illustId: entry};
  }

  Future<UgoiraExportTaskState> _run(
    int illustId,
    _ActiveUgoiraExport handle,
    DownloadSubmissionContext submissionContext,
  ) async {
    UgoiraAsset? asset;
    UgoiraExportJob? job;
    StreamSubscription<UgoiraExportSnapshot>? subscription;
    var finalState = const UgoiraExportTaskState(
      phase: UgoiraExportPhase.canceled,
    );
    try {
      final repository = ref.read(ugoiraRepositoryProvider);
      asset = await repository.load(
        illustId,
        cancelToken: handle.loadCancelToken,
      );
      if (handle.canceled || !ref.mounted) {
        return finalState;
      }
      final sinkFactory = ref.read(downloadSinkFactoryProvider);
      final recoveryStore = ref.read(ugoiraRecoveryStoreProvider);
      final encoderFactory = ref.read(ugoiraGifEncoderFactoryProvider);
      job = UgoiraExportJob(
        asset: asset,
        sinkFactory: sinkFactory,
        encoderFactory: encoderFactory,
        recoveryStore: recoveryStore,
        submissionContext: submissionContext,
        submissionContextProvider: _currentDownloadContext,
      );
      handle.job = job;
      if (handle.canceled) {
        job.cancel();
      }
      subscription = job.events.listen((snapshot) {
        _setEntry(illustId, _fromSnapshot(snapshot));
      });
      final result = await job.start();
      finalState = _fromSnapshot(result);
    } on ApiCancelled {
      finalState = const UgoiraExportTaskState(
        phase: UgoiraExportPhase.canceled,
      );
    } catch (error) {
      finalState = UgoiraExportTaskState(
        phase: UgoiraExportPhase.failed,
        failureKind: classifyDownloadFailure(error),
        error: error.toString(),
      );
    } finally {
      await subscription?.cancel();
      if (job != null) await job.dispose();
      if (asset != null) await asset.dispose();
      if (identical(_active[illustId], handle)) {
        _active.remove(illustId);
      }
      _setEntry(illustId, finalState);
    }
    return finalState;
  }

  static UgoiraExportTaskState _fromSnapshot(UgoiraExportSnapshot snapshot) {
    final phase = switch (snapshot.status) {
      UgoiraExportStatus.queued ||
      UgoiraExportStatus.running => UgoiraExportPhase.running,
      UgoiraExportStatus.finalizing => UgoiraExportPhase.finalizing,
      UgoiraExportStatus.succeeded => UgoiraExportPhase.succeeded,
      UgoiraExportStatus.canceled => UgoiraExportPhase.canceled,
      UgoiraExportStatus.failed => UgoiraExportPhase.failed,
    };
    return UgoiraExportTaskState(
      phase: phase,
      snapshot: snapshot,
      failureKind: snapshot.failureKind,
      error: snapshot.error,
    );
  }

  void _disposeAll() {
    final handles = _active.values.toList();
    _active.clear();
    for (final handle in handles) {
      handle.cancel();
    }
  }
}

final ugoiraExportControllerProvider =
    NotifierProvider<UgoiraExportController, Map<int, UgoiraExportTaskState>>(
      UgoiraExportController.new,
    );
