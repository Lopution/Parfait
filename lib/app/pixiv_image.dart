import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/network/pixiv_client_identity.dart';

/// Shared Pixiv CDN image widget: every i.pximg.net request must carry the
/// app-API Referer or the CDN answers 403 (beta56 PixivImage semantics).
class PixivImage extends StatelessWidget {
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

  static Map<String, String> get headers =>
      {'Referer': PixivClientIdentity.downloadReferer.toString()};

  @override
  Widget build(BuildContext context) {
    final image = CachedNetworkImage(
      imageUrl: url,
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
