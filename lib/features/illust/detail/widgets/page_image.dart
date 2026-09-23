import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/motion/hero_transition.dart';
import '../../../../app/pixiv_image.dart';
import '../../../../app/theme/func_tokens.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/illust/illust_download_controller.dart';
import '../../../../core/settings/app_settings.dart';
import '../../../../core/settings/settings_controller.dart';
import '../../../../l10n/context.dart';
import '../../../../app/navigation/routes.dart';

class DetailPageImage extends ConsumerStatefulWidget {
  const DetailPageImage({
    super.key,
    required this.entity,
    required this.index,
    required this.heroTag,
    required this.heroScope,
    this.heroImageUrl,
    this.heroImageDecodeWidth,
    this.detailUrl,
    required this.downloadMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onLongPress,
    this.placeholderOnly = false,
  });

  final IllustEntity entity;
  final int index;
  final String heroTag;
  final String heroScope;
  final String? heroImageUrl;

  /// Decode width of the feed card that produced [heroImageUrl]. While the
  /// hero URL is displayed the image decodes at this width — the exact cache
  /// entry the feed already painted — so the hero landing frame is instant.
  final int? heroImageDecodeWidth;

  /// True while the detail payload is still loading for a multi-page work:
  /// the page renders a neutral placeholder instead of an image whose URL
  /// does not exist in the feed snapshot yet.
  final bool placeholderOnly;

  /// Detail-quality URL once the detail payload is merged. Preferring it
  /// over [heroImageUrl] means the detail hero upgrades from the feed
  /// preview to the user's chosen detail quality as soon as data arrives.
  final String? detailUrl;

  /// Explicit download-selection mode: while on, taps toggle [selected]
  /// through [onToggleSelect] instead of opening the viewer, and the
  /// corner badge shows the selection/download state.
  final bool downloadMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onLongPress;

  @override
  ConsumerState<DetailPageImage> createState() => _DetailPageImageState();
}

class _DetailPageImageState extends ConsumerState<DetailPageImage> {
  /// Detail data can arrive while the route is still flying. Keep the feed
  /// preview as the Hero child until the route settles; swapping its provider
  /// during the flight makes the image appear to be sampled or rescaled on
  /// every frame, especially on Android. The quality upgrade happens in the
  /// first settled build and remains gapless through PixivImage's cache.
  bool _routeTransitionComplete = true;
  Animation<double>? _routeAnimation;

