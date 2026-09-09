import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/motion/hero_transition.dart';
import '../../../../app/pixiv_image.dart';
import '../../../../app/theme/func_tokens.dart';
import '../../../../app/widgets/app_snack_bar.dart';
import '../../../../core/download/download_providers.dart';
import '../../../../core/download/download_task.dart' show DownloadStatus;
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
    this.heroImageUrl,
    this.detailUrl,
    required this.downloadMode,
    required this.onLongPress,
    this.placeholderOnly = false,
  });

  final IllustEntity entity;
  final int index;
  final String heroTag;
  final String? heroImageUrl;

  /// True while the detail payload is still loading for a multi-page work:
  /// the page renders a neutral placeholder instead of an image whose URL
  /// does not exist in the feed snapshot yet.
  final bool placeholderOnly;

  /// Detail-quality URL once the detail payload is merged. Preferring it
  /// over [heroImageUrl] means the detail hero upgrades from the feed
  /// preview to the user's chosen detail quality as soon as data arrives.
  final String? detailUrl;
  final bool downloadMode;
  final VoidCallback onLongPress;

  @override
  ConsumerState<DetailPageImage> createState() => _DetailPageImageState();
}

class _DetailPageImageState extends ConsumerState<DetailPageImage> {
  /// Optimistic in-flight flag: the badge switches to the loading spinner
  /// the moment the user taps, before the coordinator notification arrives.
  bool _optimisticDownloading = false;

  IllustEntity get entity => widget.entity;
  bool get downloadMode => widget.downloadMode;

  @override
  Widget build(BuildContext context) {
    final download = ref.watch(illustDownloadControllerProvider);
    final manager = ref.watch(downloadManagerProvider);
    final viewQuality = ref.watch(viewQualityProvider);
    final state = download.stateFor(entity.id, widget.index);
    final isPagePlaceholder = widget.placeholderOnly && widget.index > 0;
    final hasActiveTask = manager.tasks.any(
      (task) =>
          task.illustId == entity.id &&
          task.pageIndex == widget.index &&
          switch (task.status) {
            DownloadStatus.queued ||
            DownloadStatus.running ||
            DownloadStatus.finalizing ||
            DownloadStatus.canceling => true,
            DownloadStatus.failed ||
            DownloadStatus.canceled ||
            DownloadStatus.retryable ||
            DownloadStatus.succeeded ||
            DownloadStatus.orphaned => false,
          },
    );
    // PixivImage keeps its last decoded frame when this URL changes. That
    // gives every quality hand-off (preview -> detail and medium -> large ->
    // original) the same gapless behavior without a second preload state in
    // each page widget.
    final previewUrl =
        widget.detailUrl ??
        (widget.index == 0 && widget.heroImageUrl != null
            ? widget.heroImageUrl!
            : entity.pageCount > 1 && widget.index < entity.metaPages.length
            ? entity.metaPages[widget.index].large
            : entity.imageUrls.large);
    final image = GestureDetector(
      onTap: isPagePlaceholder
          ? null
          : () => _openViewer(context, quality: viewQuality),
      onLongPress: isPagePlaceholder ? null : widget.onLongPress,
      child: AspectRatio(
        // Per-page ratio (R7): meta_pages carry their own width/height and
        // multi-page works legitimately differ page to page. Using the
        // work-level ratio + BoxFit.cover cropped every non-first page
        // (visible on the 31-page strip work).
        aspectRatio: entity.pageAspectRatioAt(widget.index),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Keep download controls out of the Hero flight. The matching
            // feed Hero contains only this image, so a page-count badge can
            // never be scaled or retained by a detail pop transition.
            // Both directions use the same progress-aware endpoint boundary
            // (see illustHeroFlightShuttleBuilder), so occlusion follows the
            // route chrome continuously instead of hard-cutting at landing.
            if (isPagePlaceholder)
              _DetailImageFallback()
            else
              Hero(
                tag: widget.heroTag,
                flightShuttleBuilder: illustHeroFlightShuttleBuilder,
                child: PixivImage.detail(
                  previewUrl,
                  fit: BoxFit.contain,
                  transitionKey: widget.heroTag,
                  // Keep the loading transition for cold detail images. A
                  // cached Hero hand-off is still instantaneous because
                  // PixivImage disables its fade for completed cache entries.
                  filterColor: downloadMode ? FuncTokens.imageOverlay : null,
                  filterBlendMode: downloadMode ? BlendMode.srcOver : null,
                ),
              ),
            if (downloadMode && !isPagePlaceholder)
              Positioned(
                top: 20,
                right: 20,
                child: _DownloadBadge(
                  state:
                      _optimisticDownloading &&
                          state == IllustPageSaveState.none &&
                          hasActiveTask
                      ? IllustPageSaveState.downloading
                      : state,
                  onTap: () {
                    try {
                      download.download(entity, widget.index);
                      // Immediate visual feedback: the spinner shows before
                      // the coordinator/task notification round trip.
                      setState(() => _optimisticDownloading = true);
                      showAppSnackBar(
                        context,
                        context.l10n.downloadQueuedMessage,
                      );
                    } catch (error) {
                      // Any submission failure must be visible on device: the
                      // manager/ownership/channel errors that are not
                      // FormatException otherwise vanish with no UI feedback.
                      showAppSnackBar(
                        context,
                        context.l10n.downloadSubmissionFailed(error.toString()),
                      );
                    }
                  },
                ),
              ),
          ],
        ),
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
      color: colors.surfaceContainerHighest,
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

class _DownloadBadge extends StatelessWidget {
  const _DownloadBadge({required this.state, required this.onTap});

  final IllustPageSaveState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = switch (state) {
      IllustPageSaveState.none => const Icon(
        Icons.file_download_outlined,
        size: 30,
      ),
      IllustPageSaveState.downloading => const SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(),
      ),
      IllustPageSaveState.error => Icon(
        Icons.error_outline,
        color: theme.colorScheme.error,
        size: 30,
      ),
      IllustPageSaveState.exist => Icon(
        Icons.check,
        color: theme.colorScheme.primary,
        size: 30,
      ),
    };
    return GestureDetector(
      onTap: state == IllustPageSaveState.downloading ? null : onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(30),
        ),
        child: child,
      ),
    );
  }
}
