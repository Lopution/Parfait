import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/haptics/app_haptics.dart';
import '../../../app/layout/content_widths.dart';
import '../../../app/motion/app_overlays.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../core/download/download_manager.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart';
import '../../../l10n/context.dart';

class DownloadTasksPage extends ConsumerStatefulWidget {
  const DownloadTasksPage({super.key});

  @override
  ConsumerState<DownloadTasksPage> createState() => _DownloadTasksPageState();
}

class _DownloadTasksPageState extends ConsumerState<DownloadTasksPage> {
  late final DownloadManager _manager;
  StreamSubscription<void>? _changes;

  /// Selection mode is page-local state — nothing outside this page
  /// consumes it, so it never leaves the widget tree (same contract as
  /// the history page).
  bool _managing = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _manager = ref.read(downloadManagerProvider);
    _changes = _manager.changes.listen((_) {
      if (mounted) {
        // Tasks leaving the list (dismiss/clear) drop out of the
        // selection too.
        _selected.removeWhere((id) => _manager.taskById(id) == null);
        if (_managing && _manager.tasks.isEmpty) _managing = false;
        setState(() {});
      }
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

  void _enterManaging([String? taskId]) {
    // Entering management mode is the explicit-vibration role (§5.6).
    AppHaptics.confirm();
    setState(() {
      _managing = true;
      if (taskId != null) _selected.add(taskId);
    });
  }

  void _exitManaging() {
    setState(() {
      _managing = false;
      _selected.clear();
    });
  }

  void _toggleSelected(String taskId) {
    AppHaptics.select();
    setState(() {
      if (!_selected.remove(taskId)) _selected.add(taskId);
    });
  }

  void _selectAll() {
    AppHaptics.select();
    setState(() {
      _selected.addAll(_manager.tasks.map((task) => task.id));
    });
  }

  Future<void> _cancelSelected() async {
    final targets = [
      for (final task in _manager.tasks)
        if (_selected.contains(task.id) && !isTerminal(task.status)) task.id,
    ];
    if (targets.isEmpty) return;
    final confirmed = await _confirmBatch(
      context,
      title: context.l10n.cancelDownload,
      body: context.l10n.downloadBatchCancelConfirm(targets.length),
    );
    if (!confirmed) return;
    for (final id in targets) {
      await _manager.cancel(id);
    }
    _exitManaging();
  }

  Future<void> _dismissSelected() async {
    final targets = [
      for (final task in _manager.tasks)
        if (_selected.contains(task.id) && isTerminal(task.status)) task.id,
    ];
    if (targets.isEmpty) return;
    final confirmed = await _confirmBatch(
      context,
      title: context.l10n.downloadRemoveRecord,
      body: context.l10n.downloadBatchRemoveConfirm(targets.length),
    );
    if (!confirmed) return;
    for (final id in targets) {
      _manager.dismiss(id);
    }
    _exitManaging();
  }

  /// Batch confirm through the shared dialog — its opening is the
  /// explicit-vibration role; canceling and record removal both discard
  /// something (partial output / the durable record).
  Future<bool> _confirmBatch(
    BuildContext context, {
    required String title,
    required String body,
  }) async {
    AppHaptics.confirm();
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(title),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _manager.tasks;
    final groups = _manager.groups;
    // Grouped children render under their group card (indented); only
    // ungrouped tasks stay in the flat list — a child must not appear at
    // both levels.
    final groupedJobIds = {for (final group in groups) ...group.jobIds};
    final selectedNonTerminal = [
      for (final task in tasks)
        if (_selected.contains(task.id) && !isTerminal(task.status)) task,
    ];
    final selectedTerminal = [
      for (final task in tasks)
        if (_selected.contains(task.id) && isTerminal(task.status)) task,
    ];
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      // System back exits selection mode instead of popping the page.
      canPop: !_managing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitManaging();
      },
      child: Scaffold(
        appBar: _managing
            ? AppBar(
                backgroundColor: colorScheme.primaryContainer,
                leading: IconButton(
                  tooltip: context.l10n.cancel,
                  icon: const Icon(Icons.close),
                  onPressed: _exitManaging,
                ),
                title: Text(context.l10n.selectedCount(_selected.length)),
                actions: [
                  IconButton(
                    tooltip: context.l10n.selectAll,
                    onPressed: _selectAll,
                    icon: const Icon(Icons.select_all),
                  ),
                  IconButton(
                    // Batch-cancel applies to in-flight selections;
                    // batch-remove applies to terminal ones.
                    tooltip: context.l10n.cancelDownload,
                    onPressed: selectedNonTerminal.isEmpty
                        ? null
                        : _cancelSelected,
                    icon: const Icon(Icons.cancel_outlined),
                  ),
                  IconButton(
                    tooltip: context.l10n.downloadRemoveRecord,
                    onPressed: selectedTerminal.isEmpty
                        ? null
                        : _dismissSelected,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ],
              )
            : AppBar(
                title: Text(context.l10n.downloaderSettings),
                actions: [
                  if (tasks.isNotEmpty)
                    IconButton(
                      tooltip: context.l10n.manage,
                      onPressed: _enterManaging,
                      icon: const Icon(Icons.checklist_outlined),
                    ),
                ],
              ),
        body: tasks.isEmpty
            ? FeedEmpty(title: context.l10n.downloadTasksEmpty)
            // Management-list cap (parent §5.5).
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: ContentWidths.management,
                  ),
                  child: ListView(
                    restorationId: 'download-tasks',
                    padding: const EdgeInsets.all(12),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(context.l10n.downloaderSettingsHint),
                      ),
                      for (final group in groups)
                        _DownloadGroupSection(
                          group: group,
                          manager: _manager,
                          managing: _managing,
                          selected: _selected,
                          onToggle: _toggleSelected,
                          onEnterManaging: _enterManaging,
                        ),
                      for (final task in tasks)
                        if (!groupedJobIds.contains(task.id))
                          _DownloadTaskTile(
                            task: task,
                            manager: _manager,
                            managing: _managing,
                            selected: _selected.contains(task.id),
                            onToggle: () => _toggleSelected(task.id),
                            onEnterManaging: () => _enterManaging(task.id),
                          ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// Aggregate section for one submission group (D8 batch): combined progress
/// plus group-level pause/resume/cancel instead of per-tile hunting.
class _DownloadGroupSection extends StatelessWidget {
  const _DownloadGroupSection({
    required this.group,
    required this.manager,
    required this.managing,
    required this.selected,
    required this.onToggle,
    required this.onEnterManaging,
  });

  final DownloadGroupSnapshot group;
  final DownloadManager manager;
  final bool managing;
  final Set<String> selected;
  final void Function(String taskId) onToggle;
  final void Function(String taskId) onEnterManaging;

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
    final progress = group.status == DownloadGroupStatus.succeeded
        ? 1.0
        : group.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 420;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DownloadCardHeading(
                      title: l10n.downloadGroupTitle(group.childCount),
                      compact: compact,
                      actions: _DownloadActionStrip(
                        actions: _groupActions(context, children),
                        compact: compact,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(_statusText(context)),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 4),
                    Text(
                      l10n.downloadGroupProgress(
                        group.succeededCount,
                        group.childCount,
                      ),
                    ),
                  ],
                ),
              );
            },
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
                  _DownloadTaskTile(
                    task: child,
                    manager: manager,
                    managing: managing,
                    selected: selected.contains(child.id),
                    onToggle: () => onToggle(child.id),
                    onEnterManaging: () => onEnterManaging(child.id),
                  ),
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
  List<_DownloadAction> _groupActions(
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
      DownloadGroupStatus.queued || DownloadGroupStatus.running => [
        _DownloadAction(
          label: l10n.pauseDownload,
          icon: Icons.pause,
          onPressed: () => unawaited(manager.pauseGroup(group.id)),
        ),
        _DownloadAction(
          label: l10n.cancelDownload,
          icon: Icons.close,
          onPressed: () => unawaited(manager.cancelGroup(group.id)),
        ),
      ],
      DownloadGroupStatus.retryable ||
      DownloadGroupStatus.failed ||
      DownloadGroupStatus.canceled => [
        _DownloadAction(
          // A paused group continues (resume anchors); a failed or canceled
          // group retries — same resumeGroup entry, the verb follows the
          // dominant child state.
          label: group.status == DownloadGroupStatus.retryable
              ? l10n.resumeDownload
              : l10n.retryDownload,
          icon: group.status == DownloadGroupStatus.retryable
              ? Icons.play_arrow
              : Icons.refresh,
          onPressed: () => manager.resumeGroup(group.id),
        ),
        _DownloadAction(
          label: l10n.cancelDownload,
          icon: Icons.close,
          onPressed: () => unawaited(manager.cancelGroup(group.id)),
        ),
      ],
      DownloadGroupStatus.succeeded => [
        _DownloadAction(
          label: l10n.downloadViewResult,
          icon: Icons.open_in_new,
          onPressed: () {
            final first = children.firstWhere(
              (child) => child.status == DownloadStatus.succeeded,
            );
            unawaited(openIllust(context, first.illustId));
          },
        ),
        _DownloadAction(
          label: l10n.downloadRemoveRecord,
          icon: Icons.remove_circle_outline,
          onPressed: dismissChildren,
        ),
      ],
      DownloadGroupStatus.orphaned => [
        _DownloadAction(
          label: l10n.downloadRemoveRecord,
          icon: Icons.remove_circle_outline,
          onPressed: dismissChildren,
        ),
      ],
      // finalizing/canceling are in-flight teardown — no actions.
      _ => const [],
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

@immutable
class _DownloadAction {
  const _DownloadAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

class _DownloadActionStrip extends StatelessWidget {
  const _DownloadActionStrip({required this.actions, required this.compact});

  final List<_DownloadAction> actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    if (!compact || actions.length == 1) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final action in actions) _button(action)],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(actions.first),
        PopupMenuButton<_DownloadAction>(
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          onSelected: (action) => action.onPressed(),
          itemBuilder: (context) => [
            for (final action in actions.skip(1))
              PopupMenuItem<_DownloadAction>(
                value: action,
                child: Row(
                  children: [
                    Icon(action.icon, size: 20),
                    const SizedBox(width: 12),
                    Text(action.label),
                  ],
                ),
              ),
          ],
          icon: const Icon(Icons.more_vert),
        ),
      ],
    );
  }

