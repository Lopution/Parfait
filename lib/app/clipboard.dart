import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/entity/illust_entity.dart';
import '../core/illust/illust_detail_controller.dart';
import '../core/image/image_worker_providers.dart';
import '../core/image/lane_permit_gate.dart';
import '../core/platform/image_clipboard.dart';
import '../l10n/context.dart';
import 'haptics/app_haptics.dart';
import 'widgets/app_snack_bar.dart';

/// The UI's only clipboard write: copies [text], confirms with the success
/// haptic and shows [message]. A failed write throws before either, so the
/// user is never told a copy landed when it did not.
Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  required String message,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  AppHaptics.success();
  if (context.mounted) showAppSnackBar(context, message);
}

/// Fetches page [pageIndex] of [entity] at original quality and copies its image
/// payload to the desktop OS clipboard, showing toast + haptic feedback.
Future<void> copyIllustOriginalImageToClipboard(
  BuildContext context,
  ProviderContainer container,
  IllustEntity entity, {
  int pageIndex = 0,
}) async {
  final l10n = context.l10n;
  final showCopied = deferAppSnackBar(context, l10n.imageCopiedToClipboard);
  final showFailed = deferAppSnackBar(context, l10n.imageCopyFailed);
  try {
    var url = entity.originalUrlAt(pageIndex);
    if (url == null || url.isEmpty) {
      final detail = await container
          .read(illustDetailRepositoryProvider)
          .fetch(entity.id);
      url = detail.originalUrlAt(pageIndex);
    }
    if (url == null || url.isEmpty) {
      AppHaptics.error();
      showFailed();
      return;
    }
    final fetched = await container
        .read(imageWorkerProvider)
        .fetch(url, priority: ImageFetchPriority.foreground);
    final copied = await ImageClipboard.copyImageFile(fetched.file.path);
    if (!copied) {
      AppHaptics.error();
      showFailed();
      return;
    }
    AppHaptics.success();
    showCopied();
  } catch (_) {
    AppHaptics.error();
    showFailed();
  }
}
