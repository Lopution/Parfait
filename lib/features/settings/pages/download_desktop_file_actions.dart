import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/icons/app_icons.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/display_actions.dart';
import '../../../core/download/download_task.dart';
import '../../../core/platform/desktop_file_actions.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import 'download_task_presentation.dart';

/// Opens a completed download file or reveals it in the OS file manager on
/// desktop, forwarding any macOS security-scoped bookmark (`DL-14`) and
/// surfacing missing-file or open errors via `deferAppSnackBar`.
Future<void> runDesktopDownloadFileAction(
  BuildContext context,
  WidgetRef ref, {
  required DownloadTaskSnapshot task,
  required String path,
  required bool reveal,
}) async {
  final l10n = context.l10n;
  final showMissing = deferAppSnackBar(context, l10n.downloadFileMissing);
  final showFailed = deferAppSnackBar(context, l10n.downloadOpenFailed);
  final fileActions = ref.read(desktopFileActionsProvider);
  final bookmark = resolveDownloadMacosBookmark(
    task,
    ref.read(downloadDestinationProvider),
  );
  final outcome = reveal
      ? await fileActions.showInFolder(path, macosBookmark: bookmark)
      : await fileActions.openFile(path, macosBookmark: bookmark);
  switch (outcome) {
    case DesktopFileActionResult.opened:
      return;
    case DesktopFileActionResult.notFound:
      showMissing();
    case DesktopFileActionResult.failed:
      showFailed();
  }
}

/// Builds desktop "Open file" and "Show in folder" context-menu actions for a
/// completed download task with a local [localFilePath].
List<DisplayAction> buildDesktopDownloadDisplayActions(
  BuildContext context,
  WidgetRef ref, {
  required DownloadTaskSnapshot task,
  required String? localFilePath,
}) {
  if (localFilePath == null) return const [];
  final l10n = context.l10n;
  return [
    DisplayAction(
      icon: AppIcons.externalLink,
      label: l10n.downloadOpenFile,
      onSelected: () => unawaited(
        runDesktopDownloadFileAction(
          context,
          ref,
          task: task,
          path: localFilePath,
          reveal: false,
        ),
      ),
    ),
    DisplayAction(
      icon: AppIcons.folderOpen,
      label: l10n.downloadShowInFolder,
      onSelected: () => unawaited(
        runDesktopDownloadFileAction(
          context,
          ref,
          task: task,
          path: localFilePath,
          reveal: true,
        ),
      ),
    ),
  ];
}

/// Square artwork thumbnail for a download row or group header.
class DownloadRowThumbnail extends StatelessWidget {
  const DownloadRowThumbnail({
    super.key,
    required this.url,
    required this.size,
  });

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = this.url;
    return ClipRRect(
      borderRadius: FuncShape.control,
      child: SizedBox.square(
        dimension: size,
        child: ColoredBox(
          color: colorScheme.surfaceContainerHighest,
          child: url == null
              ? Icon(AppIcons.illust, color: colorScheme.onSurfaceVariant)
              : PixivImage.feed(url, layoutWidth: size, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

/// Icon + text status line; only the icon carries the status color (R3).
class DownloadRowStatusLine extends StatelessWidget {
  const DownloadRowStatusLine({
    super.key,
    required this.state,
    required this.text,
  });

  final DownloadVisualState state;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          downloadVisualIcon(state),
          size: 16,
          color: downloadVisualIconColor(
            theme.colorScheme,
            FuncSemanticTokens.of(context),
            state,
          ),
        ),
        const SizedBox(width: FuncSpacing.xs),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                .tabular,
          ),
        ),
      ],
    );
  }
}
