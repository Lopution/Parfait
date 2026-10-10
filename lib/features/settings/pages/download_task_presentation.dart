import 'package:material_ui/material_ui.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../core/download/download_task.dart';
import '../../../core/errors/error_category.dart';
import '../../../core/format/byte_size.dart';
import '../../../l10n/app_localizations.dart';

/// How a download row or group header reads at a glance (design §4.1).
/// The persisted lifecycle folds into these states: `finalizing` reads as
/// processing, `orphaned` as failed, and `retryable` splits into paused vs.
/// retryable on `failureKind`.
enum DownloadVisualState {
  queued,
  running,
  processing,
  canceling,
  succeeded,
  paused,
  retryable,
  failed,
  canceled,
}

DownloadVisualState visualStateOfTask(DownloadTaskSnapshot task) =>
    switch (task.status) {
      DownloadStatus.queued => DownloadVisualState.queued,
      DownloadStatus.running => DownloadVisualState.running,
      DownloadStatus.finalizing => DownloadVisualState.processing,
      DownloadStatus.canceling => DownloadVisualState.canceling,
      DownloadStatus.succeeded => DownloadVisualState.succeeded,
      // A retryable job holding a pause anchor reads 已暂停; any other
      // retryable failure reads 失败 with the warning tone.
      DownloadStatus.retryable =>
        task.failureKind == DownloadFailureKind.paused
            ? DownloadVisualState.paused
            : DownloadVisualState.retryable,
      DownloadStatus.failed => DownloadVisualState.failed,
      DownloadStatus.canceled => DownloadVisualState.canceled,
      DownloadStatus.orphaned => DownloadVisualState.failed,
    };

DownloadVisualState visualStateOfGroup(
  DownloadGroupSnapshot group, {
  required bool everyRetryablePaused,
}) => switch (group.status) {
  DownloadGroupStatus.queued => DownloadVisualState.queued,
  DownloadGroupStatus.running => DownloadVisualState.running,
  DownloadGroupStatus.finalizing => DownloadVisualState.processing,
  DownloadGroupStatus.succeeded => DownloadVisualState.succeeded,
  DownloadGroupStatus.failed => DownloadVisualState.failed,
  DownloadGroupStatus.canceled => DownloadVisualState.canceled,
  // A paused group is dominated by `retryable` children whose
  // failureKind is `paused`; mixed pause/failure still reads failed.
  DownloadGroupStatus.retryable =>
    everyRetryablePaused
        ? DownloadVisualState.paused
        : DownloadVisualState.retryable,
  DownloadGroupStatus.orphaned => DownloadVisualState.failed,
};

/// Localized label — the same copy the old tiles resolved (`downloadFailed`
/// covers retryable/failed/orphaned).
String downloadVisualText(AppLocalizations l10n, DownloadVisualState state) =>
    switch (state) {
      DownloadVisualState.queued => l10n.downloadQueued,
      DownloadVisualState.running => l10n.downloadRunning,
      DownloadVisualState.processing => l10n.downloadProcessing,
      DownloadVisualState.canceling => l10n.downloadCanceling,
      DownloadVisualState.succeeded => l10n.downloadSucceeded,
      DownloadVisualState.paused => l10n.downloadPaused,
      DownloadVisualState.retryable => l10n.downloadFailed,
      DownloadVisualState.failed => l10n.downloadFailed,
      DownloadVisualState.canceled => l10n.downloadCanceled,
    };

/// Status icon; color alone never carries meaning (the text stays).
IconData downloadVisualIcon(DownloadVisualState state) => switch (state) {
  DownloadVisualState.queued => Icons.schedule,
  DownloadVisualState.running => Icons.downloading,
  DownloadVisualState.processing ||
  DownloadVisualState.canceling => Icons.hourglass_top,
  DownloadVisualState.succeeded => Icons.check_circle,
  DownloadVisualState.paused => Icons.pause_circle,
  DownloadVisualState.retryable => Icons.error_outline,
  DownloadVisualState.failed => Icons.error,
  DownloadVisualState.canceled => Icons.block,
};

/// Only the icon picks up the status color (R3). Tinted status *text* fell
/// below 4.5:1 on the page surface in both themes (PRD measurement), so the
/// text stays on `onSurfaceVariant`.
Color downloadVisualIconColor(
  ColorScheme colorScheme,
  FuncSemanticTokens tokens,
  DownloadVisualState state,
) => switch (state) {
  DownloadVisualState.running => colorScheme.primary,
  DownloadVisualState.succeeded => tokens.success,
  DownloadVisualState.paused || DownloadVisualState.retryable => tokens.warning,
  DownloadVisualState.failed => tokens.danger,
  _ => colorScheme.onSurfaceVariant,
};

/// A progress bar renders only while the state is unfinished (R2) —
/// succeeded, paused, retryable, failed and canceled rows show none.
bool downloadVisualShowsProgress(DownloadVisualState state) => switch (state) {
  DownloadVisualState.queued ||
  DownloadVisualState.running ||
  DownloadVisualState.processing ||
  DownloadVisualState.canceling => true,
  _ => false,
};