  IllustEntity get entity => widget.entity;
  bool get downloadMode => widget.downloadMode;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;

    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    _routeAnimation = animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _routeTransitionComplete = true;
    } else {
      _routeTransitionComplete = false;
      animation.addStatusListener(_handleRouteAnimationStatus);
    }
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed) {
      if (_routeTransitionComplete) return;
      setState(() => _routeTransitionComplete = true);
      return;
    }
    // A pop keeps the detail-tier URL painted while the page slides out —
    // the reverse flight shuttle uses IllustHeroFlightChild.popChild, so
    // swapping this provider mid-flight only adds a re-resolve and a
    // repaint to frames that are already animating.
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final download = ref.watch(illustDownloadControllerProvider);
    final viewQuality = ref.watch(viewQualityProvider);
    final state = download.stateFor(entity.id, widget.index);
    final isPagePlaceholder = widget.placeholderOnly && widget.index > 0;
    // PixivImage keeps its last decoded frame when this URL changes. That
    // gives every quality hand-off (preview -> detail and medium -> large ->
    // original) the same gapless behavior without a second preload state in
    // each page widget.
    final onHeroPhase =
        widget.index == 0 &&
        widget.heroImageUrl != null &&
        (widget.detailUrl == null || !_routeTransitionComplete);
    final previewUrl = onHeroPhase
        ? widget.heroImageUrl!
        : widget.detailUrl ??
              (entity.pageCount > 1 && widget.index < entity.metaPages.length
                  ? entity.metaPages[widget.index].large
                  : entity.imageUrls.large);
    final image = GestureDetector(
      // Selection mode turns the whole page into a select toggle; outside
      // the mode a tap opens the viewer as before.
      onTap: isPagePlaceholder
          ? null
          : downloadMode
          ? widget.onToggleSelect
          : () => _openViewer(context, quality: viewQuality),
      onLongPress: isPagePlaceholder ? null : widget.onLongPress,
      // Loose stack: the loaded image sizes itself to its intrinsic aspect
      // ratio at full width. The app API's meta_pages never carries
      // per-page width/height, so a fixed AspectRatio always resolved to the
      // work-level (= first page) ratio and letterboxed every non-matching
      // page. PixEz does the same: the slot only holds an estimated box
      // until the decode lands, then the real dimensions take over.
      child: Stack(
        children: [
          // Keep download controls out of the Hero flight. The matching
          // feed Hero contains only this image, so a page-count badge can
          // never be scaled or retained by a detail pop transition.
          // Both directions use the same progress-aware endpoint boundary
          // (see illustHeroFlightShuttleBuilder), so occlusion follows the
          // route chrome continuously instead of hard-cutting at landing.
          if (isPagePlaceholder)
            AspectRatio(
              // No page payload yet — the work-level ratio is the only
              // estimate available and keeps the list from collapsing.
              aspectRatio: entity.pageAspectRatioAt(widget.index),
              child: _DetailImageFallback(),
            )
          else
            Hero(
              tag: widget.heroTag,
              flightShuttleBuilder: illustHeroFlightShuttleBuilder,
              child: IllustHeroFlightChild(
                // The detail endpoint stays sharp for the normal page and
                // for a viewer push. The shared shuttle swaps to the
                // already-decoded card preview only on a reverse flight.
                popChild: widget.heroImageUrl == null
                    ? null
                    : PixivImage.detail(
                        widget.heroImageUrl!,
                        fit: BoxFit.contain,
                        transitionKey: widget.heroTag,
                        tierKey: entity.imageTierKeyAt(widget.index),
                        tier: entity.imageTierOf(widget.heroImageUrl!),
                        tierUpgrade: false,
                        decodeWidth: widget.heroImageDecodeWidth,
                        filterColor: downloadMode
                            ? FuncTokens.imageOverlay
                            : null,
                        filterBlendMode: downloadMode
                            ? BlendMode.srcOver
                            : null,
                      ),
                child: PixivImage.detail(
                  previewUrl,
                  fit: BoxFit.contain,
                  transitionKey: widget.heroTag,
                  tierKey: entity.imageTierKeyAt(widget.index),
                  tier: entity.imageTierOf(previewUrl),
                  tierUpgrade: !onHeroPhase,
                  // The hero-phase URL is the feed card's image: decode it
                  // at the feed's width so the landing frame is the
                  // already-decoded cache entry. Once detailUrl arrives,
                  // the normal page endpoint uses screen width.
                  decodeWidth: onHeroPhase ? widget.heroImageDecodeWidth : null,
                  filterColor: downloadMode ? FuncTokens.imageOverlay : null,
                  filterBlendMode: downloadMode ? BlendMode.srcOver : null,
                  // Estimated box until the first frame: after decode the
                  // image's own aspect ratio sizes the slot instead.
                  placeholderWidget: AspectRatio(
                    aspectRatio: entity.pageAspectRatioAt(widget.index),
                    child: const ColoredBox(color: Color(0x33383838)),
                  ),
                ),
              ),
            ),
          if (downloadMode && !isPagePlaceholder)
            Positioned(
              top: 20,
              right: 20,
              child: _DownloadBadge(
                state: state,
                selected: widget.selected,
                label: context.l10n.viewerPageLabel(
                  widget.index + 1,
                  entity.pageCount,
                ),
                onTap: widget.onToggleSelect,
              ),
            ),
        ],
      ),
    );
    return image;
  }

  void _openViewer(BuildContext context, {required ViewQuality quality}) {
    openImageViewer(
      context,
      entity: entity,
      page: widget.index,
      quality: quality,
      heroScope: widget.heroScope,
    );
  }
}

/// Stable multi-page placeholder used while the detail payload is pending.
/// Rendering the feed snapshot's first-page URL in every slot made a strip
/// appear as duplicated artwork and allowed tapping a page that had no viewer
/// URL yet.
class _DetailImageFallback extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainer,
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: 36,
          color: colors.onSurfaceVariant.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// Selection-mode corner badge. Priority: in-flight spinner > selected
/// check > error/exist markers > unselected hollow circle. Tapping toggles
/// the page's selection — nothing downloads until the bottom bar's "done".
class _DownloadBadge extends StatelessWidget {
  const _DownloadBadge({
    required this.state,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final IllustPageSaveState state;
  final bool selected;

  /// TalkBack/Narrator label for the toggle ("Page n of N").
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = switch ((state, selected)) {
      (IllustPageSaveState.downloading, _) => const SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(),
      ),
      (_, true) => Icon(
        Icons.check_circle,
        color: theme.colorScheme.primary,
        size: 30,
      ),
      (IllustPageSaveState.error, false) => Icon(
        Icons.error_outline,
        color: theme.colorScheme.error,
        size: 30,
      ),
      (IllustPageSaveState.exist, false) => Icon(
        Icons.check,
        color: theme.colorScheme.primary,
        size: 30,
      ),
      _ => Icon(
        Icons.radio_button_unchecked,
        color: theme.colorScheme.onSurfaceVariant,
        size: 30,
      ),
    };
    return GestureDetector(
      onTap: state == IllustPageSaveState.downloading ? null : onTap,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(30),
          ),
          child: child,
        ),
      ),
    );
  }
}
