import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/haptics/app_haptics.dart';
import '../../app/navigation/route_facade.dart'
    show showDownloadSubmittedSnackBar;
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/errors/error_details.dart' show deferErrorSnackBar;
import '../../core/download/download_task.dart' show DownloadGroupSubmission;
import '../../core/entity/illust_entity.dart';
import '../../core/illust/illust_download_controller.dart';
import '../../core/share/share_service.dart';
import '../../l10n/context.dart';
import 'detail/ugoira_export_action.dart';

/// Submits every page of [entity] through [illustDownloadControllerProvider]
/// (dedupe-safe) — or launches app-level GIF export for ugoira works — and
/// surfaces either submission feedback or an error prompt.
Future<void> downloadAllIllustPages(
  BuildContext context,
  WidgetRef ref,
  IllustEntity entity,
) async {
  if (entity.isUgoira) {
    await startUgoiraGifExport(context, ref, entity.id);
    return;
  }
  final reportFailure = deferErrorSnackBar(
    context,
    action: context.l10n.downloadSubmissionFailed,
  );
  final DownloadGroupSubmission submission;
  try {
    submission = await ref
        .read(illustDownloadControllerProvider)
        .downloadAll(entity);
  } catch (error, stack) {
    AppHaptics.error();
    reportFailure(error, stack);
    return;
  }
  if (!context.mounted) return;
  showDownloadSubmittedSnackBar(
    context,
    alreadyQueued: submission.group == null,
  );
}

/// Shares [entity]'s Pixiv URL, anchoring the platform popover to [context],
/// and shows a prompt when sharing falls back to copying the link.
Future<void> shareIllust(
  BuildContext context,
  WidgetRef ref,
  IllustEntity entity, {
  Rect? sharePositionOrigin,
  Offset? globalPosition,
}) async {
  final origin = sharePositionOrigin != null
      ? clampShareOrigin(context, sharePositionOrigin)
      : globalPosition != null
      ? shareOriginAt(context, globalPosition)
      : shareOriginOf(context);
  final outcome = await ref
      .read(shareServiceProvider)
      .share(
        SharePayload.illust(
          id: entity.id,
          title: entity.title,
          author: entity.user.name,
        ),
        sharePositionOrigin: origin,
      );
  if (outcome == ShareOutcome.copiedToClipboard && context.mounted) {
    showAppSnackBar(context, context.l10n.linkCopied);
  }
}
