import 'dart:collection';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../core/network/pixiv_client_identity.dart';
import '../core/network/compat/network_providers.dart';

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
  });

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

  // Keep this bounded: a long feed can create many Hero tags over time.
  static final LinkedHashMap<Object, List<String>> _transitionHistory =
      LinkedHashMap<Object, List<String>>();
  static const _maxTransitionKeys = 256;
  static const _maxUrlsPerKey = 4;

  static Map<String, String> get headers => {
    'Referer': PixivClientIdentity.downloadReferer.toString(),
  };

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
      color: filterColor,
      colorBlendMode: filterBlendMode,
      // Crossfade only for artwork that has not completed decoding yet:
      // already-cached images (Hero hand-off targets, preloaded URLs) must
      // appear instantly — a translucent fade over the page background is
      // the white flash.
      fadeInDuration: fade && !imageCompleted && !isUrlTransition
          ? const Duration(milliseconds: 350)
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
