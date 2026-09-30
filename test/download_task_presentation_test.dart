import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/theme/func_semantic_tokens.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/core/download/download_request.dart';
import 'package:pixiv_func/core/download/download_task.dart';
import 'package:pixiv_func/features/settings/pages/download_task_presentation.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'support/contrast.dart';

DownloadTaskSnapshot _task({
  int illustId = 7,
  int pageIndex = 0,
  DownloadStatus status = DownloadStatus.queued,
  DownloadFailureKind? failureKind,
  int receivedBytes = 0,
  int? totalBytes,
  String? error,
  String? title,
  String? artist,
  int? totalPages,
  String? thumbnailUrl,
}) {
  final request = DownloadRequest(
    illustId: illustId,
    pageIndex: pageIndex,
    url: Uri.parse('https://i.pximg.net/img/${illustId}_p$pageIndex.jpg'),
    target: DownloadTarget.illustPage,
    title: title,
    artist: artist,
    totalPages: totalPages,
    thumbnailUrl: thumbnailUrl,
  );
  return DownloadTaskSnapshot(
    id: 'job-$illustId-$pageIndex',
    illustId: illustId,
    pageIndex: pageIndex,
    url: request.url,
    target: request.target.name,
    displayName: request.displayName,
    status: status,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
    error: error,
    failureKind: failureKind,
    submission: DownloadSubmissionSnapshot(
      snapshotId: 'sub-$illustId-$pageIndex',
      jobId: 'job-$illustId-$pageIndex',
      groupId: null,
      request: request,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 9, 29),
    ),
  );
}

