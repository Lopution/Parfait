import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:octo_image/octo_image.dart';

import 'motion/motion_tokens.dart';
import 'image_tier_cache.dart';
import '../core/debug/frame_probe.dart';
import '../core/entity/illust_entity.dart';
import '../core/image/image_demand.dart';
import '../core/image/image_worker.dart';
import '../core/image/image_worker_protocol.dart';
import '../core/image/image_worker_providers.dart';
import '../core/image/lane_permit_gate.dart';
import '../core/image/worker_image_provider.dart';
import '../l10n/app_localizations.dart';
import 'widgets/image_load_progress.dart';

export '../core/image/lane_permit_gate.dart' show ImageFetchPriority;
export 'widgets/image_load_progress.dart';

/// Decode policy of a [PixivImage] variant (R8 performance boundary).
enum PixivImageSize {
  /// Feed cards and row cards: decode at the layout width.
  feed,

  /// Detail pages and wide headers: decode at the screen width.
  detail,

  /// Full-screen viewer: no decode limit.
  viewer,

  /// Avatars: decode at the avatar box size.
  avatar,
}

/// Outcome of [PixivImage.preload].
enum ImagePreloadResult {
  decoded,

  /// Still queued when nobody wanted the URL any more; never fetched.
  dropped,
  failed,
}

/// A decoded entry: the URL and the width it was decoded at.
typedef _HistoryEntry = (String url, int? decodeWidth);

