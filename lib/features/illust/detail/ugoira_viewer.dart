import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/pixiv_image.dart';
import '../../../app/motion/drag_to_dismiss.dart';
import '../../../app/theme/func_tokens.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_recovery.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/pixiv_http_client.dart';
import '../../../core/ugoira/ugoira_cache.dart';
import '../../../core/ugoira/ugoira_decoder.dart';
import '../../../core/ugoira/ugoira_export.dart';
import '../../../core/ugoira/ugoira_providers.dart';
import '../../../core/ugoira/ugoira_repository.dart';
import '../../../core/ugoira/ugoira_scheduler.dart';
import '../../../core/ugoira/ugoira_zip.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../l10n/context.dart';

/// Inline beta56-compatible Ugoira surface. The cover, play affordance and
/// paused overlay stay in the detail page; ZIP/decode/export resources are
/// owned by this widget and are torn down on route/lifecycle changes.
class UgoiraViewer extends ConsumerStatefulWidget {
  const UgoiraViewer({
    super.key,
    required this.illustId,
    required this.previewUrl,
    required this.width,
    required this.height,
    this.downloadMode = false,
    this.onLongPress,
    this.heroTag,
    this.flightShuttleBuilder,
  });

  final int illustId;
  final String previewUrl;
  final int width;
  final int height;
  final bool downloadMode;
  final VoidCallback? onLongPress;
  final Object? heroTag;
  final HeroFlightShuttleBuilder? flightShuttleBuilder;

  @override
  ConsumerState<UgoiraViewer> createState() => _UgoiraViewerState();
}

