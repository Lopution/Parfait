import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/entity/illust_entity.dart';
import '../../format/app_format.dart';
import '../../format/content_locale.dart';
import '../../../core/mute/mute_predicate.dart';
import '../../../core/mute/mute_store.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../../theme/func_semantic_tokens.dart';
import '../../motion/hero_transition.dart';
import '../../motion/press_scale.dart';
import '../../navigation/routes.dart';
import '../../pixiv_image.dart';
import '../../image_tier_cache.dart';
import '../../widgets/bookmark_switch_button.dart';
import '../card_actions/card_action_sheet.dart';
import '../entity_row.dart';
import 'feed_grid.dart';
import 'illust_card_layout.dart';
import 'muted_cover.dart';
import '../../haptics/app_haptics.dart';

/// Illust preview card replicating beta56 IllustPreviewer semantics:
/// R-18 top-left, ugoira gif bottom-left, page count top-right, AI
/// bottom-right, title (14 bold) + user name (12) beneath the image.
class IllustCard extends StatefulWidget {
  /// The default key follows the work id so a feed refresh keeps each
  /// element attached to its own work instead of recycling the slot for a
  /// different one — the image widget then sees a slot hand-off only when
  /// the element genuinely changed works. The scope disambiguates the same
  /// work appearing in two feeds at once (e.g. ranking + search copies).
  IllustCard({
    Key? key,
    required this.entity,
    this.heroScope = 'feed',
    this.rank,
    this.meta,
    this.onLongPress,
  }) : super(key: key ?? ValueKey('illust-$heroScope-${entity.id}'));

  /// Left indent of the title/author block under the card image. The
  /// skeleton's text bones use the same value.
  static const textIndent = FuncSpacing.md;

  final IllustEntity entity;
  final String heroScope;

  /// Ranking position (ranking lists), shown at the start of the title line
  /// ([EntityRankLabel]) and read as "No. n, title".
  final int? rank;

  /// Optional meta line under the author (the history page's date row).
  /// Rendered as the caller hands it over — typically [EntityMetaText].
  final Widget? meta;

  /// Long-press override; defaults to the shared card action sheet.
  /// Management pages (history selection mode) supply their own so the
  /// gesture enters selection instead of opening actions.
  final VoidCallback? onLongPress;

  @override
  State<IllustCard> createState() => _IllustCardState();
}

/// Hands the same body back while a parent rebuild passes the same inputs.
/// A feed grid rebuilds every built card on each feed state change (a
/// load-more phase flip, an appended page); the unchanged body instance
/// lets the element skip the whole card subtree. The body still rebuilds
/// on its own provider and inherited dependencies.
class _IllustCardState extends State<IllustCard> {
  late _IllustCardBody _body = _IllustCardBody(widget);

  @override
  void didUpdateWidget(IllustCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.entity, oldWidget.entity) ||
        widget.heroScope != oldWidget.heroScope ||
        widget.rank != oldWidget.rank ||
        !identical(widget.meta, oldWidget.meta) ||
        !identical(widget.onLongPress, oldWidget.onLongPress)) {
      _body = _IllustCardBody(widget);
    }
  }

  @override
  Widget build(BuildContext context) => _body;
}

class _IllustCardBody extends ConsumerWidget {
  const _IllustCardBody(this.card);

  final IllustCard card;

