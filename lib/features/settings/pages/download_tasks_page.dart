import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/routes.dart';
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
    // Grouped children render under their group card (indented); only
    // ungrouped tasks stay in the flat list — a child must not appear at
    // both levels.
    final groupedJobIds = {for (final group in groups) ...group.jobIds};
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
                    if (!groupedJobIds.contains(task.id))
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
    final children = [for (final id in group.jobIds) ?manager.taskById(id)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
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
            trailing: _groupActions(context, children),
          ),
        ),
        // Child rows indent under the group header — the parent/child
        // hierarchy is spatial, not just textual.
        if (children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Column(
              children: [
                for (final child in children)
                  _DownloadTaskTile(task: child, manager: manager),
              ],
            ),
          ),
      ],
    );
  }

  /// Group-level mapping mirrors the per-task table: queued/running
  /// pause+cancel, retryable/failed/canceled resume+cancel, succeeded
  /// offers 查看 (first succeeded work) + 移除; a fully-terminal orphaned
  /// group can only be removed.
  Widget _groupActions(
    BuildContext context,
    List<DownloadTaskSnapshot> children,
  ) {
    final l10n = context.l10n;
    void dismissChildren() {
      for (final child in children) {
        manager.dismiss(child.id);
      }
    }

    return switch (group.status) {
      DownloadGroupStatus.queued || DownloadGroupStatus.running => Row(
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
      ),
      DownloadGroupStatus.retryable ||
      DownloadGroupStatus.failed ||
      DownloadGroupStatus.canceled => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            // A paused group continues (resume anchors); a failed or
            // canceled group retries — same resumeGroup entry, the verb
            // follows the dominant child state.
            tooltip: group.status == DownloadGroupStatus.retryable
                ? l10n.resumeDownload
                : l10n.retryDownload,
            icon: Icon(
              group.status == DownloadGroupStatus.retryable
                  ? Icons.play_arrow
                  : Icons.refresh,
            ),
            onPressed: () => manager.resumeGroup(group.id),
          ),
          IconButton(
            tooltip: l10n.cancelDownload,
            icon: const Icon(Icons.close),
            onPressed: () => unawaited(manager.cancelGroup(group.id)),
          ),
        ],
      ),
      DownloadGroupStatus.succeeded => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.downloadViewResult,
            icon: const Icon(Icons.open_in_new),
            onPressed: () {
              final first = children.firstWhere(
                (child) => child.status == DownloadStatus.succeeded,
              );
              unawaited(openIllust(context, first.illustId));
            },
          ),
          IconButton(
            tooltip: l10n.downloadRemoveRecord,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: dismissChildren,
          ),
        ],
      ),
      DownloadGroupStatus.orphaned => IconButton(
        tooltip: l10n.downloadRemoveRecord,
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: dismissChildren,
      ),
      // finalizing/canceling are in-flight teardown — no actions.
      _ => const SizedBox.shrink(),
    };
  }

  String _statusText(BuildContext context) {
    final l10n = context.l10n;
    return switch (group.status) {
      DownloadGroupStatus.queued => l10n.downloadQueued,
      DownloadGroupStatus.running => l10n.downloadRunning,
      DownloadGroupStatus.finalizing => l10n.downloadProcessing,
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
        trailing: _trailingActions(context),
      ),
    );
  }

  /// §5.7/§8.2 action mapping: 取消 only terminates in-flight work, 移除
  /// drops a terminal record, 继续 resumes a paused anchor (not the retry
  /// icon), 重试 re-attempts a real failure, 查看 opens the finished work.
  Widget _trailingActions(BuildContext context) {
    final l10n = context.l10n;
    final pausedRetryable =
        task.status == DownloadStatus.retryable &&
        task.failureKind == DownloadFailureKind.paused;
    return switch (task.status) {
      DownloadStatus.queued => IconButton(
        tooltip: l10n.cancelDownload,
        icon: const Icon(Icons.close),
        onPressed: () => unawaited(manager.cancel(task.id)),
      ),
      DownloadStatus.running => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.pauseDownload,
            icon: const Icon(Icons.pause),
            onPressed: () => unawaited(manager.pause(task.id)),
          ),
          IconButton(
            tooltip: l10n.cancelDownload,
            icon: const Icon(Icons.close),
            onPressed: () => unawaited(manager.cancel(task.id)),
          ),
        ],
      ),
      // In-flight teardown (finalizing/canceling) takes no further
      // action — the status text carries the state.
      DownloadStatus.finalizing ||
      DownloadStatus.canceling => const SizedBox.shrink(),
      DownloadStatus.retryable => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            // A paused task continues from its preserved resume anchor —
            // semantically 继续, not 重试.
            tooltip: pausedRetryable ? l10n.resumeDownload : l10n.retryDownload,
            icon: Icon(pausedRetryable ? Icons.play_arrow : Icons.refresh),
            onPressed: () => manager.retry(task.id),
          ),
          // A paused (retryable) task may still be canceled — cancel is
          // what discards the preserved partial output.
          IconButton(
            tooltip: l10n.cancelDownload,
            icon: const Icon(Icons.close),
            onPressed: () => unawaited(manager.cancel(task.id)),
          ),
        ],
      ),
      DownloadStatus.failed || DownloadStatus.canceled => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.retryDownload,
            icon: const Icon(Icons.refresh),
            onPressed: () => manager.retry(task.id),
          ),
          IconButton(
            tooltip: l10n.downloadRemoveRecord,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => manager.dismiss(task.id),
          ),
        ],
      ),
      DownloadStatus.succeeded => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: l10n.downloadViewResult,
            icon: const Icon(Icons.open_in_new),
            onPressed: () => unawaited(openIllust(context, task.illustId)),
          ),
          IconButton(
            tooltip: l10n.downloadRemoveRecord,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => manager.dismiss(task.id),
          ),
        ],
      ),
      DownloadStatus.orphaned => IconButton(
        tooltip: l10n.downloadRemoveRecord,
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: () => manager.dismiss(task.id),
      ),
    };
  }

  String _downloadStatusText(BuildContext context) {
    return switch (task.status) {
      DownloadStatus.queued => context.l10n.downloadQueued,
      DownloadStatus.running => context.l10n.downloadRunning,
      DownloadStatus.finalizing => context.l10n.downloadProcessing,
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
