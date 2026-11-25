import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/clipboard.dart';
import '../../../app/icons/app_icons.dart';
import '../../../app/icons/ui_icons.dart';
import '../../../app/widgets/bookmark_switch_button.dart';
import '../../../app/widgets/display_actions.dart';
import '../../../core/bookmark/bookmark_models.dart';
import '../../../core/bookmark/bookmark_store.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/illust/illust_download_controller.dart';
import '../../../core/platform/image_clipboard.dart';
import '../../../l10n/context.dart';

/// Builds the context-menu action list for [ImageViewerPage], keeping
/// bookmarking, saving, copying, sharing, zoom, and navigation together.
List<DisplayAction> buildImageViewerContextActions(
  BuildContext context, {
  required IllustEntity? entity,
  required int activePage,
  required int pageCount,
  required IllustPageSaveState? saveState,
  required bool zoomed,
  required VoidCallback onSavePage,
  required VoidCallback onDownloadAll,
  required VoidCallback onShare,
  required VoidCallback onToggleZoom,
  required VoidCallback onBack,
}) {
  final l10n = context.l10n;
  final bookmarkKey = entity == null
      ? null
      : BookmarkKey(BookmarkEntityType.illust, entity.id);
  final bookmarkEntry = bookmarkKey == null
      ? null
      : ProviderScope.containerOf(
          context,
          listen: false,
        ).read(bookmarkStoreProvider)[bookmarkKey];
  final bookmarked = bookmarkEntry?.shown ?? false;
  final unsettled = bookmarkEntry?.isUnsettled ?? false;

  return [
    if (entity != null && bookmarkKey != null) ...[
      DisplayAction(
        icon: bookmarked ? AppIcons.heartFilled : AppIcons.heart,
        label: bookmarked ? l10n.bookmarkRemove : l10n.bookmarkIllust,
        onSelected: () => unawaited(toggleBookmark(context, bookmarkKey)),
      ),
      DisplayAction(
        icon: AppIcons.edit,
        label: l10n.bookmarkEditTitle,
        enabled: !unsettled,
        onSelected: () => unawaited(
          showBookmarkEditSheet(context, bookmarkKey, title: entity.title),
        ),
      ),
    ],
    if (entity != null)
      DisplayAction(
        icon: AppIcons.download,
        label: l10n.viewerSavePage,
        enabled:
            saveState != IllustPageSaveState.downloading &&
            saveState != IllustPageSaveState.exist,
        onSelected: onSavePage,
      ),
    if (entity != null && pageCount > 1)
      DisplayAction(
        icon: AppIcons.downloading,
        label: l10n.downloadAll,
        onSelected: onDownloadAll,
      ),
    if (entity != null) ...[
      if (isDesktopImageClipboardSupported)
        DisplayAction(
          icon: AppIcons.copy,
          label: l10n.copyOriginalImage,
          onSelected: () => unawaited(
            copyIllustOriginalImageToClipboard(
              context,
              ProviderScope.containerOf(context),
              entity,
              pageIndex: activePage,
            ),
          ),
        ),
      DisplayAction(
        icon: AppIcons.share,
        label: l10n.share,
        onSelected: onShare,
      ),
      DisplayAction(
        icon: AppIcons.link,
        label: l10n.copyLink,
        onSelected: () => unawaited(
          copyToClipboard(
            context,
            'https://www.pixiv.net/artworks/${entity.id}',
            message: l10n.linkCopied,
          ),
        ),
      ),
    ],
    DisplayAction(
      icon: zoomed ? AppIcons.fitScreen : AppIcons.zoomIn,
      label: zoomed ? l10n.viewerFitScreen : l10n.viewerZoomIn,
      onSelected: onToggleZoom,
    ),
    DisplayAction(
      icon: UiIcons.arrowBack,
      label: MaterialLocalizations.of(context).backButtonTooltip,
      onSelected: onBack,
    ),
  ];
}

/// Action tiles at the bottom of the viewer wide info panel: bookmark toggle
/// (with long-press / edit button), download all, and open detail.
class ViewerInfoPanelActions extends ConsumerWidget {
  const ViewerInfoPanelActions({
    super.key,
    required this.entity,
    required this.onSaveAll,
    required this.onOpenDetail,
  });

  final IllustEntity entity;
  final VoidCallback onSaveAll;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final key = BookmarkKey(BookmarkEntityType.illust, entity.id);
    final entry = ref.watch(bookmarkStoreProvider.select((s) => s[key]));
    final bookmarked = entry?.shown ?? false;
    final unsettled = entry?.isUnsettled ?? false;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(bookmarked ? AppIcons.heartFilled : AppIcons.heart),
          title: Text(bookmarked ? l10n.bookmarkRemove : l10n.bookmarkIllust),
          trailing: IconButton(
            tooltip: l10n.bookmarkEditTitle,
            onPressed: unsettled
                ? null
                : () => unawaited(
                    showBookmarkEditSheet(context, key, title: entity.title),
                  ),
            icon: const Icon(AppIcons.edit),
          ),
          onTap: () => unawaited(toggleBookmark(context, key)),
        ),
        ListTile(
          leading: const Icon(AppIcons.download),
          title: Text(l10n.downloadAll),
          onTap: onSaveAll,
        ),
        ListTile(
          leading: const Icon(AppIcons.externalLink),
          title: Text(l10n.viewerOpenDetail),
          onTap: onOpenDetail,
        ),
      ],
    );
  }
}
