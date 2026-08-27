import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/pixiv_client_identity.dart';
import '../core/settings/settings_controller.dart';

/// Shared Pixiv CDN image widget: every i.pximg.net request must carry the
/// app-API Referer or the CDN answers 403 (beta56 PixivImage semantics).
class PixivImage extends ConsumerWidget {
  const PixivImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholderColor = const Color(0x33343838),
    this.filterColor,
    this.filterBlendMode,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Color placeholderColor;
  final Color? filterColor;
  final BlendMode? filterBlendMode;

  static Map<String, String> get headers => {
    'Referer': PixivClientIdentity.downloadReferer.toString(),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // PixivImage is also used by the standalone viewer tests and by embedders
    // that do not install Riverpod. Keep the original URL in that context;
    // the application shell always provides the settings scope.
    var imageUrl = url;
    var hasProviderScope = true;
    try {
      ProviderScope.containerOf(context, listen: false);
    } on StateError {
      hasProviderScope = false;
    }
    if (hasProviderScope) {
      imageUrl = ref.watch(
        settingsProvider.select(
          (async) => async.value?.rewriteImageUrl(url) ?? url,
        ),
      );
    }
    final image = CachedNetworkImage(
      imageUrl: imageUrl,
      httpHeaders: headers,
      width: width,
      height: height,
      fit: fit,
      color: filterColor,
      colorBlendMode: filterBlendMode,
      placeholder: (_, _) => ColoredBox(color: placeholderColor),
      errorWidget: (_, _, _) => ColoredBox(
        color: placeholderColor,
        child: const Icon(Icons.broken_image),
      ),
    );
    return image;
  }
}
