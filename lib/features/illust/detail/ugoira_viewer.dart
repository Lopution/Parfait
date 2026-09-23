import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/haptics/app_haptics.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/motion/hero_transition.dart';
import '../../../app/theme/func_tokens.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../core/auth/account_store.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/entity/illust_entity.dart';
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
    this.heroTag,
    this.flightShuttleBuilder,
    this.heroImageUrl,
    this.heroDecodeWidth,
    this.heroTier,
    this.detailUrl,
    this.heroPopUrl,
    this.heroPopDecodeWidth,
    this.tier,
  });

  final int illustId;

  /// Always-available fallback URL ([IllustEntity.imageUrls.large]); the
  /// cover only reaches it once the Hero hand-off phase is over and no
  /// detail-tier URL exists.
  final String previewUrl;

  /// Detail-quality URL once the detail payload is merged — same role as
  /// [DetailPageImage.detailUrl].
  final String? detailUrl;

  /// Feed-provided preview URL for the opening Hero hand-off. While the
  /// route transition is running the cover must stay on this exact cache
  /// entry — switching to the detail URL mid-flight leaves the shuttle on
  /// the grey placeholder until a fresh screen-width decode finishes.
  final String? heroImageUrl;

  /// The quality tier [heroImageUrl] represents.
  final IllustImageTier? heroTier;

  /// The quality tier the non-hero cover URL represents — feeds the
  /// per-(work,page) tier registry so later higher-tier requests can serve
  /// from cache.
  final IllustImageTier? tier;
  final int width;
  final int height;
  final Object? heroTag;
  final HeroFlightShuttleBuilder? flightShuttleBuilder;

  /// Decode width of the feed image that opened this detail route. Keeping
  /// the first Hero frame at that width lets the existing card texture travel
  /// into the detail page without a second large texture upload.
  final int? heroDecodeWidth;

  /// Lightweight destination texture used only during a reverse Hero flight.
  /// Keeping it separate from the animated cover prevents a decoded frame or
  /// original-sized upload from replacing the destination card mid-flight.
  final String? heroPopUrl;
  final int? heroPopDecodeWidth;

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

  /// Same hand-off guard as DetailPageImage: detail data can land while the
  /// route is still flying. The cover keeps the feed preview URL (and its
  /// card-width decode) until the transition completes, then upgrades
  /// gaplessly. Without this the first frame after landing is a fresh
  /// screen-width decode and the shuttle spends the flight on grey.
  bool _routeTransitionComplete = true;
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    _routeAnimation = animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _routeTransitionComplete = true;
    } else {
      _routeTransitionComplete = false;
      animation.addStatusListener(_handleRouteAnimationStatus);
    }
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed && !_routeTransitionComplete) {
      setState(() => _routeTransitionComplete = true);
    }
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

    return VisibilityDetector(
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
        // An explicit no-op long-press handler keeps LongPressGesture-
        // Recognizer in the arena: without it a held tap still resolves
        // [onTap] on release and would toggle playback (the "inert
        // long-press" test).
        onLongPress: () {},
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildCover(currentImage),
              if (_loading)
                const FeedLoading()
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
              // The GIF export entry is always visible — the ugoira
              // equivalent of the plain download action. One slot carries
              // three states: preparing (asset not loaded → disabled),
              // exporting (progress spinner), failed (error icon, tap to
              // retry).
              Positioned(
                top: 12,
                right: 12,
                child: _ExportButton(
                  assetReady: _asset != null,
                  snapshot: _exportJob?.snapshot,
                  onExport: _export,
                ),
              ),
            ],
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
    // Hero hand-off phase: while the route is flying (or the detail payload
    // has not produced a URL yet) the cover stays on the feed card's URL at
    // the feed card's decode width — the exact decoded cache entry. A cached
    // detail otherwise promotes the cover to the detail tier mid-flight and
    // the shuttle renders the grey placeholder until that decode lands.
    final onHeroPhase =
        widget.heroImageUrl != null &&
        (widget.detailUrl == null || !_routeTransitionComplete);
    final coverUrl = onHeroPhase
        ? widget.heroImageUrl!
        : (widget.detailUrl ?? widget.previewUrl);
    final image = Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: PixivImage.hero(
            coverUrl,
            tag: widget.heroTag,
            fit: BoxFit.fitWidth,
            tierKey: '${widget.illustId}_0',
            tier: onHeroPhase ? widget.heroTier : widget.tier,
            // A recorded higher tier must not replace the feed URL during
            // the flight — the upgrade would point at an undecoded entry.
            tierUpgrade: !onHeroPhase,
            decodeWidth: onHeroPhase ? widget.heroDecodeWidth : null,
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
    final popUrl = widget.heroPopUrl;
    final popChild = popUrl == null
        ? null
        : SizedBox.expand(
            child: PixivImage.detail(
              popUrl,
              fit: BoxFit.fitWidth,
              transitionKey: tag,
              decodeWidth: widget.heroPopDecodeWidth,
              tierUpgrade: false,
            ),
          );
    return Hero(
      tag: tag,
      flightShuttleBuilder: widget.flightShuttleBuilder,
      child: IllustHeroFlightChild(
        popChild: popChild,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: image,
        ),
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
        AppHaptics.error();
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
    // Save succeeded → success; failed → error (§5.6); a user cancel is
    // a deliberate dismissal and gets no vibration.
    if (result.status == UgoiraExportStatus.succeeded) {
      AppHaptics.success();
    } else if (result.status != UgoiraExportStatus.canceled) {
      AppHaptics.error();
    }
    showAppSnackBar(context, message);
  }

  @override
  void dispose() {
    _disposed = true;
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
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

/// Always-visible GIF export entry (R5). One slot presents three states:
/// preparing (asset not loaded → disabled icon), exporting (progress
/// spinner with percent tooltip), failed (error icon, tap retries).
class _ExportButton extends StatelessWidget {
  const _ExportButton({
    required this.assetReady,
    required this.snapshot,
    required this.onExport,
  });

  /// Whether the ugoira ZIP/metadata has loaded. Until it has, the button
  /// is a disabled spinner — there is nothing exportable yet.
  final bool assetReady;
  final UgoiraExportSnapshot? snapshot;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = snapshot?.status;
    final exporting =
        status == UgoiraExportStatus.running ||
        status == UgoiraExportStatus.finalizing ||
        status == UgoiraExportStatus.queued;

    final String tooltip;
    final Widget icon;
    final VoidCallback? onPressed;
    if (!assetReady && snapshot == null) {
      // Nothing has been loaded yet — the entry stays discoverable but
      // inert until the first play loads the archive. A static disabled
      // icon, not a spinner: a perpetual animation here would keep every
      // ancestor scheduling frames (and would never let pumpAndSettle
      // settle in tests).
      tooltip = l10n.ugoiraSaveGif;
      icon = const Icon(Icons.file_download_outlined);
      onPressed = null;
    } else if (exporting) {
      final percent = ((snapshot?.progress ?? 0) * 100).round();
      tooltip = l10n.ugoiraExporting(percent);
      icon = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
      onPressed = null;
    } else if (status == UgoiraExportStatus.failed) {
      tooltip = l10n.retry;
      icon = Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.error,
      );
      onPressed = onExport;
    } else {
      tooltip = l10n.ugoiraSaveGif;
      icon = const Icon(Icons.file_download_outlined);
      onPressed = onExport;
    }

    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      child: IconButton(tooltip: tooltip, onPressed: onPressed, icon: icon),
    );
  }
}
