import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/network/compat/network_providers.dart';
import '../../../core/settings/settings_controller.dart';
import '../../theme/func_semantic_tokens.dart';
import '../../theme/func_tokens.dart';
import '../../motion/hero_transition.dart';
import '../../motion/press_scale.dart';
import '../../navigation/routes.dart';
import '../../pixiv_image.dart';
import '../../image_tier_cache.dart';
import '../../widgets/bookmark_switch_button.dart';
import 'feed_grid.dart';

/// Illust preview card replicating beta56 IllustPreviewer semantics:
/// R-18 top-left, ugoira gif bottom-left, page count top-right, AI
/// bottom-right, title (14 bold) + user name (12) beneath the image.
class IllustCard extends ConsumerWidget {
  /// The default key follows the work id so a feed refresh keeps each
  /// element attached to its own work instead of recycling the slot for a
  /// different one — the image widget then sees a slot hand-off only when
  /// the element genuinely changed works. The scope disambiguates the same
  /// work appearing in two feeds at once (e.g. ranking + search copies).
  IllustCard({Key? key, required this.entity, this.heroScope = 'feed'})
    : super(key: key ?? ValueKey('illust-$heroScope-${entity.id}'));

  final IllustEntity entity;
  final String heroScope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final previewQuality = ref.watch(previewQualityProvider);
    // Pixiv's medium endpoint is capped at a small source width. A very tall
    // work paints a large continuous surface in the waterfall, so stretching
    // that cap is especially obvious as blur. Use the same uncropped large
    // source for ultra-tall works while retaining the user's quality choice
    // for ordinary cards.
    final isUltraTall = entity.width > 0 && entity.height / entity.width >= 2.5;
    final previewUrl = isUltraTall
        ? entity.imageUrls.large
        : entity.previewUrl(previewQuality);
    final previewTier = isUltraTall
        ? IllustImageTier.large
        : previewQuality.tier;
    final heroTag = illustHeroTag(heroScope, entity.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPreview(
          context,
          ref,
          colorScheme,
          previewUrl,
          heroTag,
          previewTier,
        ),
        const SizedBox(height: 4),
        _buildTitle(context),
      ],
    );
  }

  Widget _buildPreview(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
    String previewUrl,
    String heroTag,
    IllustImageTier previewTier,
  ) {
    // Beta56 IllustPreviewer semantics: the preview height follows the
    // original aspect ratio (BoxFit.fitWidth) inside the waterfall flow,
    // so works are never cropped in the feed.

    // The grid publishes the resolved column width — reading it skips the
    // per-card LayoutBuilder entirely. The fallback keeps direct (non-grid)
    // usages working.
    final inheritedWidth = FeedItemExtent.maybeOf(context);
    if (inheritedWidth != null) {
      return _buildPreviewWithWidth(
        context,
        ref,
        colorScheme,
        previewUrl,
        heroTag,
        previewTier,
        inheritedWidth,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => _buildPreviewWithWidth(
        context,
        ref,
        colorScheme,
        previewUrl,
        heroTag,
        previewTier,
        constraints.maxWidth,
      ),
    );
  }

  Widget _buildPreviewWithWidth(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
    String previewUrl,
    String heroTag,
    IllustImageTier previewTier,
    double cardWidth,
  ) {
    final cardDecodeWidth = PixivImage.decodeWidthFor(cardWidth);
    void openDetail() {
      _preloadTransitionImages(
        context,
        ref,
        previewUrl,
        previewTier,
        cardDecodeWidth,
      );
      openIllust(
        context,
        entity.id,
        initialEntity: entity,
        heroScope: heroScope,
        heroImageUrl: previewUrl,
        heroImageDecodeWidth: cardDecodeWidth,
      );
    }

    final previewHeight = entity.width > 0
        ? cardWidth / entity.width * entity.height
        : cardWidth;
    return PressScale(
      child: Semantics(
        container: true,
        button: true,
        image: true,
        label: '${entity.title}, ${entity.user.name}',
        onTap: openDetail,
        child: GestureDetector(
          excludeFromSemantics: true,
          onTapDown: (_) => _preloadTransitionImages(
            context,
            ref,
            previewUrl,
            previewTier,
            cardDecodeWidth,
          ),
          onTap: openDetail,
          // No outer ClipRRect: the Hero child already clips the image to
          // the same 12px radius and every badge sits 7px inside the
          // bounds, so the extra clip only cost a saveLayer per card per
          // frame while scrolling.
          child: SizedBox(
            width: cardWidth,
            height: previewHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildHeroImage(previewUrl, heroTag, cardWidth, previewTier),
                ..._buildBadges(colorScheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroImage(
    String previewUrl,
    String heroTag,
    double width,
    IllustImageTier previewTier,
  ) {
    // Only the image participates in the detail Hero flight. Badges belong to
    // the feed viewport; when the whole Stack was the Hero, the page-count
    // badge was scaled and left as a large ghost during pop.
    //
    // The ClipRRect sits INSIDE the Hero child (R7 Ugoira):
    // Hero flight renders the raw child, so a clip outside the Hero only
    // applied after the flight finished — the image snapped from square to
    // rounded on pop. Clipping inside keeps the rounded corners during the
    // whole flight.
    return Hero(
      tag: heroTag,
      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: PixivImage.feed(
          previewUrl,
          layoutWidth: width,
          fit: BoxFit.fitWidth,
          transitionKey: heroTag,
          // Record the painted tier but never upgrade it: the feed always
          // renders its configured preview tier — an upgraded file would
          // decode to the same output size and only cost extra file reads.
          tierKey: entity.imageTierKeyAt(0),
          tier: previewTier,
          tierUpgrade: false,
        ),
      ),
    );
  }

  List<Widget> _buildBadges(ColorScheme colorScheme) {
    return [
      if (entity.isR18)
        Positioned(
          left: 7,
          top: 7,
          child: Card(
            color: colorScheme.primary,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              child: Text(
                'R-18',
                style: TextStyle(color: FuncTokens.lightBackground),
              ),
            ),
          ),
        ),
      if (entity.isUgoira)
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
      if (entity.pageCount > 1)
        Positioned(
          right: 7,
          top: 7,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7.5),
              color: const Color(0x99343838),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Text(
                '${entity.pageCount}',
                style: TextStyle(color: FuncTokens.lightBackground),
              ),
            ),
          ),
        ),
      if (entity.isAi)
        Positioned(
          right: 7,
          bottom: 7,
          child: Card(
            color: colorScheme.error,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              child: Text(
                'AI',
                style: TextStyle(color: FuncTokens.lightBackground),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildTitle(BuildContext context) {
    // Beta56 title row: 10px indent, title/user block, bookmark heart on the
    // right (BookmarkSwitchButton isButton variant).
    return Row(
      children: [
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entity.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FuncSemanticTokens.of(
                  context,
                ).label.copyWith(fontWeight: FontWeight.bold),
              ),
              Text(
                entity.user.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FuncSemanticTokens.of(context).caption,
              ),
            ],
          ),
        ),
        BookmarkSwitchButton(illustId: entity.id, title: entity.title),
      ],
    );
  }

  void _preloadTransitionImages(
    BuildContext context,
    WidgetRef ref,
    String previewUrl,
    IllustImageTier previewTier,
    int decodeWidth,
  ) {
    final cacheManager = ref
        .read(pixivNetworkFactoryProvider)
        .imageCacheManager;
    // Warm the exact decoded entry the feed card displays AND the detail
    // hero phase reuses (same ResizeImage width): the whole feed -> detail
    // hand-off then hits an already-decoded frame.
    unawaited(
      PixivImage.preload(
        context,
        previewUrl,
        cacheManager: cacheManager,
        tierKey: entity.imageTierKeyAt(0),
        tier: previewTier,
        memCacheWidth: decodeWidth,
      ),
    );
    final avatarUrl = entity.user.profileImageUrl;
    if (avatarUrl != null) {
      unawaited(
        PixivImage.preload(context, avatarUrl, cacheManager: cacheManager),
      );
    }
  }
}
