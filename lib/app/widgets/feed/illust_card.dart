import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../../core/network/compat/network_providers.dart';
import '../../../core/settings/settings_controller.dart';
import '../../theme/func_tokens.dart';
import '../../motion/hero_transition.dart';
import '../../navigation/routes.dart';
import '../../pixiv_image.dart';
import '../../widgets/bookmark_switch_button.dart';

/// Illust preview card replicating beta56 IllustPreviewer semantics:
/// R-18 top-left, ugoira gif bottom-left, page count top-right, AI
/// bottom-right, title (14 bold) + user name (12) beneath the image.
class IllustCard extends ConsumerWidget {
  const IllustCard({super.key, required this.entity, this.heroScope = 'feed'});

  final IllustEntity entity;
  final String heroScope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final previewQuality = ref.watch(previewQualityProvider);
    final previewUrl = entity.previewUrl(previewQuality);
    final heroTag = illustHeroTag(heroScope, entity.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPreview(context, ref, colorScheme, previewUrl, heroTag),
        const SizedBox(height: 4),
        _buildTitle(),
      ],
    );
  }

  Widget _buildPreview(
    BuildContext context,
    WidgetRef ref,
    ColorScheme colorScheme,
    String previewUrl,
    String heroTag,
  ) {
    // Beta56 IllustPreviewer semantics: the preview height follows the
    // original aspect ratio (BoxFit.fitWidth) inside the waterfall flow,
    // so works are never cropped in the feed.
    return LayoutBuilder(
      builder: (context, constraints) {
        final previewHeight = entity.width > 0
            ? constraints.maxWidth / entity.width * entity.height
            : constraints.maxWidth;
        return GestureDetector(
          onTapDown: (_) => _preloadTransitionImages(context, ref, previewUrl),
          onTap: () {
            _preloadTransitionImages(context, ref, previewUrl);
            openIllust(
              context,
              entity.id,
              initialEntity: entity,
              heroScope: heroScope,
              heroImageUrl: previewUrl,
            );
          },
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: SizedBox(
              width: constraints.maxWidth,
              height: previewHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildHeroImage(previewUrl, heroTag, constraints.maxWidth),
                  ..._buildBadges(colorScheme),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeroImage(String previewUrl, String heroTag, double width) {
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

  Widget _buildTitle() {
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
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                entity.user.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
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
  ) {
    final cacheManager = ref
        .read(pixivNetworkFactoryProvider)
        .imageCacheManager;
    unawaited(
      PixivImage.preload(context, previewUrl, cacheManager: cacheManager),
    );
    final avatarUrl = entity.user.profileImageUrl;
    if (avatarUrl != null) {
      unawaited(
        PixivImage.preload(context, avatarUrl, cacheManager: cacheManager),
      );
    }
  }
}