DownloadGroupSnapshot _group({
  DownloadGroupStatus status = DownloadGroupStatus.running,
  int childCount = 2,
  int succeededCount = 0,
  int receivedBytes = 0,
  int? totalBytes,
}) {
  final request = DownloadRequest(
    illustId: 7,
    pageIndex: 0,
    url: Uri.parse('https://i.pximg.net/img/7_p0.jpg'),
    target: DownloadTarget.illustPage,
  );
  return DownloadGroupSnapshot(
    id: 'group-1',
    jobIds: [for (var i = 0; i < childCount; i++) 'job-7-$i'],
    submission: DownloadSubmissionSnapshot(
      snapshotId: 'sub-group',
      jobId: 'job-7-0',
      groupId: 'group-1',
      request: request,
      accountId: 'account-a',
      submittedAt: DateTime.utc(2026, 9, 29),
    ),
    status: status,
    childCount: childCount,
    succeededCount: succeededCount,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
  );
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('zh'));
  final light = replicaTheme(Brightness.light);
  final dark = replicaTheme(Brightness.dark);
  final lightTokens = light.extension<FuncSemanticTokens>()!;
  final darkTokens = dark.extension<FuncSemanticTokens>()!;

  group('visual state mapping (design §4.1)', () {
    test('task statuses fold into visual states', () {
      final cases = {
        DownloadStatus.queued: DownloadVisualState.queued,
        DownloadStatus.running: DownloadVisualState.running,
        DownloadStatus.finalizing: DownloadVisualState.processing,
        DownloadStatus.canceling: DownloadVisualState.canceling,
        DownloadStatus.succeeded: DownloadVisualState.succeeded,
        DownloadStatus.failed: DownloadVisualState.failed,
        DownloadStatus.canceled: DownloadVisualState.canceled,
        DownloadStatus.orphaned: DownloadVisualState.failed,
      };
      for (final entry in cases.entries) {
        expect(
          visualStateOfTask(_task(status: entry.key)),
          entry.value,
          reason: '${entry.key} should read as ${entry.value}',
        );
      }
      // retryable splits on failureKind: a pause anchor is "paused".
      expect(
        visualStateOfTask(
          _task(
            status: DownloadStatus.retryable,
            failureKind: DownloadFailureKind.paused,
          ),
        ),
        DownloadVisualState.paused,
      );
      expect(
        visualStateOfTask(
          _task(
            status: DownloadStatus.retryable,
            failureKind: DownloadFailureKind.network,
          ),
        ),
        DownloadVisualState.retryable,
      );
    });

    test('group statuses fold into visual states', () {
      final cases = {
        DownloadGroupStatus.queued: DownloadVisualState.queued,
        DownloadGroupStatus.running: DownloadVisualState.running,
        DownloadGroupStatus.finalizing: DownloadVisualState.processing,
        DownloadGroupStatus.succeeded: DownloadVisualState.succeeded,
        DownloadGroupStatus.failed: DownloadVisualState.failed,
        DownloadGroupStatus.canceled: DownloadVisualState.canceled,
        DownloadGroupStatus.orphaned: DownloadVisualState.failed,
      };
      for (final entry in cases.entries) {
        expect(
          visualStateOfGroup(
            _group(status: entry.key),
            everyRetryablePaused: false,
          ),
          entry.value,
          reason: '${entry.key} should read as ${entry.value}',
        );
      }
      expect(
        visualStateOfGroup(
          _group(status: DownloadGroupStatus.retryable),
          everyRetryablePaused: true,
        ),
        DownloadVisualState.paused,
      );
      expect(
        visualStateOfGroup(
          _group(status: DownloadGroupStatus.retryable),
          everyRetryablePaused: false,
        ),
        DownloadVisualState.retryable,
      );
    });
  });

  group('status text, icon and color (design §4.2)', () {
    test('every visual state keeps its localized text', () {
      final expected = {
        DownloadVisualState.queued: l10n.downloadQueued,
        DownloadVisualState.running: l10n.downloadRunning,
        DownloadVisualState.processing: l10n.downloadProcessing,
        DownloadVisualState.canceling: l10n.downloadCanceling,
        DownloadVisualState.succeeded: l10n.downloadSucceeded,
        DownloadVisualState.paused: l10n.downloadPaused,
        DownloadVisualState.retryable: l10n.downloadFailed,
        DownloadVisualState.failed: l10n.downloadFailed,
        DownloadVisualState.canceled: l10n.downloadCanceled,
      };
      for (final state in DownloadVisualState.values) {
        expect(downloadVisualText(l10n, state), expected[state]);
      }
    });

    test('icon and icon color follow the state table', () {
      final scheme = light.colorScheme;
      final tokens = lightTokens;
      Color iconColor(DownloadVisualState state) =>
          downloadVisualIconColor(scheme, tokens, state);

      expect(downloadVisualIcon(DownloadVisualState.queued), Icons.schedule);
      expect(
        downloadVisualIcon(DownloadVisualState.running),
        Icons.downloading,
      );
      expect(
        downloadVisualIcon(DownloadVisualState.processing),
        Icons.hourglass_top,
      );
      expect(
        downloadVisualIcon(DownloadVisualState.canceling),
        Icons.hourglass_top,
      );
      expect(
        downloadVisualIcon(DownloadVisualState.succeeded),
        Icons.check_circle,
      );
      expect(
        downloadVisualIcon(DownloadVisualState.paused),
        Icons.pause_circle,
      );
      expect(
        downloadVisualIcon(DownloadVisualState.retryable),
        Icons.error_outline,
      );
      expect(downloadVisualIcon(DownloadVisualState.failed), Icons.error);
      expect(downloadVisualIcon(DownloadVisualState.canceled), Icons.block);

      expect(iconColor(DownloadVisualState.running), scheme.primary);
      expect(iconColor(DownloadVisualState.succeeded), tokens.success);
      expect(iconColor(DownloadVisualState.paused), tokens.warning);
      expect(iconColor(DownloadVisualState.retryable), tokens.warning);
      expect(iconColor(DownloadVisualState.failed), tokens.danger);
      for (final state in [
        DownloadVisualState.queued,
        DownloadVisualState.processing,
        DownloadVisualState.canceling,
        DownloadVisualState.canceled,
      ]) {
        expect(
          iconColor(state),
          scheme.onSurfaceVariant,
          reason: '$state icon stays on the secondary color',
        );
      }
    });

    test('progress bar only renders for unfinished states', () {
      final shown = {
        DownloadVisualState.queued,
        DownloadVisualState.running,
        DownloadVisualState.processing,
        DownloadVisualState.canceling,
      };
      for (final state in DownloadVisualState.values) {
        expect(
          downloadVisualShowsProgress(state),
          shown.contains(state),
          reason: '$state progress visibility',
        );
      }
      expect(
        downloadProgressValue(DownloadVisualState.queued, null),
        0,
        reason: 'a queued row with no bytes pins to zero',
      );
      expect(
        downloadProgressValue(DownloadVisualState.running, null),
        isNull,
        reason: 'unknown total is indeterminate',
      );
      expect(downloadProgressValue(DownloadVisualState.running, 0.4), 0.4);
      expect(
        downloadProgressValue(DownloadVisualState.processing, 0.9),
        isNull,
        reason: 'teardown is indeterminate',
      );
    });
  });

  group('status text contrast (R3)', () {
    test('secondary text keeps 4.5:1 on page and container surfaces', () {
      for (final (theme, tokens) in [
        (light, lightTokens),
        (dark, darkTokens),
      ]) {
        final scheme = theme.colorScheme;
        // Status text is rendered in onSurfaceVariant — verify it on the
        // page color and on the group container color it sits inside.
        for (final background in [scheme.surface, scheme.surfaceContainer]) {
          expect(
            contrastRatio(scheme.onSurfaceVariant, background),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} onSurfaceVariant on $background',
          );
        }
        // Semantic caption color agrees with the resolved scheme role.
        expect(tokens.caption.color, scheme.onSurfaceVariant);
      }
    });
  });

  group('titles and details (design §4.3/§4.4)', () {
    test('task title prefers the work title and falls back to the file', () {
      expect(downloadTaskTitle(_task(title: '星空')), '星空');
      expect(
        downloadTaskTitle(_task(title: '')),
        '7_p0.jpg',
        reason: 'an empty title falls back to the file name',
      );
      expect(downloadTaskTitle(_task()), '7_p0.jpg');
    });

    test('page label only appears for a multi-page submission', () {
      expect(
        downloadTaskPageLabel(l10n, _task(pageIndex: 1, totalPages: 3)),
        '第 2/3 页',
      );
      expect(downloadTaskPageLabel(l10n, _task(totalPages: 1)), isNull);
      expect(downloadTaskPageLabel(l10n, _task()), isNull);
    });

    test('task subtitle is the artist when present', () {
      expect(downloadTaskSubtitle(_task(artist: '画师')), '画师');
      expect(downloadTaskSubtitle(_task(artist: '')), isNull);
      expect(downloadTaskSubtitle(_task()), isNull);
    });

    test('status detail carries percent, size or nothing', () {
      expect(
        downloadTaskStatusDetail(
          DownloadVisualState.running,
          _task(
            status: DownloadStatus.running,
            receivedBytes: 4,
            totalBytes: 10,
          ),
        ),
        '40%',
      );
      expect(
        downloadTaskStatusDetail(
          DownloadVisualState.running,
          _task(status: DownloadStatus.running, receivedBytes: 2048),
        ),
        '2.0 KiB',
        reason: 'unknown total shows the downloaded size',
      );
      expect(
        downloadTaskStatusDetail(
          DownloadVisualState.succeeded,
          _task(
            status: DownloadStatus.succeeded,
            receivedBytes: 3,
            totalBytes: 3,
          ),
        ),
        '3 B',
      );
      expect(
        downloadTaskStatusDetail(
          DownloadVisualState.succeeded,
          _task(status: DownloadStatus.succeeded),
        ),
        isNull,
        reason: 'zero-byte records show no size',
      );
      expect(
        downloadTaskStatusDetail(DownloadVisualState.failed, _task()),
        isNull,
      );
    });

    test('group detail is the done counter plus running percentage', () {
      expect(
        downloadGroupStatusDetail(
          l10n,
          DownloadVisualState.succeeded,
          _group(status: DownloadGroupStatus.succeeded, succeededCount: 2),
        ),
        '已完成 2/2',
      );
      expect(
        downloadGroupStatusDetail(
          l10n,
          DownloadVisualState.running,
          _group(receivedBytes: 5, totalBytes: 10),
        ),
        '已完成 0/2 · 50%',
      );
      expect(
        downloadGroupStatusDetail(l10n, DownloadVisualState.running, _group()),
        '已完成 0/2',
        reason: 'unknown group total drops the percentage',
      );
    });

    test('group status line folds the counter into one line', () {
      // A finished group reads "已完成 2/2" once — the old card printed
      // 已完成 on both the status row and the counter row (R4).
      expect(
        downloadGroupStatusLine(
          l10n,
          DownloadVisualState.succeeded,
          _group(status: DownloadGroupStatus.succeeded, succeededCount: 2),
        ),
        '已完成 2/2',
      );
      expect(
        downloadGroupStatusLine(
          l10n,
          DownloadVisualState.running,
          _group(receivedBytes: 5, totalBytes: 10),
        ),
        '下载中 · 已完成 0/2 · 50%',
      );
      expect(
        downloadGroupStatusLine(
          l10n,
          DownloadVisualState.paused,
          _group(status: DownloadGroupStatus.retryable),
        ),
        '已暂停 · 已完成 0/2',
      );
    });

    test('group title reads the work, the author, or the item count', () {
      final workPages = [
        _task(illustId: 7, pageIndex: 0, title: '星空', artist: '画师'),
        _task(illustId: 7, pageIndex: 1, title: '星空', artist: '画师'),
      ];
      expect(downloadGroupRowTitle(l10n, workPages, 2), '星空');
      expect(downloadGroupSubtitle(workPages), '画师');

      final authorWorks = [
        _task(illustId: 7, title: 'a', artist: '画师'),
        _task(illustId: 8, title: 'b', artist: '画师'),
      ];
      expect(downloadGroupRowTitle(l10n, authorWorks, 2), '画师 的作品');
      expect(
        downloadGroupSubtitle(authorWorks),
        isNull,
        reason: 'the artist already is the title',
      );

      // Anonymous submissions (the _req shape the page tests build) keep
      // the plain item-count title.
      final anonymous = [_task(), _task(illustId: 8)];
      expect(downloadGroupRowTitle(l10n, anonymous, 2), '批量下载 · 2 项');
      expect(downloadGroupRowTitle(l10n, const [], 3), '批量下载 · 3 项');
    });
  });

  group('failure reason text (C8/D1, design §2.4 第 4 类)', () {
    test('every failureKind maps to its localized reason', () {
      final expectations = <DownloadFailureKind?, String>{
        DownloadFailureKind.auth: l10n.errorUnauthorized,
        DownloadFailureKind.rateLimit: l10n.errorRateLimited,
        DownloadFailureKind.network: l10n.errorNetwork,
        DownloadFailureKind.storage: l10n.errorStorage,
        DownloadFailureKind.decode: l10n.errorParse,
        DownloadFailureKind.permission: l10n.downloadFailurePermission,
        DownloadFailureKind.resource: l10n.downloadFailureResource,
        DownloadFailureKind.ownership: l10n.downloadFailureOwnership,
        DownloadFailureKind.unknown: l10n.errorUnknown,
      };
      for (final entry in expectations.entries) {
        expect(
          downloadFailureReasonText(l10n, entry.key),
          entry.value,
          reason: '${entry.key} must read "${entry.value}"',
        );
      }
      // canceled and paused are not failures; an absent kind has nothing
      // to map (the row falls back to the generic category of the error).
      for (final kind in [
        null,
        DownloadFailureKind.canceled,
        DownloadFailureKind.paused,
      ]) {
        expect(
          downloadFailureReasonText(l10n, kind),
          isNull,
          reason: '$kind shows no failure reason',
        );
      }
    });
  });
}
