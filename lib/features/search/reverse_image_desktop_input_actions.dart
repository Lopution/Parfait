import 'dart:async';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/icons/app_icons.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/desktop_file_drop_target.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../core/platform/image_clipboard.dart';
import '../../core/reverse_image/desktop_image_input.dart';
import '../../core/reverse_image/reverse_image_controller.dart';
import '../../l10n/context.dart';

/// Wraps [child] with desktop `Ctrl/Cmd+V` clipboard paste shortcuts and OS
/// file drag-and-drop handling when [isDesktop] is true.
Widget wrapReverseImageDesktopInputs(
  BuildContext context, {
  required bool isDesktop,
  required Future<void> Function() onPaste,
  required Future<void> Function(List<String> paths) onFilesDropped,
  required Widget child,
}) {
  Widget wrapped = DesktopFileDropTarget(
    hint: context.l10n.reverseImageDropHint,
    icon: AppIcons.imageSearch,
    onFilesDropped: (paths) => unawaited(onFilesDropped(paths)),
    child: child,
  );
  if (isDesktop) {
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;
    wrapped = CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(
          LogicalKeyboardKey.keyV,
          meta: isMac,
          control: !isMac,
        ): () =>
            unawaited(onPaste()),
      },
      child: Focus(autofocus: true, child: wrapped),
    );
  }
  return wrapped;
}

/// Reads an image from the desktop clipboard and feeds it into [controller],
/// surfacing an empty-clipboard prompt or categorized error snackbar.
Future<void> pasteReverseImageFromClipboard(
  BuildContext context,
  WidgetRef ref,
  ReverseImageSearchController controller,
) async {
  final l10n = context.l10n;
  final showEmpty = deferAppSnackBar(context, l10n.reverseImagePasteEmpty);
  final showError = deferErrorSnackBar(
    context,
    action: l10n.searchReverseImage,
  );
  final bytes = await ref.read(desktopImageClipboardReaderProvider)();
  if (!context.mounted) return;
  if (bytes == null || bytes.isEmpty) {
    showEmpty();
    return;
  }
  try {
    await DesktopReverseImageInputPlatform.withStagedClipboardBytes(
      bytes,
      controller.prepare,
    );
  } on Object catch (error, stack) {
    showError(error, stack);
  }
}

/// Validates the first dropped desktop file path and hands it to [controller].
Future<void> prepareDroppedReverseImage(
  BuildContext context,
  ReverseImageSearchController controller,
  List<String> paths,
) async {
  if (paths.isEmpty) return;
  final showError = deferErrorSnackBar(
    context,
    action: context.l10n.searchReverseImage,
  );
  try {
    final reference =
        await DesktopReverseImageInputPlatform.referenceFromFilePath(
          paths.first,
        );
    if (!context.mounted) return;
    await controller.prepare(reference);
  } on Object catch (error, stack) {
    showError(error, stack);
  }
}
