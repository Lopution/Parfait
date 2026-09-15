import 'dart:collection';

import '../core/entity/illust_entity.dart';
import '../core/settings/app_settings.dart';

/// Remembers which quality tier of each (work, page) has been decoded, so a
/// lower-tier request can be upgraded to an already-cached higher tier
/// instead of re-fetching a blurrier image.
///
/// Equivalent of pixez-flutter's `IllustCacher.targetUrl`: requesting the
/// medium URL after the large tier was fetched serves the large URL
/// directly — no second download, no tier-regression blur.
///
/// Upgrades only ever go *up* (requested -> higher cached tier). Serving a
/// lower cached tier for a higher request would silently downgrade the
/// visible quality, which is why the lookup never returns below the
/// requested tier.
class IllustTierCache {
  IllustTierCache._();

  // key -> [mediumUrl, largeUrl, originalUrl]; LRU via insertion order.
  static final LinkedHashMap<String, List<String?>> _entries =
      LinkedHashMap<String, List<String?>>();
  static const int _capacity = 512;

  /// Returns the best cached (url, tier) pair for [key] whose tier is at
  /// least [requested], or ([url], [requested]) when nothing better is
  /// known to be cached.
  static (String, IllustImageTier) resolve(
    String key,
    IllustImageTier requested,
    String url,
  ) {
    final tiers = _entries[key];
    if (tiers == null) return (url, requested);
    for (var i = IllustImageTier.values.length - 1; i > requested.index; i--) {
      final cached = tiers[i];
      if (cached != null) {
        return (cached, IllustImageTier.values[i]);
      }
    }
    return (url, requested);
  }

  /// True when this exact (tier, url) pair was already recorded for [key] —
  /// used to skip re-attaching decode listeners on every build.
  static bool isRecorded(String key, IllustImageTier tier, String url) =>
      _entries[key]?[tier.index] == url;

  /// Marks [url] — the [tier] image for [key] — as having actually been
  /// decoded, i.e. present in the image/disk cache. Call this when the
  /// image painted (or a preload completed), not at request time.
  static void record(String key, IllustImageTier tier, String url) {
    var tiers = _entries.remove(key);
    tiers ??= List<String?>.filled(IllustImageTier.values.length, null);
    tiers[tier.index] = url;
    _entries[key] = tiers; // reinsert -> LRU touch
    while (_entries.length > _capacity) {
      _entries.remove(_entries.keys.first);
    }
  }
}

extension PreviewQualityTier on PreviewQuality {
  IllustImageTier get tier => switch (this) {
    PreviewQuality.medium => IllustImageTier.medium,
    PreviewQuality.large => IllustImageTier.large,
  };
}

extension DetailQualityTier on DetailQuality {
  IllustImageTier get tier => switch (this) {
    DetailQuality.medium => IllustImageTier.medium,
    DetailQuality.large => IllustImageTier.large,
    DetailQuality.original => IllustImageTier.original,
  };
}

extension ViewQualityTier on ViewQuality {
  IllustImageTier get tier => switch (this) {
    ViewQuality.medium => IllustImageTier.medium,
    ViewQuality.large => IllustImageTier.large,
    ViewQuality.original => IllustImageTier.original,
  };
}