/// Shared Pixiv CDN image widget. Every image loads through the background
/// image worker (which sends the Referer the CDN requires), so it must sit
/// under a [ProviderScope].
class PixivImage extends ConsumerStatefulWidget {
  const PixivImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.alignment = Alignment.center,
    this.placeholderColor,
    this.placeholderWidget,
    this.fade = true,
    this.sizeToImage = false,
    this.transitionKey,
    this.filterColor,
    this.filterBlendMode,
    this.memCacheWidth,
    this.filterQuality = FilterQuality.low,
    this.tierKey,
    this.tier,
    this.tierUpgrade = true,
    this.progress,
  });

  /// Feed/row card variant: decode width derives from [layoutWidth] (the
  /// box the image paints into), capped at 1.5x logical pixels.
  PixivImage.feed(
    String url, {
    Key? key,
    required double layoutWidth,
    BoxFit fit = BoxFit.cover,
    Alignment alignment = Alignment.center,
    double? width,
    double? height,
    Color? placeholderColor,
    Widget? placeholderWidget,
    Object? transitionKey,
    String? tierKey,
    IllustImageTier? tier,
    bool tierUpgrade = true,
    int? decodeWidth,
  }) : this(
         key: key,
         url: url,
         fit: fit,
         alignment: alignment,
         width: width,
         height: height,
         placeholderColor: placeholderColor,
         placeholderWidget: placeholderWidget,
         transitionKey: transitionKey,
         memCacheWidth: decodeWidthFor(layoutWidth),
         tierKey: tierKey,
         tier: tier,
         tierUpgrade: tierUpgrade,
       );

  /// Avatar variant: decode width derives from the avatar box [size].
  PixivImage.avatar(
    String url, {
    Key? key,
    required double size,
    BoxFit fit = BoxFit.cover,
    Widget? placeholderWidget,
  }) : this(
         key: key,
         url: url,
         fit: fit,
         placeholderWidget: placeholderWidget,
         memCacheWidth: decodeWidthFor(size),
       );

  /// Detail variant: decode at the screen width.
  PixivImage.detail(
    String url, {
    Key? key,
    BoxFit fit = BoxFit.cover,
    Alignment alignment = Alignment.center,
    Color? filterColor,
    BlendMode? filterBlendMode,
    Object? transitionKey,
    String? tierKey,
    IllustImageTier? tier,
    bool tierUpgrade = true,
    Widget? placeholderWidget,
    ValueNotifier<ImageLoadProgress>? progress,
    // Hero hand-off phase: decode at the source card's width so the first
    // frame is the exact cache entry the feed already decoded — without
    // this, the detail page re-decodes the same file at screen width and
    // the landing frame flashes the placeholder.
    int? decodeWidth,
  }) : this(
         key: key,
         url: url,
         fit: fit,
         alignment: alignment,
         filterColor: filterColor,
         filterBlendMode: filterBlendMode,
         transitionKey: transitionKey,
         memCacheWidth: decodeWidth ?? screenDecodeWidth,
         tierKey: tierKey,
         tier: tier,
         tierUpgrade: tierUpgrade,
         placeholderWidget: placeholderWidget,
         progress: progress,
       );

  /// Hero hand-off variant: keeps the transition history keyed by [tag] so a
  /// rebuilt endpoint reuses the last displayed quality as its placeholder.
  PixivImage.hero(
    String url, {
    Key? key,
    required Object? tag,
    BoxFit fit = BoxFit.cover,
    Alignment alignment = Alignment.center,
    Color? placeholderColor,
    String? tierKey,
    IllustImageTier? tier,
    bool tierUpgrade = true,
    int? decodeWidth,
  }) : this(
         key: key,
         url: url,
         fit: fit,
         alignment: alignment,
         placeholderColor: placeholderColor,
         transitionKey: tag,
         tierKey: tierKey,
         tier: tier,
         tierUpgrade: tierUpgrade,
         memCacheWidth: decodeWidth ?? screenDecodeWidth,
       );

  /// Decode width for a logical [layoutWidth] box: the box's physical pixel
  /// width (`layoutWidth x DPR`) so the decoded bitmap is 1:1 sharp on
  /// screen. The codec never upscales, so sources narrower than the target
  /// decode at their native width — the effective cost ceiling is the
  /// *source tier* chosen for the slot, not this value.
  ///
  /// The former `layoutWidth x 1.5` cap was removed on purpose: on
  /// DPR >= 2 devices it decoded feed cards at half their display
  /// resolution, which read as blurry, aliased thumbnails.
  static int decodeWidthFor(double layoutWidth, {double? devicePixelRatio}) {
    final dpr =
        devicePixelRatio ??
        PlatformDispatcher.instance.views.first.devicePixelRatio;
    return (layoutWidth * dpr).round().clamp(1, 100000);
  }

  /// Screen-width decode target for detail images.
  static int get screenDecodeWidth {
    final view = PlatformDispatcher.instance.views.first;
    final dpr = view.devicePixelRatio;
    return (view.physicalSize.width / (dpr == 0 ? 1 : dpr) * dpr).round().clamp(
      1,
      100000,
    );
  }

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Alignment alignment;

  /// Loading/error backdrop. When null the widget resolves the ambient
  /// theme's `colorScheme.surfaceContainer` — the same tier the surrounding
  /// card paints, so an empty slot reads as card surface, not a grey hole.
  /// Full-bleed surfaces (the viewer's black stage) pass an explicit color.
  final Color? placeholderColor;

  /// Optional custom placeholder (avatar shimmer etc.). When null the
  /// default [ColoredBox] with [placeholderColor] is used.
  final Widget? placeholderWidget;

  /// When false the image appears instantly instead of crossfading in.
  ///
  /// When true (default) the crossfade applies **only while the image is not
  /// yet completed in the Flutter image cache**: newly loaded artwork
  /// crossfades from the grey placeholder (smooth loading animation), while
  /// an already-decoded image (Hero flight hand-off target, a card scrolled
  /// back in) appears instantly — Glide skips memory-cache hits the same
  /// way.
  final bool fade;

  /// Lays the box out at the decoded image's own aspect ratio, as large as
  /// the constraints allow ([AspectFitBox]), for images whose ratio nothing
  /// knows up front (article images). Off, a bounded max width pins the
  /// box's width — see build.
  final bool sizeToImage;

  /// Stable identity for an image that participates in a Hero hand-off.
  ///
  /// Hero temporarily removes the endpoint child from the tree while it
  /// flies. Keeping a small URL history by this key lets a newly rebuilt
  /// endpoint use the last displayed quality as its placeholder, even when
  /// the image element itself was disposed during the flight.
  /// Ordinary images can leave this null.
  final Object? transitionKey;
  final Color? filterColor;
  final BlendMode? filterBlendMode;

  /// Sampling quality for the decoded image. Image-grid apps commonly
  /// render at `low`/`none`; `medium` costs real raster time per image
  /// during scroll.
  final FilterQuality filterQuality;

  /// Decode-width cap in pixels for this image, or null for unlimited
  /// (viewer). See [PixivImageSize] and R8.
  final int? memCacheWidth;

  /// Per-(work,page) key + the tier [url] represents, enabling
  /// [IllustTierCache] upgrade: when a higher tier of the same page was
  /// already decoded, the higher URL is requested instead so the painted
  /// result never regresses to a blurrier tier.
  final String? tierKey;
  final IllustImageTier? tier;

  /// Whether a cached higher tier may replace [url] (default true). Feed
  /// cards keep this off: they always paint their configured preview tier,
  /// since an upgraded file decodes to the same output size anyway and only
  /// adds file-read cost.
  final bool tierUpgrade;

  /// Receives the download progress of the image this widget resolves, for
  /// an [ImageLoadProgressOverlay] placed outside any Hero. The owner keeps
  /// the notifier at least as long as this widget.
  final ValueNotifier<ImageLoadProgress>? progress;

  @override
  ConsumerState<PixivImage> createState() => _PixivImageState();

  // Keep this bounded: a long feed can create many Hero tags over time.
  // (url, decodeWidth) per transition key — the placeholder for a quality
  // hand-off must decode the previous tier at the SAME width it was decoded
  // before, or it misses the decoded cache entry and shows the flat color
  // box while it re-decodes (the first-open flash after the Hero lands).
  static final LinkedHashMap<Object, List<_HistoryEntry>> _transitionHistory =
      LinkedHashMap<Object, List<_HistoryEntry>>();
  static const _maxTransitionKeys = 256;
  static const _maxUrlsPerKey = 4;

  /// The provider the widget resolves for [url], wrapped the way the
  /// widget wraps it — the same key is the same decoded entry.
  static ImageProvider _imageProvider(
    String url,
    int? decodeWidth, {
    required ImageWorker worker,
    ImageFetchPriority priority = ImageFetchPriority.foreground,
  }) {
    final base = WorkerImageProvider(worker, url, priority: priority);
    return decodeWidth == null
        ? base
        : ResizeImage.resizeIfNeeded(decodeWidth, null, base);
  }

  /// Decode-width-qualified completion log. The visible widget resolves
  /// `ResizeImage(provider, memCacheWidth)`, so checking `statusForKey` on the
  /// raw provider never matched — every capped image reported "not complete"
  /// and crossfaded in from transparent on every first frame (the flash).
  /// We therefore track completion ourselves, keyed by the exact decode
  /// width the widget resolves.
  ///
  /// The log records "decoded at least once" while the real imageCache
  /// evicts on LRU pressure — so it is bounded FIFO and only ever used for
  /// choices whose stale hit is benign (history placeholder, width
  /// promotion). The fade decision cannot trust it: OctoImage's own
  /// `wasSynchronouslyLoaded` is the accurate signal for "decoded now".
  static const _maxCompletedDecodes = 1024;
  static final LinkedHashSet<String> _completedDecodes = LinkedHashSet();

  /// The latest completed decode of each URL, same bound: the one entry a
  /// stand-in for that URL can paint without fetching anything.
  static final LinkedHashMap<String, _HistoryEntry> _lastDecodeOfUrl =
      LinkedHashMap();

  /// Records a decode; false when it was already recorded.
  static bool _markCompleted(_HistoryEntry entry) {
    _lastDecodeOfUrl
      ..remove(entry.$1)
      ..[entry.$1] = entry;
    if (_lastDecodeOfUrl.length > _maxCompletedDecodes) {
      _lastDecodeOfUrl.remove(_lastDecodeOfUrl.keys.first);
    }
    if (!_completedDecodes.add(_decodeKey(entry))) return false;
    if (_completedDecodes.length > _maxCompletedDecodes) {
      _completedDecodes.remove(_completedDecodes.first);
    }
    return true;
  }

  static String _decodeKey(_HistoryEntry entry) =>
      '${entry.$2 ?? 0}|${entry.$1}';

  /// True when [entry]'s decode already completed — meaning the first
  /// frame can render instantly with no crossfade.
  static bool _imageCompleted(_HistoryEntry entry) =>
      _completedDecodes.contains(_decodeKey(entry));

  static _HistoryEntry? _rememberTransitionUrl(
    Object? key,
    _HistoryEntry current,
  ) {
    if (key == null || current.$1.isEmpty) return null;
    final history = _transitionHistory.putIfAbsent(
      key,
      () => <_HistoryEntry>[],
    );
    // The hand-off placeholder must be an entry whose decode actually
    // completed — an aborted tier (user popped mid-load, or a fresh page
    // instance after one) is recorded in history but has no decoded frame,
    // so using it as the placeholder paints the flat colour box. Filtering
    // by _completedDecodes also subsumes the old same-URL early return: a
    // rebuild of the current URL finds no older *decoded* entry and stays a
    // non-transition.
    _HistoryEntry? previous;
    for (final candidate in history.reversed) {
      // URL and decode width together identify the painted cache entry. A
      // detail Hero commonly keeps the same URL but changes from the feed's
      // card width to the screen width; treating that as a no-op loses the
      // old frame and exposes the placeholder during the second decode.
      if (candidate == current) continue;
      if (_imageCompleted(candidate)) {
        previous = candidate;
        break;
      }
    }
    // (url, width) is the decode identity — a rebuild with either changed
    // is a different cache entry and belongs in history.
    if (history.isEmpty || history.last != current) {
      history.add(current);
      if (history.length > _maxUrlsPerKey) {
        history.removeRange(0, history.length - _maxUrlsPerKey);
      }
    }
    while (_transitionHistory.length > _maxTransitionKeys) {
      _transitionHistory.remove(_transitionHistory.keys.first);
    }
    return previous;
  }

  /// Paint the last completed cache entry directly while the next entry is
  /// resolving. This deliberately uses [Image] instead of another
  /// [PixivImage]: nesting the stateful network widget made the placeholder
  /// start a second load and could briefly replace a valid Hero frame with a
  /// flat colour during URL or decode-width changes.
  static Widget _lastDecodedFrame(
    _HistoryEntry entry, {
    required ImageWorker worker,
    required BoxFit fit,
    required double? width,
    required double? height,
    required Alignment alignment,
    required Color? filterColor,
    required BlendMode? filterBlendMode,
    required FilterQuality filterQuality,
  }) {
    // entry.$2 is the exact width the completed decode used; substituting
    // another resolves a key that was never decoded — the "placeholder"
    // then stays empty until that decode finishes.
    final (url, decodeWidth) = entry;
    return Image(
      image: _imageProvider(url, decodeWidth, worker: worker),
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      color: filterColor,
      colorBlendMode: filterBlendMode,
      filterQuality: filterQuality,
      gaplessPlayback: true,
      // Named by the surface around it, as in the loaded path.
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => ColoredBox(
        color: const Color(0x00000000),
        child: SizedBox(width: width, height: height),
      ),
    );
  }

  /// The best image of [tierKey] (an [IllustTierCache] key) that has
  /// already been decoded, at the width it was decoded at: a stand-in that
  /// paints a decode which already happened instead of starting a load.
  /// Null when no tier of it has been decoded.
  static Widget? decodedStandIn(
    BuildContext context,
    String tierKey, {
    BoxFit fit = BoxFit.contain,
  }) {
    final url = IllustTierCache.best(tierKey);
    final entry = url == null ? null : _lastDecodeOfUrl[url];
    if (entry == null) return null;
    return _lastDecodedFrame(
      entry,
      worker: ProviderScope.containerOf(
        context,
        listen: false,
      ).read(imageWorkerProvider),
      fit: fit,
      width: null,
      height: null,
      alignment: Alignment.center,
      filterColor: null,
      filterBlendMode: null,
      filterQuality: FilterQuality.low,
    );
  }

  /// Records a decode on its first frame: OctoImage only builds the image
  /// once a frame exists, so no second listener has to follow the stream.
  /// Later builds of a recorded decode return at the first check.
  static void _recordFrame(
    _HistoryEntry entry,
    String? tierKey,
    IllustImageTier? tier,
  ) {
    if (!_markCompleted(entry)) return;
    FrameProbe.instance.mark('img worker');
    if (tierKey != null && tier != null) {
      IllustTierCache.record(tierKey, tier, entry.$1);
    }
  }

  /// Starts decoding through the same provider/cache identity as [build].
  /// An image error completes the future normally, so callers can start
  /// this without delaying navigation; the visible widget still owns its
  /// placeholder and error state.
  ///
  /// [priority] is background for speculative warm-up. Preloads the user
  /// just asked for (a tapped card's detail image, the viewer page) pass
  /// foreground so they never queue behind other warm-up, and hold the URL
  /// until the target page has had time to mount.
  ///
  /// The warm-up lands on the decoded entry the widget showing the image
  /// resolves. A background preload is only kept while something wants its
  /// URL — a widget showing it or a prefetch window on the worker's demand.
  ///
  /// Completes with the outcome; never with an image error.
  static Future<ImagePreloadResult> preload(
    BuildContext context,
    String url, {
    String? tierKey,
    IllustImageTier? tier,
    int? memCacheWidth,
    ImageFetchPriority priority = ImageFetchPriority.background,
  }) async {
    final resolved = tierKey != null && tier != null
        ? IllustTierCache.resolve(tierKey, tier, url)
        : (url, tier);
    final worker = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(imageWorkerProvider);
    if (priority == ImageFetchPriority.foreground) {
      worker.demand.holdFor(resolved.$1, _userPreloadHold);
    }
    // The visible widget's ResizeImage wrapping, so the warmed entry is the
    // exact cache key it resolves — a different decode width is a different
    // decoded entry and the hand-off still shows a placeholder.
    final imageProvider = _imageProvider(
      resolved.$1,
      memCacheWidth,
      worker: worker,
      priority: priority,
    );
    ImagePreloadResult? failure;
    await precacheImage(
      imageProvider,
      context,
      // Without onError a failed warm-up is reported through
      // FlutterError.onError and lands in the crash log. The visible widget
      // shows (and retries) its own failure; here it is only noise.
      onError: (error, _) {
        // A dropped fetch is the scheduler working as intended.
        if (error is ImageFetchDropped) {
          failure = ImagePreloadResult.dropped;
          return;
        }
        failure = ImagePreloadResult.failed;
        debugPrint('PixivImage.preload ${resolved.$1}: $error');
      },
    );
    // A failed image must not be recorded as decoded: the tier cache would
    // then upgrade later requests to a URL that never loaded.
    if (failure case final failure?) return failure;
    FrameProbe.instance.mark('img preload');
    _markCompleted((resolved.$1, memCacheWidth));
    if (tierKey != null && resolved.$2 != null) {
      IllustTierCache.record(tierKey, resolved.$2!, resolved.$1);
    }
    return ImagePreloadResult.decoded;
  }

  /// How long a user-requested preload stays wanted without a widget; the
  /// target page normally mounts and takes over well within it.
  static const _userPreloadHold = Duration(seconds: 10);
}

