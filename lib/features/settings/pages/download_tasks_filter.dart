import 'package:material_ui/material_ui.dart';

import '../../../core/download/download_manager.dart';
import '../../../core/download/download_task.dart';
import '../../../l10n/context.dart';
import '../../../app/icons/app_icons.dart';
import '../../../app/icons/ui_icons.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/filter_menu_button.dart';

enum DownloadTaskFilter { all, active, failed, completed }

void retryAllFailedDownloads(DownloadManager manager) {
  final ids = [
    for (final task in manager.tasks)
      if (task.status == DownloadStatus.failed) task.id,
  ];
  for (final id in ids) {
    manager.retry(id);
  }
}

bool matchesDownloadTaskFilter(
  DownloadStatus status,
  DownloadTaskFilter filter,
) => switch (filter) {
  DownloadTaskFilter.all => true,
  DownloadTaskFilter.active => !isTerminal(status),
  DownloadTaskFilter.failed => status == DownloadStatus.failed,
  DownloadTaskFilter.completed => status == DownloadStatus.succeeded,
};

String downloadFilterLabel(BuildContext context, DownloadTaskFilter filter) {
  final l10n = context.l10n;
  return switch (filter) {
    DownloadTaskFilter.all => l10n.downloadFilterAll,
    DownloadTaskFilter.active => l10n.downloadFilterActive,
    DownloadTaskFilter.failed => l10n.downloadFilterFailed,
    DownloadTaskFilter.completed => l10n.downloadFilterCompleted,
  };
}

/// Overflow menu on [DownloadTasksPage] offering bulk retry-failed and
/// clear-completed actions.
Widget buildDownloadTasksOverflowMenu(
  BuildContext context, {
  required bool hasFailed,
  required bool hasCompleted,
  required VoidCallback onRetryAllFailed,
  required VoidCallback onClearCompleted,
}) => AppMenuButton<VoidCallback>(
  entries: [
    AppMenuEntry(
      value: onRetryAllFailed,
      icon: UiIcons.refresh,
      label: context.l10n.downloadRetryAllFailed,
      enabled: hasFailed,
    ),
    AppMenuEntry(
      value: onClearCompleted,
      icon: AppIcons.clearDone,
      label: context.l10n.downloadClearCompleted,
      enabled: hasCompleted,
    ),
  ],
  onSelected: (_, action) => action(),
);

/// Top filter & bulk retry-failed frame wrapping the task list or filter-empty
/// state on [DownloadTasksPage].
class DownloadTasksFilterFrame extends StatelessWidget {
  const DownloadTasksFilterFrame({
    super.key,
    required this.filter,
    required this.onFilterChanged,
    required this.failedCount,
    required this.onRetryAllFailed,
    required this.isEmpty,
    required this.child,
  });

  final DownloadTaskFilter filter;
  final ValueChanged<DownloadTaskFilter> onFilterChanged;
  final int failedCount;
  final VoidCallback onRetryAllFailed;
  final bool isEmpty;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.lg,
            FuncSpacing.sm,
            FuncSpacing.lg,
            FuncSpacing.xs,
          ),
          child: Wrap(
            spacing: FuncSpacing.sm,
            runSpacing: FuncSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterMenuButton<DownloadTaskFilter>(
                label: downloadFilterLabel(context, filter),
                value: filter,
                onChanged: onFilterChanged,
                options: [
                  for (final option in DownloadTaskFilter.values)
                    AppMenuEntry(
                      value: option,
                      label: downloadFilterLabel(context, option),
                    ),
                ],
              ),
              if (failedCount > 0)
                OutlinedButton.icon(
                  icon: const Icon(UiIcons.refresh, size: 18),
                  label: Text(context.l10n.downloadRetryAllFailed),
                  onPressed: onRetryAllFailed,
                ),
            ],
          ),
        ),
        Expanded(
          child: isEmpty
              ? FeedEmpty(title: context.l10n.downloadFilterEmpty)
              : child,
        ),
      ],
    );
  }
}