/// Bar value for a state that shows one: queued pins to `progress ?? 0`,
/// running is indeterminate while the total is unknown, and teardown is
/// indeterminate.
double? downloadProgressValue(DownloadVisualState state, double? progress) =>
    switch (state) {
      DownloadVisualState.queued => progress ?? 0,
      DownloadVisualState.running => progress,
      _ => null,
    };

/// "· info" tail on the status line (design §4.3): a running task shows its
/// percentage — or the downloaded size while the total is unknown — and a
/// finished one shows the file size. `null` renders nothing.
String? downloadTaskStatusDetail(
  DownloadVisualState state,
  DownloadTaskSnapshot task,
) => switch (state) {
  DownloadVisualState.running =>
    task.totalBytes != null
        ? '${((task.progress ?? 0) * 100).floor()}%'
        : formatByteSize(task.receivedBytes),
  DownloadVisualState.succeeded => switch (task.totalBytes ??
      task.receivedBytes) {
    0 => null,
    final bytes => formatByteSize(bytes),
  },
  _ => null,
};

/// Group tail: always the done counter — the only place "已完成 x/y"
/// appears on the header (R4) — plus the percentage while the group is
/// running and its total is known.
String downloadGroupStatusDetail(
  AppLocalizations l10n,
  DownloadVisualState state,
  DownloadGroupSnapshot group,
) {
  final done = l10n.downloadGroupProgress(
    group.succeededCount,
    group.childCount,
  );
  final progress = group.progress;
  if (state == DownloadVisualState.running && progress != null) {
    return '$done · ${(progress * 100).floor()}%';
  }
  return done;
}

/// The group header's single status line (R4): for a finished group the
/// done counter *is* the status — the old card printed 已完成 twice; for
/// every other state the counter trails the status text.
String downloadGroupStatusLine(
  AppLocalizations l10n,
  DownloadVisualState state,
  DownloadGroupSnapshot group,
) {
  final detail = downloadGroupStatusDetail(l10n, state, group);
  if (state == DownloadVisualState.succeeded) return detail;
  return '${downloadVisualText(l10n, state)} · $detail';
}

/// Localized failure reason for a terminal/retryable row (C8/D1): the
/// five kinds with a generic meaning borrow the shared category sentence,
/// the download-only kinds (permission/resource/ownership) get their own
/// copy, and `unknown` maps through the category table. `canceled` and
/// `paused` are not errors — the row shows no reason for them.
String? downloadFailureReasonText(
  AppLocalizations l10n,
  DownloadFailureKind? kind,
) => switch (kind) {
  null || DownloadFailureKind.canceled || DownloadFailureKind.paused => null,
  DownloadFailureKind.permission => l10n.downloadFailurePermission,
  DownloadFailureKind.resource => l10n.downloadFailureResource,
  DownloadFailureKind.ownership => l10n.downloadFailureOwnership,
  final k => errorCategoryTextL10n(l10n, categorizeDownloadFailure(k)),
};

/// Row title: the work title the submission carried, else the generated
/// file name (records predating these fields and un-owned submissions have
/// no title).
String downloadTaskTitle(DownloadTaskSnapshot task) {
  final title = task.submission?.request.title;
  if (title != null && title.isNotEmpty) return title;
  return task.displayName;
}

/// "第 2/3 页"-style label for a multi-page submission; null for
/// single-page works and for records that predate the persisted page count.
String? downloadTaskPageLabel(
  AppLocalizations l10n,
  DownloadTaskSnapshot task,
) {
  final totalPages = task.submission?.request.totalPages;
  if (totalPages == null || totalPages <= 1) return null;
  return l10n.downloadTaskPageLabel(task.pageIndex + 1, totalPages);
}

/// Artist under the row title; absent metadata renders no line.
String? downloadTaskSubtitle(DownloadTaskSnapshot task) {
  final artist = task.submission?.request.artist;
  if (artist != null && artist.isNotEmpty) return artist;
  return null;
}

/// Group title (R4): a one-work group takes the work's title; a set by one
/// artist reads "Works by `artist`"; anything else falls back to the plain
/// "batch · N items" copy.
String downloadGroupRowTitle(
  AppLocalizations l10n,
  List<DownloadTaskSnapshot> children,
  int count,
) {
  if (children.isNotEmpty) {
    final first = children.first.submission?.request;
    if (children.every((task) => task.illustId == children.first.illustId)) {
      final title = first?.title;
      if (title != null && title.isNotEmpty) return title;
    } else {
      final artist = first?.artist;
      if (artist != null &&
          artist.isNotEmpty &&
          children.every((task) => task.submission?.request.artist == artist)) {
        return l10n.downloadGroupAuthorTitle(artist);
      }
    }
  }
  return l10n.downloadGroupTitle(count);
}

/// Line under the group title: the author for a one-work group; an
/// author-works group has no second line (the artist is in the title).
String? downloadGroupSubtitle(List<DownloadTaskSnapshot> children) {
  if (children.isEmpty) return null;
  if (!children.every((task) => task.illustId == children.first.illustId)) {
    return null;
  }
  final artist = children.first.submission?.request.artist;
  if (artist != null && artist.isNotEmpty) return artist;
  return null;
}
