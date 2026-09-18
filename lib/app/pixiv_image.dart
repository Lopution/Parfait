import 'dart:collection';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'motion/motion_tokens.dart';
import 'image_tier_cache.dart';
import '../core/entity/illust_entity.dart';
import '../core/network/pixiv_headers.dart';
import '../core/network/compat/network_providers.dart';

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

/// Shared Pixiv CDN image widget: every i.pximg.net request must carry the
/// app-API Referer or the CDN answers 403 (beta56 PixivImage semantics).
typedef _HistoryEntry = (String url, int? decodeWidth);

class PixivImage extends ConsumerStatefulWidget {
  const PixivImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.alignment = Alignment.center,
    this.placeholderColor = const Color(0x33383838),
    this.placeholderWidget,
    this.fade = true,
    this.fadeDuration = MotionTokens.imageFade,
    this.transitionKey,
    this.filterColor,
    this.filterBlendMode,
    this.memCacheWidth,
    this.filterQuality = FilterQuality.low,
    this.tierKey,
    this.tier,
    this.tierUpgrade = true,
  });

  /// Feed/row card variant: decode width derives from [layoutWidth] (the
  /// box the image paints into), capped at 1.5x logical pixels.
  PixivImage.feed(
    String url, {
    Key? key,
    required double layoutWidth,
    BoxFit fit = BoxFit.cover,
    double? width,
    double? height,
    Color placeholderColor = const Color(0x33383838),
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
         width: width,
         height: height,
         placeholderColor: placeholderColor,
         placeholderWidget: placeholderWidget,
         transitionKey: transitionKey,
         memCacheWidth: decodeWidthFor(layoutWidth),
         tierKey: tierKey,
         tier: tier,
         tierUpgrade: tierUpgrade,
         // Feed cards keep a short load transition even during a fling. The
         // completion log below still skips it for decoded cache entries,
         // while newly revealed cards retain the requested visual continuity.
         fadeDuration: MotionTokens.imageFadeFeed,
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
       );

  /// Hero hand-off variant: keeps the transition history keyed by [tag] so a
  /// rebuilt endpoint reuses the last displayed quality as its placeholder.
  PixivImage.hero(
    String url, {
    Key? key,
    required Object? tag,
    BoxFit fit = BoxFit.cover,
    Alignment alignment = Alignment.center,
    Color placeholderColor = const Color(0x33383838),
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

  /// Decode width for a logical [layoutWidth] box: layout width x DPR,
  /// capped at 1.5x the *physical* display size (R8). The cap must be in
  /// physical pixels too — capping `layoutWidth * dpr` by `layoutWidth * 1.5`
  /// decoded high-DPR devices at half resolution, which read as blurry,
  /// aliased thumbnails.
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
  final Color placeholderColor;

  /// Optional custom placeholder (avatar shimmer etc.). When null the
  /// default [ColoredBox] with [placeholderColor] is used.
  final Widget? placeholderWidget;

  /// When false the image appears instantly instead of crossfading in.
  ///
  /// When true (default) the crossfade applies **only while the image is not
  /// yet completed in the Flutter image cache**: newly loaded artwork
  /// crossfades from the grey placeholder (smooth loading animation), while
  /// an already-decoded image (Hero flight hand-off target) appears
  /// instantly — never a translucent frame over the page background.
  final bool fade;

  /// Duration of the cold-load fade. Feed cards use a shorter duration than
  /// detail artwork so a settled grid gets a visible transition without
  /// leaving a long trail of animated placeholders behind a scroll.
  final Duration fadeDuration;

  /// Stable identity for an image that participates in a Hero hand-off.
  ///
  /// Hero temporarily removes the endpoint child from the tree while it
  /// flies. Keeping a small URL history by this key lets a newly rebuilt
  /// endpoint use the last displayed quality as its placeholder, even when
  /// the `CachedNetworkImage` element itself was disposed during the flight.
  /// Ordinary images can leave this null.
  final Object? transitionKey;
  final Color? filterColor;
  final BlendMode? filterBlendMode;

  /// Sampling quality for the decoded image. `low` matches the
  /// CachedNetworkImage default and every comparable client (pixez,
  /// immich render grids at `low`/`none`); `medium` costs real raster time
  /// per image during scroll.
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

  static Map<String, String> get headers => PixivHeaders.image();

  static CachedNetworkImageProvider provider(
    String url, {
    BaseCacheManager? cacheManager,
  }) => CachedNetworkImageProvider(
    url,
    headers: headers,
    cacheManager: cacheManager,
  );

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

  static void _markCompleted(String decodeKey) {
    _completedDecodes.add(decodeKey);
    if (_completedDecodes.length > _maxCompletedDecodes) {
      _completedDecodes.remove(_completedDecodes.first);
    }
  }

  static String _decodeKey(String url, int? memCacheWidth) =>
      '${memCacheWidth ?? 0}|$url';

  /// True when the [memCacheWidth]-capped decode for [url] already completed
  /// — meaning the first frame can render instantly with no crossfade.
  static bool _imageCompleted(String url, int? memCacheWidth) =>
      _completedDecodes.contains(_decodeKey(url, memCacheWidth));

  static (String, int?)? _rememberTransitionUrl(
    Object? key,
    String imageUrl,
    int? memCacheWidth,
  ) {
    if (key == null || imageUrl.isEmpty) return null;
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
      if (candidate.$1 == imageUrl && candidate.$2 == memCacheWidth) continue;
      if (_completedDecodes.contains(_decodeKey(candidate.$1, candidate.$2))) {
        previous = candidate;
        break;
      }
    }
    // (url, width) is the decode identity — a rebuild at a different width
    // is a different cache entry and belongs in history.
    if (history.isEmpty ||
        history.last.$1 != imageUrl ||
        history.last.$2 != memCacheWidth) {
      history.add((imageUrl, memCacheWidth));
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
    required BaseCacheManager? cacheManager,
    required BoxFit fit,
    required double? width,
    required double? height,
    required Alignment alignment,
    required Color? filterColor,
    required BlendMode? filterBlendMode,
    required FilterQuality filterQuality,
  }) {
    ImageProvider imageProvider = provider(
      entry.$1,
      cacheManager: cacheManager,
    );
    // entry.$2 is the exact width the completed decode used; null means the
    // uncapped provider itself. Substituting any other width wraps the
    // provider in a ResizeImage key that was never decoded — the
    // "placeholder" then resolves empty until that decode finishes.
    final decodeWidth = entry.$2;
    if (decodeWidth != null) {
      imageProvider = ResizeImage.resizeIfNeeded(
        decodeWidth,
        null,
        imageProvider,
      );
    }
    return Image(
      image: imageProvider,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      color: filterColor,
      colorBlendMode: filterBlendMode,
      filterQuality: filterQuality,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => ColoredBox(
        color: const Color(0x00000000),
        child: SizedBox(width: width, height: height),
      ),
    );
  }

  // Pending decode listeners so one URL accumulates at most one listener
  // across rebuilds; entries are removed once the stream resolves.
  static final Set<String> _pendingTierRecords = <String>{};

  /// Records (key,tier,url) once the byte stream actually resolves — the
  /// point where the image is guaranteed to be in the cache. Upgrades then
  /// serve it for later lower-tier requests of the same page.
  static void _recordWhenDecoded(
    String url,
    String? tierKey,
    IllustImageTier? tier,
    BaseCacheManager? cacheManager,
    int? memCacheWidth,
  ) {
    final decodeKey = _decodeKey(url, memCacheWidth);
    if (_completedDecodes.contains(decodeKey)) return;
    // A recorded tier implies the decode already finished — fold it into the
    // completion log and keep builds cheap during scroll.
    if (tierKey != null &&
        tier != null &&
        IllustTierCache.isRecorded(tierKey, tier, url)) {
      _markCompleted(decodeKey);
      return;
    }
    final pending = '$decodeKey|${tierKey ?? ''}';
    if (!_pendingTierRecords.add(pending)) return;
    ImageProvider imageProvider = provider(url, cacheManager: cacheManager);
    // Attach to the SAME stream the visible widget resolves — the
    // ResizeImage-wrapped key — so recording shares the pending decode
    // instead of triggering a second, full-size decode per image.
    if (memCacheWidth != null) {
      imageProvider = ResizeImage.resizeIfNeeded(
        memCacheWidth,
        null,
        imageProvider,
      );
    }
    final stream = imageProvider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    void done() {
      stream.removeListener(listener);
      _pendingTierRecords.remove(pending);
    }

    listener = ImageStreamListener((_, _) {
      _markCompleted(decodeKey);
      if (tierKey != null && tier != null) {
        IllustTierCache.record(tierKey, tier, url);
      }
      done();
    }, onError: (_, _) => done());
    stream.addListener(listener);
  }

  /// Starts decoding through the same provider/cache identity as [build].
  /// [precacheImage] completes normally on image errors, so callers can start
  /// this without delaying navigation; the visible widget still owns its
  /// placeholder and error state.
  static Future<void> preload(
    BuildContext context,
    String url, {
    BaseCacheManager? cacheManager,
    String? tierKey,
    IllustImageTier? tier,
    int? memCacheWidth,
  }) async {
    final resolved = tierKey != null && tier != null
        ? IllustTierCache.resolve(tierKey, tier, url)
        : (url, tier);
    ImageProvider imageProvider = provider(
      resolved.$1,
      cacheManager: cacheManager,
    );
    // Match OctoImage's ResizeImage.wrap so the warmed entry is the exact
    // cache key the visible widget resolves — a different decode width is a
    // different decoded entry and the hand-off still shows a placeholder.
    if (memCacheWidth != null) {
      imageProvider = ResizeImage.resizeIfNeeded(
        memCacheWidth,
        null,
        imageProvider,
      );
    }
    await precacheImage(imageProvider, context);
    _markCompleted(_decodeKey(resolved.$1, memCacheWidth));
    if (tierKey != null && resolved.$2 != null) {
      IllustTierCache.record(tierKey, resolved.$2!, resolved.$1);
    }
  }
}

class _PixivImageState extends ConsumerState<PixivImage> {
  /// The URL this element was asked to paint last build. Feed lists
  /// recycle card elements by index, so a pull-to-refresh can land a
  /// *different work* on the same element: `url` changes while the element
  /// — and OctoImage's retained old frame — stays. That is a slot
  /// hand-off, not a cold load.
  String? _lastShownUrl;

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    // PixivImage is also used by the standalone viewer tests and by embedders
    // that do not install Riverpod. Keep the original URL in that context;
    // the application shell always provides the settings scope.
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
    // A URL's only decoded entry can be the viewer's uncapped frame (the
    // viewer decodes without a memCacheWidth cap). Requesting a fresh
    // capped decode of it leaves a placeholder/swap window — the flash
    // when a detail page re-lands after the viewer fetched the original.
    // The uncapped entry is decoded and strictly sharper than the
    // requested width, so paint it directly.
    var effectiveWidth = widget.memCacheWidth;
    if (effectiveWidth != null &&
        !PixivImage._imageCompleted(imageUrl, effectiveWidth) &&
        PixivImage._imageCompleted(imageUrl, null)) {
      effectiveWidth = null;
    }
    BaseCacheManager? cacheManager;
    var hasProviderScope = true;
    try {
      ProviderScope.containerOf(context, listen: false);
    } on StateError {
      hasProviderScope = false;
    }
    if (hasProviderScope) {
      cacheManager = ref.watch(pixivNetworkFactoryProvider).imageCacheManager;
    }
    PixivImage._recordWhenDecoded(
      imageUrl,
      widget.tierKey,
      effectiveTier,
      cacheManager,
      effectiveWidth,
    );
    final previousTransition = PixivImage._rememberTransitionUrl(
      widget.transitionKey,
      imageUrl,
      effectiveWidth,
    );
    // A completed current frame resolves synchronously and never reaches the
    // placeholder at all — so whenever a decoded-once previous entry exists,
    // it is always the better stand-in while the next tier resolves. Only
    // the absence of history falls back to the flat colour box.
    final transitionPlaceholder = previousTransition == null
        ? widget.placeholderWidget
        : PixivImage._lastDecodedFrame(
            previousTransition,
            cacheManager: cacheManager,
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
    // Glide/PixEz replace the drawable instantly in that case; the crossfade
    // is only for a real cold load (placeholder colour → image). OctoImage
    // separately skips fades entirely when the first frame is synchronous
    // (wasSynchronouslyLoaded).
    //
    // A slot hand-off is the same story one level down: this element was
    // already committed to a different URL (a recycled feed slot now
    // showing a different work, or a quality swap on the same slot).
    // OctoImage retains whatever old frame exists via
    // useOldImageOnUrlChange, so the replacement must be instant — fading
    // work B in over retained work A reads as a cross-work dissolve on
    // every refreshed slot. Glide behaves identically: a URL change on a
    // live target never plays the load transition.
    final slotHandoff = _lastShownUrl != null && _lastShownUrl != imageUrl;
    final crossfade = widget.fade && previousTransition == null && !slotHandoff;
    _lastShownUrl = imageUrl;
    final image = LayoutBuilder(
      builder: (context, constraints) => CachedNetworkImage(
        imageUrl: imageUrl,
        httpHeaders: PixivImage.headers,
        cacheManager: cacheManager,
        // Keep the last decoded frame as the placeholder while a different
        // quality tier is resolving.  This is the important distinction
        // between a cold load (where the loading fade is useful) and a URL
        // hand-off (where replacing the frame with a placeholder produces a
        // white/grey flash).  CachedNetworkImage delegates this to OctoImage's
        // gapless playback and applies it consistently to every caller:
        // cards, detail pages, multi-page items, GIF covers and the viewer.
        useOldImageOnUrlChange: true,
        // Under loose constraints (the detail page's unbounded-height
        // Stack) an image without an explicit width sizes itself to the
        // decoded pixel count — a hero hand-off decoded at the card's
        // width lands as a small box with blank space beside it until the
        // detail-tier decode "suddenly" re-sizes it. Pinning the box to
        // the bounded max width makes every decode tier fill the slot;
        // aspect ratio still sets the height from whatever decoded first.
        width:
            widget.width ??
            (constraints.hasBoundedWidth ? constraints.maxWidth : null),
        height: widget.height,
        fit: widget.fit,
        alignment: widget.alignment,
        memCacheWidth: effectiveWidth,
        color: widget.filterColor,
        colorBlendMode: widget.filterBlendMode,
        filterQuality: widget.filterQuality,
        fadeInDuration: crossfade ? widget.fadeDuration : Duration.zero,
        fadeOutDuration: crossfade ? MotionTokens.imageFadeOut : Duration.zero,
        placeholder: (_, _) =>
            transitionPlaceholder ?? ColoredBox(color: widget.placeholderColor),
        errorWidget: (_, _, _) => ColoredBox(
          color: widget.placeholderColor,
          child: const Icon(Icons.broken_image),
        ),
      ),
    );
    // A running fade/loader repaint otherwise propagates to the nearest
    // ancestor boundary — usually the whole scroll viewport — and
    // re-records every visible image on each tick. Keep the blast radius
    // at this image.
    return RepaintBoundary(child: image);
  }
}
