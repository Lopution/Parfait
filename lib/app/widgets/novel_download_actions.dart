import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/localnovel/local_novel_repository.dart';
import '../../core/novel/novel_download_coordinator.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/share/share_service.dart' show shareOriginOf;
import '../../l10n/app_localizations.dart';
import '../../l10n/context.dart';
import '../haptics/app_haptics.dart';
import 'app_snack_bar.dart';
import 'errors/error_details.dart';

/// Saves a single Pixiv [novel] into the offline library with feedback.
Future<void> savePixivNovelOfflineAction(
  BuildContext context,
  WidgetRef ref,
  NovelEntity novel,
) async {
  final l10n = context.l10n;
  final present = deferAppSnackBarPresenter(context);
  final reportFailure = deferErrorSnackBar(
    context,
    action: l10n.novelSaveOfflineFailed,
  );
  try {
    await ref.read(novelDownloadCoordinatorProvider).saveNovelOffline(novel);
    AppHaptics.success();
    present(l10n.novelSavedOffline);
  } on Object catch (error, stack) {
    AppHaptics.error();
    reportFailure(error, stack);
  }
}

/// Exports a single Pixiv [novel] as UTF-8 `.txt` (DownloadManager on desktop /
/// Android SAF, SharePlus on iOS, or an actionable folder notice on Android
/// album destinations).
Future<void> exportPixivNovelTxtAction(
  BuildContext context,
  WidgetRef ref,
  NovelEntity novel, {
  int? seriesOrder,
  int? seriesTotal,
}) async {
  final l10n = context.l10n;
  final origin = shareOriginOf(context);
  final present = deferAppSnackBarPresenter(context);
  final reportFailure = deferErrorSnackBar(
    context,
    action: l10n.novelExportTxtFailed,
  );
  try {
    final outcome = await ref
        .read(novelDownloadCoordinatorProvider)
        .exportNovelTxt(
          novel,
          seriesOrder: seriesOrder,
          seriesTotal: seriesTotal,
          sharePositionOrigin: origin,
        );
    _presentExportOutcome(outcome, l10n: l10n, present: present);
  } on Object catch (error, stack) {
    AppHaptics.error();
    reportFailure(error, stack);
  }
}

/// Paginates and caches all viewable chapters of [seriesId] into the offline
/// library as one merged work, reporting skipped unavailable chapters.
Future<void> savePixivNovelSeriesOfflineAction(
  BuildContext context,
  WidgetRef ref,
  int seriesId,
) async {
  final l10n = context.l10n;
  final present = deferAppSnackBarPresenter(context);
  final reportFailure = deferErrorSnackBar(
    context,
    action: l10n.novelSaveOfflineFailed,
  );
  try {
    final result = await ref
        .read(novelDownloadCoordinatorProvider)
        .saveSeriesOffline(seriesId);
    if (result.processed == 0) {
      present(l10n.novelSeriesNoViewableChapters);
      return;
    }
    AppHaptics.success();
    present(
      result.skipped > 0
          ? l10n.novelSeriesSavedWithSkipped(result.processed, result.skipped)
          : l10n.novelSavedOffline,
    );
  } on Object catch (error, stack) {
    AppHaptics.error();
    reportFailure(error, stack);
  }
}

/// Exports a Pixiv novel series as UTF-8 `.txt` (merged or per-chapter).
Future<void> exportPixivNovelSeriesTxtAction(
  BuildContext context,
  WidgetRef ref,
  int seriesId, {
  required bool merged,
}) async {
  final l10n = context.l10n;
  final origin = shareOriginOf(context);
  final present = deferAppSnackBarPresenter(context);
  final reportFailure = deferErrorSnackBar(
    context,
    action: l10n.novelExportTxtFailed,
  );
  try {
    final result = await ref
        .read(novelDownloadCoordinatorProvider)
        .exportSeriesTxt(seriesId, merged: merged, sharePositionOrigin: origin);
    if (result.outcome == NovelTxtExportOutcome.androidFolderRequired) {
      present(l10n.novelExportAndroidFolderRequired);
      return;
    }
    if (result.processed == 0) {
      present(l10n.novelSeriesNoViewableChapters);
      return;
    }
    AppHaptics.success();
    if (result.outcome == NovelTxtExportOutcome.shared) {
      present(l10n.novelExportTxtShared);
    } else if (result.skipped > 0) {
      present(
        l10n.novelSeriesExportQueuedWithSkipped(
          result.processed,
          result.skipped,
        ),
      );
    } else {
      present(l10n.novelExportTxtQueued);
    }
  } on Object catch (error, stack) {
    AppHaptics.error();
    reportFailure(error, stack);
  }
}

/// Exports an existing [LocalNovel] row as a UTF-8 `.txt` download or iOS
/// share.
Future<void> exportLocalNovelTxtAction(
  BuildContext context,
  WidgetRef ref,
  LocalNovel novel,
) async {
  final l10n = context.l10n;
  final origin = shareOriginOf(context);
  final present = deferAppSnackBarPresenter(context);
  final reportFailure = deferErrorSnackBar(
    context,
    action: l10n.novelExportTxtFailed,
  );
  try {
    final outcome = await ref
        .read(novelDownloadCoordinatorProvider)
        .exportLocalNovelTxt(novel, sharePositionOrigin: origin);
    _presentExportOutcome(outcome, l10n: l10n, present: present);
  } on Object catch (error, stack) {
    AppHaptics.error();
    reportFailure(error, stack);
  }
}

void _presentExportOutcome(
  NovelTxtExportOutcome outcome, {
  required AppLocalizations l10n,
  required void Function(String message) present,
}) {
  switch (outcome) {
    case NovelTxtExportOutcome.androidFolderRequired:
      present(l10n.novelExportAndroidFolderRequired);
    case NovelTxtExportOutcome.shared:
      AppHaptics.success();
      present(l10n.novelExportTxtShared);
    case NovelTxtExportOutcome.queued:
      AppHaptics.success();
      present(l10n.novelExportTxtQueued);
  }
}
