import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/pixiv_image.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_recovery.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/pixiv_http_client.dart';
import '../../../core/ugoira/ugoira_cache.dart';
import '../../../core/ugoira/ugoira_decoder.dart';
import '../../../core/ugoira/ugoira_export.dart';
import '../../../core/ugoira/ugoira_providers.dart';
import '../../../core/ugoira/ugoira_repository.dart';
import '../../../core/ugoira/ugoira_scheduler.dart';
import '../../../core/ugoira/ugoira_zip.dart';

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
  UgoiraExportJob? _exportJob;
  String? _error;
  var _loading = false;
  var _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final scheduler = _scheduler;
    if (scheduler == null) return;
    if (state == AppLifecycleState.resumed) {
      scheduler.start();
      _ensureCurrentFrame();
    } else {
      scheduler.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheduler = _scheduler;
    final cache = _cache;
    final currentImage = scheduler == null || cache == null
        ? null
        : cache.get(scheduler.currentIndex);
    final aspectRatio = widget.width > 0 && widget.height > 0
        ? widget.width / widget.height
        : 1.0;

    return VisibilityDetector(
      key: ValueKey('ugoira-${widget.illustId}'),
      onVisibilityChanged: (info) {
        final activeScheduler = _scheduler;
        if (activeScheduler == null) return;
        if (info.visibleFraction == 0) {
          activeScheduler.stop();
        } else {
          activeScheduler.start();
          _ensureCurrentFrame();
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
                    color: Colors.white,
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
                      tooltip: '保存 GIF',
                      onPressed: _export,
                      icon:
                          _exportJob?.snapshot.status ==
                                  UgoiraExportStatus.running ||
                              _exportJob?.snapshot.status ==
                                  UgoiraExportStatus.finalizing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.file_download_outlined),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover(ui.Image? currentImage) {
    final image = currentImage == null
        ? PixivImage(
            url: widget.previewUrl,
            fit: BoxFit.fitWidth,
            width: double.infinity,
          )
        : RawImage(
            image: currentImage,
            fit: BoxFit.fitWidth,
            width: double.infinity,
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

  void _togglePlayback() {
    if (_disposed) return;
    final scheduler = _scheduler;
    if (scheduler == null) {
      _loadAndPlay();
      return;
    }
    if (scheduler.isPlaying) {
      scheduler.pause();
    } else {
      scheduler.play();
      _ensureCurrentFrame();
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
      if (play) scheduler.play();
      await _ensureFrame(0);
    } on ApiCancelled {
      if (!_disposed) setState(() => _error = '加载已取消');
    } catch (error) {
      if (!_disposed) setState(() => _error = _friendlyError(error));
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
    unawaited(_ensureFrame(index));
    if (mounted) setState(() {});
  }

  Future<void> _ensureCurrentFrame() {
    final scheduler = _scheduler;
    if (scheduler == null) return Future.value();
    return _ensureFrame(scheduler.currentIndex);
  }

  Future<void> _ensureFrame(int index) {
    final asset = _asset;
    final cache = _cache;
    if (asset == null || cache == null || _disposed) return Future.value();
    if (cache.get(index) != null) return Future.value();
    final active = _decodeFuture;
    if (active != null) return active;
    final future = _decodeOne(asset, cache, index);
    _decodeFuture = future;
    return future.whenComplete(() {
      if (identical(_decodeFuture, future)) {
        _decodeFuture = null;
        final scheduler = _scheduler;
        if (scheduler != null && scheduler.currentIndex != index) {
          unawaited(_ensureFrame(scheduler.currentIndex));
        }
      }
    });
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
      if (!_disposed) setState(() => _error = _friendlyError(error));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先登录后保存 GIF')));
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
      UgoiraExportStatus.succeeded => 'GIF 已保存',
      UgoiraExportStatus.canceled => 'GIF 保存已取消',
      _ => 'GIF 保存失败：${result.error ?? '未知错误'}',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  static String _friendlyError(Object error) {
    if (error is UgoiraArchiveException) return '动图压缩包无效：${error.message}';
    if (error is UgoiraDecodeException) return '动图帧损坏：${error.message}';
    return '动图加载失败：$error';
  }

  DownloadSubmissionContext? _currentDownloadContext() {
    final accountState = ref.read(accountStoreProvider).asData?.value;
    final account = accountState?.usableCurrent;
    if (accountState == null || account == null) return null;
    return DownloadSubmissionContext(
      accountId: account.id,
      credentialRevision: accountState.credentialRevision,
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
        color: Colors.white,
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
              Text(message, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}