class _PixivImageState extends ConsumerState<PixivImage> with TickerModeWatch {
  /// The decode the last build would fade in as a cold load; null when
  /// that build ruled the fade out for another reason.
  _HistoryEntry? _coldLoad;

  /// A ticker-mode flip only changes the output of a cold load still in
  /// flight: a decoded image paints synchronously and never fades.
  @override
  void didChangeTickerMode(bool enabled) {
    final coldLoad = _coldLoad;
    if (coldLoad == null || PixivImage._imageCompleted(coldLoad)) return;
    setState(() {});
  }

  /// The URL this element was asked to paint last build. Feed lists
  /// recycle card elements by index, so a pull-to-refresh can land a
  /// *different work* on the same element: `url` changes while the element
  /// — and OctoImage's retained old frame — stays. That is a slot
  /// hand-off, not a cold load.
  String? _lastShownUrl;

  /// The URL this element registered in [_demand], so a queued fetch for
  /// it is not dropped while it is on screen.
  String? _heldUrl;
  ImageDemand? _demand;

  /// Holds the new URL before releasing the old one, so a rebuild with the
  /// same URL never drops to zero holders.
  void _hold(ImageDemand demand, String url) {
    if (identical(demand, _demand) && url == _heldUrl) return;
    demand.hold(url);
    _release();
    _demand = demand;
    _heldUrl = url;
  }