  Widget _button(_DownloadAction action) => IconButton(
    tooltip: action.label,
    onPressed: action.onPressed,
    icon: Icon(action.icon),
  );
}

class _DownloadCardHeading extends StatelessWidget {
  const _DownloadCardHeading({
    required this.title,
    required this.compact,
    required this.actions,
  });

  final String title;
  final bool compact;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      title,
      maxLines: compact ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    );
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          text,
          Align(alignment: Alignment.centerRight, child: actions),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: text),
        actions,
      ],
    );
  }
}

class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({
    required this.task,
    required this.manager,
    required this.managing,
    required this.selected,
    required this.onToggle,
    required this.onEnterManaging,
  });

  final DownloadTaskSnapshot task;
  final DownloadManager manager;

  /// In selection mode the tile becomes a single selection unit: tap
  /// toggles membership and the nested action row disappears (M3/T5).
  final bool managing;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onEnterManaging;

  @override
  Widget build(BuildContext context) {
    // Unknown content lengths are indeterminate while active, but a terminal
    // success is still visually complete even when no byte total was known.
    final progress = task.status == DownloadStatus.succeeded
        ? 1.0
        : task.progress;
    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 420;
          final actions = managing
              ? Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : null,
                )
              : _DownloadActionStrip(
                  actions: _taskActions(context),
                  compact: compact,
                );
          return InkWell(
            onTap: managing ? onToggle : null,
            onLongPress: managing ? null : onEnterManaging,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DownloadCardHeading(
                    title: task.displayName,
                    compact: compact && !managing,
                    actions: actions,
                  ),
                  const SizedBox(height: 8),
                  Text(_downloadStatusText(context)),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress),
                  if (task.error != null &&
                      task.failureKind != DownloadFailureKind.paused) ...[
                    const SizedBox(height: 6),
                    Text(
                      task.error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// §5.7/§8.2 action mapping: 取消 only terminates in-flight work, 移除
  /// drops a terminal record, 继续 resumes a paused anchor (not the retry
  /// icon), 重试 re-attempts a real failure, 查看 opens the finished work.
  List<_DownloadAction> _taskActions(BuildContext context) {
    final l10n = context.l10n;
    final pausedRetryable =
        task.status == DownloadStatus.retryable &&
        task.failureKind == DownloadFailureKind.paused;
    return switch (task.status) {
      DownloadStatus.queued => [
        _DownloadAction(
          label: l10n.cancelDownload,
          icon: Icons.close,
          onPressed: () => unawaited(manager.cancel(task.id)),
        ),
      ],
      DownloadStatus.running => [
        _DownloadAction(
          label: l10n.pauseDownload,
          icon: Icons.pause,
          onPressed: () => unawaited(manager.pause(task.id)),
        ),
        _DownloadAction(
          label: l10n.cancelDownload,
          icon: Icons.close,
          onPressed: () => unawaited(manager.cancel(task.id)),
        ),
      ],
      // In-flight teardown (finalizing/canceling) takes no further
      // action — the status text carries the state.
      DownloadStatus.finalizing || DownloadStatus.canceling => const [],
      DownloadStatus.retryable => [
        _DownloadAction(
          // A paused task continues from its preserved resume anchor —
          // semantically 继续, not 重试.
          label: pausedRetryable ? l10n.resumeDownload : l10n.retryDownload,
          icon: pausedRetryable ? Icons.play_arrow : Icons.refresh,
          onPressed: () => manager.retry(task.id),
        ),
        _DownloadAction(
          label: l10n.cancelDownload,
          icon: Icons.close,
          onPressed: () => unawaited(manager.cancel(task.id)),
        ),
      ],
      DownloadStatus.failed || DownloadStatus.canceled => [
        _DownloadAction(
          label: l10n.retryDownload,
          icon: Icons.refresh,
          onPressed: () => manager.retry(task.id),
        ),
        _DownloadAction(
          label: l10n.downloadRemoveRecord,
          icon: Icons.remove_circle_outline,
          onPressed: () => manager.dismiss(task.id),
        ),
      ],
      DownloadStatus.succeeded => [
        _DownloadAction(
          label: l10n.downloadViewResult,
          icon: Icons.open_in_new,
          onPressed: () => unawaited(openIllust(context, task.illustId)),
        ),
        _DownloadAction(
          label: l10n.downloadRemoveRecord,
          icon: Icons.remove_circle_outline,
          onPressed: () => manager.dismiss(task.id),
        ),
      ],
      DownloadStatus.orphaned => [
        _DownloadAction(
          label: l10n.downloadRemoveRecord,
          icon: Icons.remove_circle_outline,
          onPressed: () => manager.dismiss(task.id),
        ),
      ],
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