  IllustEntity get entity => card.entity;
  String get heroScope => card.heroScope;
  int? get rank => card.rank;
  Widget? get meta => card.meta;
  VoidCallback? get onLongPress => card.onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPreview(context, ref),
        const SizedBox(height: FuncSpacing.xs),
        _buildTitle(context),
      ],
    );
  }

  Widget _buildPreview(BuildContext context, WidgetRef ref) {
    // The grid publishes the resolved column width — reading it skips the
    // per-card LayoutBuilder entirely. The fallback keeps direct (non-grid)
    // usages working.
    final inheritedWidth = FeedItemExtent.maybeOf(context);
    if (inheritedWidth != null) {
      return _buildPreviewWithWidth(context, ref, inheritedWidth);
    }
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildPreviewWithWidth(context, ref, constraints.maxWidth),
    );
  }

  Widget _buildPreviewWithWidth(
    BuildContext context,
    WidgetRef ref,
    double cardWidth,
  ) {
    final cardDecodeWidth = PixivImage.decodeWidthFor(cardWidth);
    // Beta56 IllustPreviewer semantics: the preview height follows the
    // original aspect ratio up to 1:2. Taller works crop to the top of
    // `large` or switch to the square thumbnail (illustCardPreview).
    final preview = illustCardPreview(
      entity,
      quality: ref.watch(previewQualityProvider),
      cardPhysicalWidth: cardDecodeWidth,
    );
    final heroTag = illustHeroTag(heroScope, entity.id);
    // The square thumbnail is a different image from the detail page's:
    // that card opens without a Hero and hands the detail no first frame.
    final hasHero = preview.crop != IllustCardCrop.square;
    // Mute presentation (default blur mode): a hit renders the blurred
    // cover and the first tap reveals in place instead of opening the
    // detail. Hide mode never reaches here — the feed filter already
    // removed the id. Reveal is session-local and never edits the store.
    final mutedHit = ref.watch(
      muteStoreProvider.select((s) => muteHitFor(entity, s)),
    );
    final revealed = ref.watch(
      revealedMuteIdsProvider.select((ids) => ids.contains(entity.id)),
    );
    final muted = mutedHit != null && !revealed;
    void openDetail() {
      _preloadTransitionImages(context, ref, preview, cardDecodeWidth);
      openIllust(
        context,
        entity.id,
        initialEntity: entity,
        heroScope: heroScope,
        heroImageUrl: hasHero ? preview.url : null,
        heroImageDecodeWidth: hasHero ? cardDecodeWidth : null,
        // Inside a feed grid this carries the feed's work list — the
        // detail route then opens as a work-to-work pager.
        pagerSource: IllustPagerScope.maybeOf(context),
      );
    }

    final previewHeight = cardWidth * preview.heightRatio;
    final image = _buildImage(preview, heroTag, cardWidth);
    void reveal() {
      ref.read(revealedMuteIdsProvider.notifier).reveal(entity.id);
    }

    final longPress =
        onLongPress ??
        () {
          AppHaptics.longPress();
          showCardActionSheet(context, entity);
        };
    return PressScale(
      child: Semantics(
        container: true,
        button: true,
        image: true,
        // The one stop for the work: the title and author lines under the
        // image are left out of semantics, so the label carries them (and
        // the rank) instead of a screen reader reading them twice.
        label: muted
            ? context.l10n.labelValue(
                context.l10n.mutedContent,
                '${entity.title}, ${entity.user.name}',
              )
            : [
                if (rank case final rank?) context.l10n.rankLabel(rank),
                entity.title,
                entity.user.name,
              ].join(', '),
        onTap: muted ? reveal : openDetail,
        onLongPress: longPress,
        child: GestureDetector(
          excludeFromSemantics: true,
          onTapDown: muted
              ? null
              : (_) => _preloadTransitionImages(
                  context,
                  ref,
                  preview,
                  cardDecodeWidth,
                ),
          onTap: muted ? reveal : openDetail,
          onLongPress: longPress,
          // No outer ClipRRect: the Hero child already clips the image to
          // the same 12px radius and every badge sits 7px inside the
          // bounds, so the extra clip only cost a saveLayer per card per
          // frame while scrolling.
          child: SizedBox(
            width: cardWidth,
            height: previewHeight,
            child: muted
                ? MutedCover(reasonLabel: mutedHit.label, child: image)
                : Stack(
                    fit: StackFit.expand,
                    children: [image, ..._buildBadges(context)],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(IllustCardPreview preview, String heroTag, double width) {
    final tier = preview.tier;
    final framed = IllustHeroCardFrame(
      cropAspect: preview.crop == IllustCardCrop.top
          ? entity.pageAspectRatioAt(0)
          : null,
      child: PixivImage.feed(
        preview.url,
        layoutWidth: width,
        fit: switch (preview.crop) {
          IllustCardCrop.none => BoxFit.fitWidth,
          IllustCardCrop.top || IllustCardCrop.square => BoxFit.cover,
        },
        alignment: preview.crop == IllustCardCrop.top
            ? Alignment.topCenter
            : Alignment.center,
        transitionKey: heroTag,
        // Record the painted tier but never upgrade it: the feed always
        // renders its configured preview tier — an upgraded file would
        // decode to the same output size and only cost extra file reads.
        // The square crop is no tier and records nothing.
        tierKey: tier == null ? null : entity.imageTierKeyAt(0),
        tier: tier,
        tierUpgrade: false,
      ),
    );
    if (preview.crop == IllustCardCrop.square) return framed;
    // Only the image participates in the detail Hero flight. Badges belong to
    // the feed viewport; when the whole Stack was the Hero, the page-count
    // badge was scaled and left as a large ghost during pop.
    //
    // The card frame (rounded clip) sits INSIDE the Hero child (R7 Ugoira):
    // Hero flight renders the raw child, so a clip outside the Hero only
    // applied after the flight finished — the image snapped from square to
    // rounded on pop.
    return Hero(
      tag: heroTag,
      flightShuttleBuilder: illustHeroFlightShuttleBuilder,
      child: framed,
    );
  }

  List<Widget> _buildBadges(BuildContext context) {
    final l10n = context.l10n;
    // Four fixed corner slots, 7dp inside the image. The ranking position
    // is not a badge — it leads the title line.
    return [
      if (entity.isR18)
        const Positioned(left: 7, top: 7, child: EntityBadge(label: 'R-18')),
      if (entity.isUgoira)
        Positioned(
          left: 7,
          bottom: 7,
          child: EntityBadge(
            icon: Icons.gif_box_outlined,
            semanticsLabel: l10n.badgeUgoira,
          ),
        ),
      if (entity.pageCount > 1)
        Positioned(
          right: 7,
          top: 7,
          child: EntityBadge(
            icon: Icons.photo_library_outlined,
            label: AppFormat.count(context, entity.pageCount),
            semanticsLabel: l10n.illustPagesTotal(entity.pageCount),
          ),
        ),
      if (entity.isAi)
        Positioned(
          right: 7,
          bottom: 7,
          child: EntityBadge(label: 'AI', semanticsLabel: l10n.badgeAi),
        ),
    ];
  }

  Widget _buildTitle(BuildContext context) {
    // Beta56 title row: 10px indent, title/user block, bookmark heart on the
    // right (BookmarkSwitchButton isButton variant).
    return Row(
      children: [
        const SizedBox(width: IllustCard.textIndent),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Read through the image's label (H2).
              ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTitleLine(context),
                    Text(
                      entity.user.name,
                      locale: contentLocale(context, entity.user.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FuncSemanticTokens.of(context).caption,
                    ),
                  ],
                ),
              ),
              ?meta,
            ],
          ),
        ),
        BookmarkSwitchButton(illustId: entity.id, title: entity.title),
      ],
    );
  }

  Widget _buildTitleLine(BuildContext context) {
    final title = Text(
      entity.title,
      locale: contentLocale(context, entity.title),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: FuncSemanticTokens.of(
        context,
      ).label.copyWith(fontWeight: FontWeight.bold),
    );
    final rank = this.rank;
    if (rank == null) return title;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        EntityRankLabel(rank),
        const SizedBox(width: FuncSpacing.xs),
        Expanded(child: title),
      ],
    );
  }

  void _preloadTransitionImages(
    BuildContext context,
    WidgetRef ref,
    IllustCardPreview preview,
    int decodeWidth,
  ) {
    final previewUrl = preview.url;
    final previewTier = preview.tier;
    // Warm the exact decoded entry the feed card displays AND the detail
    // hero phase reuses (same ResizeImage width): the whole feed -> detail
    // hand-off then hits an already-decoded frame.
    unawaited(
      PixivImage.preload(
        context,
        previewUrl,
        tierKey: previewTier == null ? null : entity.imageTierKeyAt(0),
        tier: previewTier,
        memCacheWidth: decodeWidth,
      ),
    );
    final avatarUrl = entity.user.profileImageUrl;
    if (avatarUrl != null) {
      unawaited(PixivImage.preload(context, avatarUrl));
    }
    // Warm the detail-tier page-0 image too: the detail page swaps off the
    // preview URL as soon as its payload lands, and without this the bigger
    // variant still starts from zero on open. Original stays lazy — a
    // cancelled tap must not burn a multi-MB fetch on a background lane.
    // The user is waiting for this one, so it must not queue behind feed
    // prefetch.
    final detailQuality = ref.read(detailQualityProvider);
    if (detailQuality != DetailQuality.original) {
      final detailUrl = entity.detailUrlAt(0, detailQuality);
      if (detailUrl != previewUrl) {
        unawaited(
          PixivImage.preload(
            context,
            detailUrl,
            tierKey: entity.imageTierKeyAt(0),
            tier: detailQuality.tier,
            priority: ImageFetchPriority.foreground,
          ),
        );
      }
    }
  }
}
