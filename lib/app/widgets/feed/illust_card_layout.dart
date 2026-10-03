import 'dart:math' as math;

import '../../../core/entity/illust_entity.dart';
import '../../../core/settings/app_settings.dart';
import '../../image_tier_cache.dart';

/// How a feed card shows a work taller than [kFeedCardMaxHeightRatio].
enum IllustCardCrop {
  /// The whole work at its own ratio.
  none,

  /// The top of the `large` thumbnail in a 1:2 box. Still the same image
  /// as the detail page, so the card keeps its Hero.
  top,

  /// pixiv's square thumbnail (an author-chosen crop) in a 1:1 box. A
  /// different image from the detail page: no Hero.
  square,
}

/// What one feed card paints: box ratio (height / width), image URL and
/// tier, and how the image takes part in the detail Hero.
typedef IllustCardPreview = ({
  double heightRatio,
  String url,

  /// Null for [IllustCardCrop.square]: a square crop is not a resize tier.
  IllustImageTier? tier,
  IllustCardCrop crop,
});

/// The tallest card box, as a multiple of the card width.
const kFeedCardMaxHeightRatio = 2.0;

/// A tall work keeps a cropped `large` card only while that thumbnail is at
/// least this share of the card's physical width; below it the upscale
/// shows as blur and the card switches to the square thumbnail.
const kFeedTallCropMinSourceShare = 0.8;

/// Side of pixiv's resized square thumbnail (`c/540x540_70`).
const kSquarePreviewSide = 540;

/// pixiv fits `large` thumbnails into 600×1200; a work taller than 1:2 is
/// bound by the height.
const _kLargeMaxHeight = 1200;

/// The single card layout rule, shared by the card and the feed prefetch
/// so both fetch the same URL at the same decode width.
IllustCardPreview illustCardPreview(
  IllustEntity entity, {
  required PreviewQuality quality,
  required int cardPhysicalWidth,
}) {
  final known = entity.width > 0 && entity.height > 0;
  final ratio = known ? entity.height / entity.width : 1.0;
  if (ratio <= kFeedCardMaxHeightRatio) {
    return (
      heightRatio: ratio,
      url: entity.previewUrl(quality),
      tier: quality.tier,
      crop: IllustCardCrop.none,
    );
  }
  final largeWidth = math.min(entity.width, _kLargeMaxHeight / ratio);
  if (largeWidth >= kFeedTallCropMinSourceShare * cardPhysicalWidth) {
    return (
      heightRatio: kFeedCardMaxHeightRatio,
      url: entity.imageUrls.large,
      tier: IllustImageTier.large,
      crop: IllustCardCrop.top,
    );
  }
  return (
    heightRatio: 1.0,
    url: squarePreviewUrl(entity.imageUrls.squareMedium, cardPhysicalWidth),
    tier: null,
    crop: IllustCardCrop.square,
  );
}

/// The square thumbnail sized for the card. `square_medium` is
/// `c/360x360_70/img-master/…_square1200.jpg`: a card up to
/// [kSquarePreviewSide] physical pixels takes the 540 resize, a wider one
/// the unresized `img-master/…_square1200.jpg`. Only the path changes, so
/// the mirror rewrite (host only) still applies. An unrecognised shape
/// stays `square_medium`.
String squarePreviewUrl(String squareMedium, int cardPhysicalWidth) {
  final uri = Uri.tryParse(squareMedium);
  if (uri == null) return squareMedium;
  final segments = uri.pathSegments;
  if (segments.length < 3 ||
      segments[0] != 'c' ||
      segments[2] != 'img-master') {
    return squareMedium;
  }
  final rest = segments.skip(2);
  final path = cardPhysicalWidth <= kSquarePreviewSide
      ? ['c', '${kSquarePreviewSide}x${kSquarePreviewSide}_70', ...rest]
      : rest;
  return uri.replace(pathSegments: path).toString();
}
