import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/feed/feed_states.dart';
import '../../../core/download/download_manager.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class DownloadTasksPage extends ConsumerStatefulWidget {
  const DownloadTasksPage({super.key});

  @override
  ConsumerState<DownloadTasksPage> createState() => _DownloadTasksPageState();
}

class _DownloadTasksPageState extends ConsumerState<DownloadTasksPage> {
  late final DownloadManager _manager;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(downloadManagerProvider);
    _changes = _manager.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(
      _manager.recover().whenComplete(() {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _manager.tasks;
    final groups = _manager.groups;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.downloaderSettings)),
      body: tasks.isEmpty
          ? FeedEmpty(title: context.l10n.downloadTasksEmpty)
          : settingsNarrowBody(
              ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(context.l10n.downloaderSettingsHint),
                  ),
                  for (final group in groups)
                    _DownloadGroupSection(group: group, manager: _manager),
                  for (final task in tasks)
                    _DownloadTaskTile(task: task, manager: _manager),
                ],
              ),
            ),
    );
  }
}

/// Aggregate section for one submission group (D8 batch): combined progress
/// plus group-level pause/resume/cancel instead of per-tile hunting.
class _DownloadGroupSection extends StatelessWidget {
  const _DownloadGroupSection({required this.group, required this.manager});

  final DownloadGroupSnapshot group;
  final DownloadManager manager;

  bool get _everyRetryablePaused {
    final retryable = [
      for (final id in group.jobIds)
        if (manager.taskById(id) case final task?
            when task.status == DownloadStatus.retryable)
          task,
    ];
    return retryable.isNotEmpty &&
        retryable.every(
          (task) => task.failureKind == DownloadFailureKind.paused,
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canAct =
        group.status == DownloadGroupStatus.queued ||
        group.status == DownloadGroupStatus.running;
    final canResume =
        group.status == DownloadGroupStatus.retryable ||
        group.status == DownloadGroupStatus.failed ||
        group.status == DownloadGroupStatus.canceled;
    return Card(
      child: ListTile(
        title: Text(l10n.downloadGroupTitle(group.childCount)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_statusText(context)),
            LinearProgressIndicator(value: group.progress),
            Text(
              l10n.downloadGroupProgress(
                group.succeededCount,
                group.childCount,
              ),
            ),
          ],
        ),
        trailing: canAct
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: l10n.pauseDownload,
                    icon: const Icon(Icons.pause),
                    onPressed: () => unawaited(manager.pauseGroup(group.id)),
                  ),
                  IconButton(
                    tooltip: l10n.cancelDownload,
                    icon: const Icon(Icons.close),
                    onPressed: () => unawaited(manager.cancelGroup(group.id)),
                  ),
                ],
              )
            : canResume
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: l10n.resumeDownload,
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => manager.resumeGroup(group.id),
                  ),
                  IconButton(
                    tooltip: l10n.cancelDownload,
                    icon: const Icon(Icons.close),
                    onPressed: () => unawaited(manager.cancelGroup(group.id)),
                  ),
                ],
              )
            : Icon(
                group.status == DownloadGroupStatus.succeeded
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
              ),
      ),
    );
  }

  String _statusText(BuildContext context) {
    final l10n = context.l10n;
    return switch (group.status) {
      DownloadGroupStatus.queued => l10n.downloadQueued,
      DownloadGroupStatus.running => l10n.downloadRunning,
      DownloadGroupStatus.finalizing => l10n.downloadRunning,
      DownloadGroupStatus.succeeded => l10n.downloadSucceeded,
      DownloadGroupStatus.failed => l10n.downloadFailed,
      DownloadGroupStatus.canceled => l10n.downloadCanceled,
      // A paused group is dominated by `retryable` children whose
      // failureKind is `paused`; mixed pause/failure still reads failed.
      DownloadGroupStatus.retryable =>
        _everyRetryablePaused ? l10n.downloadPaused : l10n.downloadFailed,
      DownloadGroupStatus.orphaned => l10n.downloadFailed,
    };
  }
}

class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({required this.task, required this.manager});

  final DownloadTaskSnapshot task;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final progress = task.progress;
    return Card(
      child: ListTile(
        title: Text(task.displayName, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_downloadStatusText(context)),
            LinearProgressIndicator(value: progress),
            if (task.error != null &&
                task.failureKind != DownloadFailureKind.paused)
              Text(task.error!),
          ],
        ),
        trailing: switch (task.status) {
          // A paused (retryable) task may still be canceled — cancel is
          // what discards the preserved partial output.
          DownloadStatus.queued ||
          DownloadStatus.running ||
          DownloadStatus.canceling ||
          DownloadStatus.retryable => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (task.status != DownloadStatus.canceling)
                IconButton(
                  tooltip: task.status == DownloadStatus.retryable
                      ? context.l10n.retryDownload
                      : context.l10n.pauseDownload,
                  icon: Icon(
                    task.status == DownloadStatus.retryable
                        ? Icons.refresh
                        : Icons.pause,
                  ),
                  onPressed: () => task.status == DownloadStatus.retryable
                      ? manager.retry(task.id)
                      : unawaited(manager.pause(task.id)),
                ),
              IconButton(
                tooltip: context.l10n.cancelDownload,
                icon: const Icon(Icons.close),
                onPressed: () => manager.cancel(task.id),
              ),
            ],
          ),
          DownloadStatus.failed || DownloadStatus.canceled => IconButton(
            tooltip: context.l10n.retryDownload,
            icon: const Icon(Icons.refresh),
            onPressed: () => manager.retry(task.id),
          ),
          _ => Icon(
            task.status == DownloadStatus.succeeded
                ? Icons.check_circle_outline
                : Icons.info_outline,
          ),
        },
      ),
    );
  }

  String _downloadStatusText(BuildContext context) {
    return switch (task.status) {
      DownloadStatus.queued => context.l10n.downloadQueued,
      DownloadStatus.running => context.l10n.downloadRunning,
      DownloadStatus.finalizing => context.l10n.downloadRunning,
      DownloadStatus.canceling => context.l10n.downloadCanceling,
      DownloadStatus.succeeded => context.l10n.downloadSucceeded,
      DownloadStatus.failed => context.l10n.downloadFailed,
      DownloadStatus.canceled => context.l10n.downloadCanceled,
      DownloadStatus.retryable =>
        task.failureKind == DownloadFailureKind.paused
            ? context.l10n.downloadPaused
            : context.l10n.downloadFailed,
      DownloadStatus.orphaned => context.l10n.downloadFailed,
    };
  }
}