  void _release() {
    final url = _heldUrl;
    if (url != null) _demand?.release(url);
    _heldUrl = null;
  }

  /// Waits before each automatic retry of a transient failure.
  static const _retryBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
  ];

  /// HTTP statuses that a retry cannot fix.
  static const _permanentStatuses = {403, 404, 410};

  /// Smallest image box that shows a manual retry button; smaller slots
  /// (avatars, chips) keep the broken-image icon.
  static const _retryButtonMinSize = 48.0;

  /// Automatic retries used for the current URL.
  int _attempt = 0;

  /// Key of the network image; each bump is a fresh resolve.
  int _load = 0;
  Timer? _retryTimer;
  var _retryScheduled = false;

  void _resetRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryScheduled = false;
    _attempt = 0;
  }

  @override
  void didUpdateWidget(covariant PixivImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _resetRetry();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _detachProgress();
    _release();
    super.dispose();
  }

  /// What [_trackProgress] last attached for: notifier, decode, worker and
  /// load generation.
  Object? _progressKey;
  ValueNotifier<ImageLoadProgress>? _progressNotifier;
  ImageStream? _progressStream;
  ImageStreamListener? _progressListener;

  /// Ends the worker progress subscription.
  void Function()? _unwatchProgress;

  /// Follows the stream the visible image resolves — the same key, so no
  /// second decode. Attaches after the frame: a cache hit reports at once,
  /// and notifying the overlay (a sibling) mid-build is not allowed.
  void _trackProgress(_HistoryEntry entry, ImageWorker worker) {
    final notifier = widget.progress;
    final key = (notifier, entry, worker, _load);
    if (key == _progressKey) return;
    _progressKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _progressKey != key) return;
      // The old stream's last report must not linger on the new image.
      _progressNotifier?.value = const ImageLoadProgress.idle();
      _detachProgress();
      if (notifier != null) _attachProgress(notifier, entry, worker);
    });
  }

  /// Loading starts with the first bytes, not with the request: a fetch
  /// still connecting or queued reports nothing. The worker reports bytes
  /// by URL to whoever watches it, so a ring attached to a decode another
  /// caller started still sees them; the stream only says when it is done.
  void _attachProgress(
    ValueNotifier<ImageLoadProgress> notifier,
    _HistoryEntry entry,
    ImageWorker worker,
  ) {
    final (url, decodeWidth) = entry;
    final stream = PixivImage._imageProvider(
      url,
      decodeWidth,
      worker: worker,
    ).resolve(ImageConfiguration.empty);
    void idle() => notifier.value = const ImageLoadProgress.idle();
    final listener = ImageStreamListener(
      (_, _) => idle(),
      onError: (_, _) => idle(),
    );
    stream.addListener(listener);
    _unwatchProgress = worker.watchProgress(
      url,
      (received, total) =>
          notifier.value = ImageLoadProgress.ofBytes(received, total),
    );
    _progressNotifier = notifier;
    _progressStream = stream;
    _progressListener = listener;
  }

  void _detachProgress() {
    final listener = _progressListener;
    if (listener != null) _progressStream?.removeListener(listener);
    _unwatchProgress?.call();
    _unwatchProgress = null;
    _progressNotifier = null;
    _progressStream = null;
    _progressListener = null;
  }

  /// A transient failure retries on its own up to [_retryBackoff].length
  /// times; a permanent or exhausted one offers a manual retry when the box
  /// is large enough for a button.
  Widget _errorView(Object error, _HistoryEntry entry, ImageWorker worker) {
    const broken = Icon(Icons.broken_image);
    final status = error is FetchFailure ? error.statusCode : null;
    final permanent = _permanentStatuses.contains(status);
    if (!permanent && _attempt < _retryBackoff.length) {
      if (!_retryScheduled) {
        _retryScheduled = true;
        final delay = _retryBackoff[_attempt];
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // A URL change in the meantime reset the schedule.
          if (!mounted || !_retryScheduled) return;
          _retryTimer = Timer(delay, () {
            _retryTimer = null;
            _reload(entry, worker, automatic: true);
          });
        });
      }
      return broken;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _retryButtonMinSize ||
            constraints.maxHeight < _retryButtonMinSize) {
          return broken;
        }
        return Center(
          child: IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: Localizations.of<AppLocalizations>(
              context,
              AppLocalizations,
            )?.imageRetry,
            onPressed: () => _reload(entry, worker, automatic: false),
          ),
        );
      },
    );
  }

  /// Drops the failed entry from the image cache — the same
  /// `ResizeImage`-wrapped key the visible widget resolves, which the
  /// loader's own eviction does not reach — then resolves again.
  void _reload(
    _HistoryEntry entry,
    ImageWorker worker, {
    required bool automatic,
  }) {
    final (url, decodeWidth) = entry;
    final provider = PixivImage._imageProvider(
      url,
      decodeWidth,
      worker: worker,
    );
    unawaited(
      provider.evict().then((_) {
        if (!mounted) return;
        setState(() {
          _attempt = automatic ? _attempt + 1 : 0;
          _retryScheduled = false;
          _load++;
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    var imageUrl = widget.url;
    var effectiveTier = widget.tier;
    if (widget.tierKey != null && widget.tier != null && widget.tierUpgrade) {
      // Serve the best cached tier for this page: a request for medium after
      // large already decoded paints large instead of re-fetching (and
      // briefly flashing) the blurrier URL.
      (imageUrl, effectiveTier) = IllustTierCache.resolve(
        widget.tierKey!,
        widget.tier!,
        widget.url,
      );
    }
    final worker = ref.watch(imageWorkerProvider);
    _HistoryEntry entryAt(int? width) => (imageUrl, width);
    // A URL's only decoded entry can be the viewer's uncapped frame (the
    // viewer decodes without a memCacheWidth cap). Requesting a fresh
    // capped decode of it leaves a placeholder/swap window — the flash
    // when a detail page re-lands after the viewer fetched the original.
    // The uncapped entry is decoded and strictly sharper than the
    // requested width, so paint it directly.
    var current = entryAt(widget.memCacheWidth);
    if (current.$2 != null &&
        !PixivImage._imageCompleted(current) &&
        PixivImage._imageCompleted(entryAt(null))) {
      current = entryAt(null);
    }
    final (_, effectiveWidth) = current;
    _hold(worker.demand, imageUrl);
    _trackProgress(current, worker);
    final previousTransition = PixivImage._rememberTransitionUrl(
      widget.transitionKey,
      current,
    );
    // Progressive underlay (3a): when no transition history exists — e.g.
    // swiping to a viewer page that never had a Hero — a lower tier of the
    // same page already decoded in the cache paints under the resolving
    // higher tier. Zero traffic: it paints a decode that already happened.
    final underlayUrl =
        previousTransition == null &&
            widget.tierKey != null &&
            effectiveTier != null &&
            !PixivImage._imageCompleted(current)
        ? IllustTierCache.bestBelow(widget.tierKey!, effectiveTier)
        : null;
    // The tier record does not say which width decoded it; paint the
    // decode that actually happened — anything else would fetch.
    final underlayEntry = underlayUrl == null
        ? null
        : PixivImage._lastDecodeOfUrl[underlayUrl];
    // A completed current frame resolves synchronously and never reaches the
    // placeholder at all — so whenever a decoded-once previous entry exists,
    // it is always the better stand-in while the next tier resolves. Only
    // the absence of history falls back to the flat colour box.
    final transitionPlaceholder =
        previousTransition == null && underlayEntry == null
        ? widget.placeholderWidget
        : PixivImage._lastDecodedFrame(
            previousTransition ?? underlayEntry!,
            worker: worker,
            fit: widget.fit,
            width: widget.width,
            height: widget.height,
            alignment: widget.alignment,
            filterColor: widget.filterColor,
            filterBlendMode: widget.filterBlendMode,
            filterQuality: widget.filterQuality,
          );
    // A tier/width hand-off swaps onto an already-decoded frame. Fading the
    // new frame in leaves a half-transparent composite over the dissolving
    // old frame and the page background — the "contrast dip" flash.
    // Glide replaces the drawable instantly in that case; the crossfade
    // is only for a real cold load (placeholder colour → image). OctoImage
    // separately skips fades entirely when the first frame is synchronous
    // (wasSynchronouslyLoaded).
    //
    // A slot hand-off is the same story one level down: this element was
    // already committed to a different URL (a recycled feed slot now
    // showing a different work, or a quality swap on the same slot).
    // OctoImage retains whatever old frame exists via gapless playback, so
    // the replacement must be instant — fading work B in over retained
    // work A reads as a cross-work dissolve on every refreshed slot. Glide
    // behaves identically: a URL change on a live target never plays the
    // load transition.
    final slotHandoff = _lastShownUrl != null && _lastShownUrl != imageUrl;
    // Frozen tickers (a route transition owns the budget) must not arm a
    // fade: the outgoing snapshot would bake a half-transparent frame and
    // the fade resuming after landing reads as the image reloading. Read
    // without a dependency; [didChangeTickerMode] rebuilds the cold loads
    // the flip affects.
    _coldLoad =
        widget.fade &&
            previousTransition == null &&
            underlayEntry == null &&
            !slotHandoff
        ? current
        : null;
    final crossfade = _coldLoad != null && tickersEnabled;
    _lastShownUrl = imageUrl;
    final placeholderColor =
        widget.placeholderColor ??
        Theme.of(context).colorScheme.surfaceContainer;
    // OctoImage stacks the placeholder over the image. Glide keeps the
    // placeholder under an image fading in; over an opaque image, the image
    // painted at once beneath a placeholder dissolving off it is the same
    // composite. Fading both layers at once let the page show through the
    // middle of the fade — the grey dip, held for a second.
    final fadeOutDuration = crossfade
        ? MotionTokens.resolve(context, MotionTokens.imageFade)
        : Duration.zero;
    Widget placeholder(BuildContext _) =>
        transitionPlaceholder ?? ColoredBox(color: placeholderColor);
    Widget failed(Object error) => ColoredBox(
      color: placeholderColor,
      child: _errorView(error, current, worker),
    );
    final image = LayoutBuilder(
      builder: (context, constraints) {
        // Under loose constraints (the detail page's unbounded-height
        // Stack) an image without an explicit width sizes itself to the
        // decoded pixel count — a hero hand-off decoded at the card's
        // width lands as a small box with blank space beside it until the
        // detail-tier decode "suddenly" re-sizes it. Pinning the box to
        // the bounded max width makes every decode tier fill the slot;
        // aspect ratio still sets the height from whatever decoded first.
        final width =
            widget.width ??
            (constraints.hasBoundedWidth && !widget.sizeToImage
                ? constraints.maxWidth
                : null);
        return OctoImage(
          // A new key is a fresh resolve: how a retry reloads.
          key: ValueKey(_load),
          image: PixivImage._imageProvider(
            imageUrl,
            effectiveWidth,
            worker: worker,
          ),
          imageBuilder: (_, child) {
            PixivImage._recordFrame(current, widget.tierKey, effectiveTier);
            // The pixels carry no meaning of their own: the surface around
            // them names the work (the card, the viewer page). Left in, the
            // decoded image added an unnamed "image" stop for screen
            // readers (H2). The failure view, with its retry, stays.
            return ExcludeSemantics(
              child: widget.sizeToImage ? AspectFitBox(child: child) : child,
            );
          },
          placeholderBuilder: placeholder,
          errorBuilder: (_, error, _) => failed(error),
          // Keeps the last frame while a different URL or tier resolves: a
          // hand-off never flashes the placeholder.
          gaplessPlayback: true,
          width: width,
          height: widget.height,
          fit: widget.fit,
          alignment: widget.alignment,
          color: widget.filterColor,
          colorBlendMode: widget.filterBlendMode,
          filterQuality: widget.filterQuality,
          fadeInDuration: Duration.zero,
          fadeOutDuration: fadeOutDuration,
          fadeOutCurve: MotionTokens.imageFadeCurve,
        );
      },
    );
    // A running fade/loader repaint otherwise propagates to the nearest
    // ancestor boundary — usually the whole scroll viewport — and
    // re-records every visible image on each tick. Keep the blast radius
    // at this image.
    return RepaintBoundary(child: image);
  }
}

/// Sizes its child to the largest box within the constraints that keeps
/// the child's natural aspect ratio, scaling up as well as down: what
/// [BoxFit.contain] does to an image's pixels, done to its layout box. A
/// decoded image alone only ever shrinks to fit, so an image with fewer
/// pixels than the column stayed small, and one pinned to the column width
/// under a height cap left bars beside it.
///
/// The natural size is the child's dry layout under unbounded constraints
/// (an image's pixel size); the child must support dry layout.
class AspectFitBox extends SingleChildRenderObjectWidget {
  const AspectFitBox({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAspectFitBox();
}

class _RenderAspectFitBox extends RenderProxyBox {
  Size _fit(BoxConstraints constraints) {
    final natural = child?.getDryLayout(const BoxConstraints());
    if (natural == null || natural.isEmpty) return constraints.smallest;
    final scale = math.min(
      constraints.maxWidth / natural.width,
      constraints.maxHeight / natural.height,
    );
    return constraints.constrain(scale.isFinite ? natural * scale : natural);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _fit(constraints);

  @override
  void performLayout() {
    size = _fit(constraints);
    child?.layout(BoxConstraints.tight(size));
  }
}
