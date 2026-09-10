import 'dart:collection';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'motion/motion_tokens.dart';
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
class PixivImage extends ConsumerWidget {
  const PixivImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.alignment = Alignment.center,
    this.placeholderColor = const Color(0x33343838),
    this.placeholderWidget,
    this.fade = true,
    this.transitionKey,
    this.filterColor,
    this.filterBlendMode,
    this.memCacheWidth,
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
    Color placeholderColor = const Color(0x33343838),
    Widget? placeholderWidget,
    Object? transitionKey,
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
  }) : this(
         key: key,
         url: url,
         fit: fit,
         alignment: alignment,
         filterColor: filterColor,
         filterBlendMode: filterBlendMode,
         transitionKey: transitionKey,
         memCacheWidth: _screenDecodeWidth,
       );

  /// Hero hand-off variant: keeps the transition history keyed by [tag] so a
  /// rebuilt endpoint reuses the last displayed quality as its placeholder.
  const PixivImage.hero(
    String url, {
    Key? key,
    required Object? tag,
    BoxFit fit = BoxFit.cover,
    Alignment alignment = Alignment.center,
    Color placeholderColor = const Color(0x33343838),
  }) : this(
         key: key,
         url: url,
         fit: fit,
         alignment: alignment,
         placeholderColor: placeholderColor,
         transitionKey: tag,
       );

  /// Decode width for a logical [layoutWidth] box: layout width x DPR,
  /// capped at 1.5x logical pixels (R8: never decode more than that for
  /// feed/avatar art). [devicePixelRatio] overrides the platform view's DPR
  /// (tests).
  static int decodeWidthFor(double layoutWidth, {double? devicePixelRatio}) {
    final dpr =
        devicePixelRatio ??
        PlatformDispatcher.instance.views.first.devicePixelRatio;
    final physical = layoutWidth * dpr;
    final cap = layoutWidth * 1.5;
    return (physical < cap ? physical : cap).round().clamp(1, 100000);
  }

  /// Screen-width decode target for detail images.
  static int get _screenDecodeWidth {
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

  /// Decode-width cap in pixels for this image, or null for unlimited
  /// (viewer). See [PixivImageSize] and R8.
  final int? memCacheWidth;

  // Keep this bounded: a long feed can create many Hero tags over time.
  static final LinkedHashMap<Object, List<String>> _transitionHistory =
      LinkedHashMap<Object, List<String>>();
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

  /// True when the byte stream for [url] has already completed in the
  /// Flutter image cache (the same provider identity [build]/[preload]
  /// share). Pending or never-seen images keep the crossfade.
  static bool _imageCompleted(String url, BaseCacheManager? cacheManager) {
    try {
      final status = PaintingBinding.instance.imageCache.statusForKey(
        provider(url, cacheManager: cacheManager),
      );
      return !status.pending && (status.keepAlive || status.live);
    } on Object {
      return false;
    }
  }

  static String? _rememberTransitionUrl(Object? key, String imageUrl) {
    if (key == null || imageUrl.isEmpty) return null;
    final history = _transitionHistory.putIfAbsent(key, () => <String>[]);
    // A rebuild with the same URL is not a quality hand-off. Returning an
    // older URL in that case makes CachedNetworkImage briefly rebuild its
    // placeholder on every provider/state notification (most visible after a
    // detail pop), which is the white flash reported on device.
    if (history.isNotEmpty && history.last == imageUrl) return null;
    String? previous;
    for (final candidate in history.reversed) {
      if (candidate != imageUrl) {
        previous = candidate;
        break;
      }
    }
    if (history.isEmpty || history.last != imageUrl) {
      history.add(imageUrl);
      if (history.length > _maxUrlsPerKey) {
        history.removeRange(0, history.length - _maxUrlsPerKey);
      }
    }
    while (_transitionHistory.length > _maxTransitionKeys) {
      _transitionHistory.remove(_transitionHistory.keys.first);
    }
    return previous;
  }

  /// Starts decoding through the same provider/cache identity as [build].
  /// [precacheImage] completes normally on image errors, so callers can start
  /// this without delaying navigation; the visible widget still owns its
  /// placeholder and error state.
  static Future<void> preload(
    BuildContext context,
    String url, {
    BaseCacheManager? cacheManager,
  }) => precacheImage(provider(url, cacheManager: cacheManager), context);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // PixivImage is also used by the standalone viewer tests and by embedders
    // that do not install Riverpod. Keep the original URL in that context;
    // the application shell always provides the settings scope.
    final imageUrl = url;
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
    final imageCompleted = _imageCompleted(imageUrl, cacheManager);
    final previousTransitionUrl = _rememberTransitionUrl(
      transitionKey,
      imageUrl,
    );
    final isUrlTransition = previousTransitionUrl != null;
    final transitionPlaceholder = !isUrlTransition || imageCompleted
        ? placeholderWidget
        : PixivImage(
            // Do not register the fallback again. It is only the last frame
            // shown while the new quality URL resolves.
            url: previousTransitionUrl,
            fit: fit,
            width: width,
            height: height,
            alignment: alignment,
            placeholderColor: placeholderColor,
            fade: false,
            filterColor: filterColor,
            filterBlendMode: filterBlendMode,
          );
    final image = CachedNetworkImage(
      imageUrl: imageUrl,
      httpHeaders: headers,
      cacheManager: cacheManager,
      // Keep the last decoded frame as the placeholder while a different
      // quality tier is resolving.  This is the important distinction
      // between a cold load (where the loading fade is useful) and a URL
      // hand-off (where replacing the frame with a placeholder produces a
      // white/grey flash).  CachedNetworkImage delegates this to OctoImage's
      // gapless playback and applies it consistently to every caller:
      // cards, detail pages, multi-page items, GIF covers and the viewer.
      useOldImageOnUrlChange: true,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      memCacheWidth: memCacheWidth,
      color: filterColor,
      colorBlendMode: filterBlendMode,
      // Crossfade only for artwork that has not completed decoding yet:
      // already-cached images (Hero hand-off targets, preloaded URLs) must
      // appear instantly — a translucent fade over the page background is
      // the white flash.
      fadeInDuration: fade && !imageCompleted && !isUrlTransition
          ? MotionTokens.imageFade
          : Duration.zero,
      // Gapless playback already keeps the previous decoded frame visible
      // while a new quality URL is pending. Never fade that frame out: a
      // translucent placeholder between medium/large/original (including
      // multi-page and GIF covers) is perceived as a white flash.
      fadeOutDuration: Duration.zero,
      placeholder: (_, _) =>
          transitionPlaceholder ?? ColoredBox(color: placeholderColor),
      errorWidget: (_, _, _) => ColoredBox(
        color: placeholderColor,
        child: const Icon(Icons.broken_image),
      ),
    );
    return image;
  }
}
