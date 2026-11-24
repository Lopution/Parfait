import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../app/clipboard.dart';
import '../../../../app/icons/app_icons.dart';
import '../../../../app/icons/ui_icons.dart';
import '../../../../app/widgets/display_actions.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/platform/image_clipboard.dart';
import '../../../../l10n/context.dart';

/// Pointer context menu for a page inside [DetailPageImage]: page selection or
/// save, desktop original-image copy (FB-16), and copy artwork link.
Future<void> showDetailPageContextMenu(
  BuildContext context, {
  required IllustEntity entity,
  required int pageIndex,
  required Offset position,
  required PointerDeviceKind kind,
  required bool canSelectPages,
  required VoidCallback onSelectPages,
  required VoidCallback onQuickSave,
}) {
  final l10n = context.l10n;
  return showDisplayActions(
    context,
    position: position,
    kind: kind,
    onLongPress: canSelectPages ? onSelectPages : onQuickSave,
    actions: [
      if (canSelectPages)
        DisplayAction(
          icon: UiIcons.checklist,
          label: l10n.downloadSelectPages,
          onSelected: onSelectPages,
        )
      else
        DisplayAction(
          icon: AppIcons.download,
          label: l10n.viewerSavePage,
          onSelected: onQuickSave,
        ),
      if (isDesktopImageClipboardSupported)
        DisplayAction(
          icon: AppIcons.copy,
          label: l10n.copyOriginalImage,
          onSelected: () => unawaited(
            copyIllustOriginalImageToClipboard(
              context,
              ProviderScope.containerOf(context),
              entity,
              pageIndex: pageIndex,
            ),
          ),
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
  );
}