class _UgoiraViewerState extends ConsumerState<UgoiraViewer>
    with WidgetsBindingObserver {
  UgoiraAsset? _asset;
  UgoiraFrameCache<ui.Image>? _cache;
  UgoiraScheduler? _scheduler;
  CancelToken? _loadCancelToken;
  Future<void>? _loadFuture;
  Future<void>? _decodeFuture;
  int? _decodeIndex;

  /// Frame indexes that failed decoding in the current archive.  A failed
  /// frame must not be retried on every scheduler tick: doing so used to
  /// produce a rapid pause/resume loop (and apparent frame corruption) while
  /// the ZIP was still being decoded.
  final Set<int> _failedFrames = <int>{};
  UgoiraExportJob? _exportJob;
  String? _error;
  var _loading = false;
  var _frameReady = false;
  var _playRequested = false;
  var _visible = true;
  var _appResumed = true;
  int? _lastFrameIndex;
  var _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final scheduler = _scheduler;
    if (state == AppLifecycleState.resumed) {
      _appResumed = true;
      if (scheduler != null) unawaited(_startPlaybackIfReady(scheduler));
    } else {
      _appResumed = false;
      scheduler?.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheduler = _scheduler;
    final cache = _cache;
    final currentImage = _currentImage(scheduler, cache);
    final aspectRatio = widget.width > 0 && widget.height > 0
        ? widget.width / widget.height
        : 1.0;

    return DragToDismiss(
      onDismissed: () => Navigator.of(context).pop<void>(),
      child: VisibilityDetector(
        key: ValueKey('ugoira-${widget.illustId}'),
        onVisibilityChanged: (info) {
          final activeScheduler = _scheduler;
          _visible = info.visibleFraction > 0;
          if (activeScheduler == null) return;
          if (!_visible) {
            activeScheduler.stop();
          } else {
            unawaited(_startPlaybackIfReady(activeScheduler));
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _togglePlayback,
          onLongPress: widget.onLongPress,
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildCover(currentImage),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_error != null)
                  _ErrorOverlay(message: _error!, onRetry: _togglePlayback)
                else if (scheduler == null || !scheduler.isPlaying)
                  const _PlayOverlay(),
                Positioned(
                  left: 7,
                  bottom: 7,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      color: const Color(0x99343838),
                    ),
                    child: const Icon(
                      Icons.gif_box_outlined,
                      color: FuncTokens.lightBackground,
                      size: 30,
                    ),
                  ),
                ),
                if (widget.downloadMode && _asset != null)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: context.l10n.ugoiraSaveGif,
                        onPressed: _export,
                        icon:
                            _exportJob?.snapshot.status ==
                                    UgoiraExportStatus.running ||
                                _exportJob?.snapshot.status ==
                                    UgoiraExportStatus.finalizing
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.file_download_outlined),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCover(ui.Image? currentImage) {
    // Keep the network cover mounted even after a decoded GIF frame appears.
    // Apart from avoiding a blank frame when playback is starting/stopping,
    // this makes preview URL changes use the same gapless PixivImage path as
    // still and multi-page works. The decoded frame simply paints above the
    // cover while it is available.
    final image = Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: PixivImage.hero(
            widget.previewUrl,
            tag: widget.heroTag,
            fit: BoxFit.fitWidth,
          ),
        ),
        if (currentImage != null)
          Positioned.fill(
            child: RawImage(
              image: currentImage,
              fit: BoxFit.fitWidth,
              width: double.infinity,
            ),
          ),
      ],
    );
    final tag = widget.heroTag;
    if (tag == null) return image;
    return Hero(
      tag: tag,
      flightShuttleBuilder: widget.flightShuttleBuilder,
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: image,
      ),
    );
  }

  ui.Image? _currentImage(
    UgoiraScheduler? scheduler,
    UgoiraFrameCache<ui.Image>? cache,
  ) {
    if (scheduler == null || cache == null) return null;
    final current = cache.get(scheduler.currentIndex);
    if (current != null) {
      _lastFrameIndex = scheduler.currentIndex;
      return current;
    }
    final previousIndex = _lastFrameIndex;
    return previousIndex == null ? null : cache.get(previousIndex);
  }

  void _togglePlayback() {
    if (_disposed) return;
    if (_error != null) {
      _playRequested = true;
      _loadAndPlay();
      return;
    }
    final scheduler = _scheduler;
    if (scheduler == null || !_frameReady) {
      _playRequested = true;
      _loadAndPlay();
      return;
    }
    if (scheduler.isPlaying) {
      _playRequested = false;
      scheduler.pause();
    } else {
      _playRequested = true;
      unawaited(_startPlaybackIfReady(scheduler));
    }
    setState(() {});
  }

  Future<void> _loadAndPlay() async {
    await _load(play: true);
  }

  Future<void> _load({required bool play}) {
    return _loadFuture ??= _performLoad(play: play);
  }

  Future<void> _performLoad({required bool play}) async {
    if (!mounted) return;
    _playRequested = play;
    _frameReady = false;
    _failedFrames.clear();
    if (_scheduler != null) _releaseLoadedResources();
    setState(() {
      _loading = true;
      _error = null;
    });
    final cancelToken = CancelToken();
    _loadCancelToken = cancelToken;
    try {
      final repository = ref.read(ugoiraRepositoryProvider);
      final asset = await repository.load(
        widget.illustId,
        cancelToken: cancelToken,
      );
      if (_disposed) {
        await asset.dispose();
        return;
      }
      final cache = UgoiraFrameCache<ui.Image>(
        maxBytes: asset.limits.maxDecodedWindowBytes,
        sizeOf: (image) => image.width * image.height * 4,
        dispose: (image) => image.dispose(),
      );
      final scheduler = UgoiraScheduler(
        delays: [
          for (final frame in asset.metadata.frames)
            Duration(milliseconds: frame.delayMs),
        ],
        onFrame: _onFrame,
      );
      _asset = asset;
      _cache = cache;
      _scheduler = scheduler;
      await _ensureFrame(0);
      if (!_disposed &&
          mounted &&
          identical(_scheduler, scheduler) &&
          _cache?.get(0) != null) {
        _frameReady = true;
        if (_playRequested) unawaited(_startPlaybackIfReady(scheduler));
      }
    } on ApiCancelled {
      if (!_disposed) {
        setState(() => _error = context.l10n.ugoiraLoadCanceled);
      }
    } catch (error) {
      if (!_disposed) {
        setState(() => _error = _friendlyError(context, error));
      }
    } finally {
      _loadCancelToken = null;
      if (!_disposed && mounted) {
        setState(() => _loading = false);
      }
      _loadFuture = null;
    }
  }

  void _onFrame(int index) {
    if (_disposed) return;
    final scheduler = _scheduler;
    final cache = _cache;
    if (scheduler != null && cache != null && cache.get(index) == null) {
      scheduler.suspend();
      unawaited(
        _ensureFrame(index).then((_) {
          if (!_disposed && mounted && !_failedFrames.contains(index)) {
            unawaited(_startPlaybackIfReady(scheduler));
          }
        }),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _startPlaybackIfReady(UgoiraScheduler scheduler) async {
    if (_disposed ||
        !mounted ||
        !identical(_scheduler, scheduler) ||
        !_frameReady ||
        !_playRequested ||
        !_visible ||
        !_appResumed) {
      return;
    }
    final cache = _cache;
    if (cache == null) return;
    final index = scheduler.currentIndex;
    if (_failedFrames.contains(index)) {
      // Keep the last successfully decoded frame visible and stop the
      // scheduler.  Retrying a known-bad frame on every tick is what caused
      // GIFs to jump/flash before the archive had finished loading.
      _playRequested = false;
      if (scheduler.isPlaying) scheduler.pause();
      if (mounted) setState(() {});
      return;
    }
    if (cache.get(index) == null) {
      scheduler.suspend();
      await _ensureFrame(index);
      if (_disposed ||
          !mounted ||
          !identical(_scheduler, scheduler) ||
          !_frameReady ||
          !_playRequested ||
          !_visible ||
          !_appResumed ||
          cache.get(index) == null ||
          _failedFrames.contains(index)) {
        if (_failedFrames.contains(index)) {
          _playRequested = false;
          if (scheduler.isPlaying) scheduler.pause();
          if (mounted) setState(() {});
        }
        return;
      }
    }
    if (!scheduler.isPlaying) {
      scheduler.play();
    } else {
      scheduler.start();
    }
    if (mounted) setState(() {});
  }

  Future<void> _ensureFrame(int index) {
    final asset = _asset;
    final cache = _cache;
    if (asset == null || cache == null || _disposed) return Future.value();
    if (cache.get(index) != null) return Future.value();
    if (_failedFrames.contains(index)) return Future.value();
    final active = _decodeFuture;
    if (active != null) {
      if (_decodeIndex == index) return active;
      return active.then((_) => _ensureFrame(index));
    }
    final future = _decodeOne(asset, cache, index);
    _decodeFuture = future;
    _decodeIndex = index;
    return future.whenComplete(() {
      if (identical(_decodeFuture, future)) {
        _decodeFuture = null;
        _decodeIndex = null;
        final scheduler = _scheduler;
        if (scheduler != null && scheduler.currentIndex != index) {
          unawaited(_ensureFrame(scheduler.currentIndex));
        }
      }
    });
  }

  void _releaseLoadedResources() {
    final scheduler = _scheduler;
    final cache = _cache;
    final asset = _asset;
    _scheduler = null;
    _cache = null;
    _asset = null;
    _frameReady = false;
    _lastFrameIndex = null;
    _failedFrames.clear();
    scheduler?.dispose();
    cache?.clear();
    if (asset != null) unawaited(asset.dispose());
  }

  Future<void> _decodeOne(
    UgoiraAsset asset,
    UgoiraFrameCache<ui.Image> cache,
    int index,
  ) async {
    ui.Image? image;
    try {
      image = await asset.decodeFrame(index);
      if (_disposed || !identical(_asset, asset)) return;
      cache.put(index, image);
      image = null;
      if (mounted) setState(() {});
    } catch (error) {
      if (!_disposed && identical(_asset, asset)) {
        _failedFrames.add(index);
        final scheduler = _scheduler;
        if (scheduler != null && scheduler.currentIndex == index) {
          _playRequested = false;
          if (scheduler.isPlaying) scheduler.pause();
        }
        setState(() => _error = _friendlyError(context, error));
      }
    } finally {
      image?.dispose();
    }
  }

  Future<void> _export() async {
    if (_disposed ||
        _exportJob?.snapshot.status == UgoiraExportStatus.running ||
        _exportJob?.snapshot.status == UgoiraExportStatus.finalizing) {
      return;
    }
    if (_asset == null) await _load(play: false);
    final asset = _asset;
    if (asset == null || _disposed) return;
    final previousJob = _exportJob;
    if (previousJob != null) await previousJob.dispose();
    final submissionContext = _currentDownloadContext();
    if (submissionContext == null) {
      if (mounted) {
        showAppSnackBar(context, context.l10n.ugoiraLoginRequired);
      }
      return;
    }
    final job = UgoiraExportJob(
      asset: asset,
      sinkFactory: ref.read(downloadSinkFactoryProvider),
      recoveryStore: ref.read(ugoiraRecoveryStoreProvider),
      submissionContext: submissionContext,
      submissionContextProvider: _currentDownloadContext,
    );
    _exportJob = job;
    final subscription = job.events.listen((_) {
      if (mounted) setState(() {});
    });
    final result = await job.start();
    await subscription.cancel();
    if (!mounted) return;
    final message = switch (result.status) {
      UgoiraExportStatus.succeeded => context.l10n.ugoiraSaved,
      UgoiraExportStatus.canceled => context.l10n.ugoiraSaveCanceled,
      _ => context.l10n.ugoiraSaveFailed(result.error ?? 'unknown error'),
    };
    showAppSnackBar(context, message);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _loadCancelToken?.cancel();
    _scheduler?.dispose();
    _cache?.clear();
    final asset = _asset;
    if (asset != null) unawaited(asset.dispose());
    final job = _exportJob;
    if (job != null) unawaited(job.dispose());
    super.dispose();
  }

  String _friendlyError(BuildContext context, Object error) {
    if (error is UgoiraArchiveException) {
      return context.l10n.ugoiraArchiveInvalid(error.message);
    }
    if (error is UgoiraDecodeException) {
      return context.l10n.ugoiraFrameCorrupt(error.message);
    }
    return context.l10n.ugoiraLoadFailed(error.toString());
  }

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
}

class _PlayOverlay extends StatelessWidget {
  const _PlayOverlay();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Icon(
        Icons.play_circle_outline_outlined,
        size: 70,
        color: FuncTokens.lightBackground,
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x99000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: TextStyle(color: FuncTokens.lightBackground),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: Text(context.l10n.retry)),
            ],
          ),
        ),
      ),
    );
  }
}
