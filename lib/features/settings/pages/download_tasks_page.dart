import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/haptics/app_haptics.dart';
import '../../../app/layout/content_widths.dart';
import '../../../app/motion/app_overlays.dart';
import '../../../app/motion/removal.dart';
import '../../../app/motion/state_icon_switcher.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/errors/error_details.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../app/widgets/selection_app_bar.dart';
import '../../../app/widgets/sliver_surface_list.dart';
import '../../../app/widgets/undo_snack_bar.dart';
import '../../../core/download/download_manager.dart';
import '../../../core/download/download_providers.dart';
import '../../../core/download/download_task.dart';
import '../../../core/errors/error_category.dart';
import '../../../l10n/context.dart';
import 'download_task_presentation.dart';

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

  /// Group expansion is page-local too (D1): groups start collapsed and
  /// the set is never persisted or restored.
  final Set<String> _expandedGroups = {};

  final _removals = RemovalController();

  /// Rows an expand inserts this frame: only those grow in, not rows the
  /// lazy list builds on scroll.
  Set<String> _growingRows = const {};

  @override
  void initState() {
    super.initState();
    _manager = ref.read(downloadManagerProvider);
    _changes = _manager.changes.listen((_) {
      if (mounted) {
        // Tasks leaving the list (dismiss/clear) drop out of the
        // selection; gone groups drop out of the expansion set.
        _selected.removeWhere((id) => _manager.taskById(id) == null);
        _expandedGroups.removeWhere(
          (id) => _manager.groups.every((group) => group.id != id),
        );
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

  Future<void> _toggleGroupExpanded(String groupId) async {
    if (_expandedGroups.contains(groupId)) {
      // The children fold away first, then leave the list.
      final group = _manager.groups.where((group) => group.id == groupId);
      await _removals.playExit([
        for (final id in group.expand((group) => group.jobIds)) _taskRowKey(id),
      ]);
      if (mounted) setState(() => _expandedGroups.remove(groupId));
      return;
    }
    final group = _manager.groups.where((group) => group.id == groupId);
    setState(() {
      _expandedGroups.add(groupId);
      _growingRows = {
        for (final id in group.expand(
          (group) => group.jobIds.take(_maxGrowingRows),
        ))
          _taskRowKey(id),
      };
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _growingRows = const {},
    );
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
    _exitManaging();
    await _removeTasks(targets);
  }

  /// Plays the exit of the rows of [taskIds] — plus the header of every
  /// group they empty, however they were picked — then drops the records
  /// and offers Undo (D5: a record is not the file, so removal is
  /// reversible). A task that left the terminal state meanwhile (a retry
  /// landed) is kept, and its rows and its group's header return.
  Future<void> _removeTasks(List<String> taskIds) async {
    final ids = taskIds.toSet();
    final emptied = [
      for (final group in _manager.groups)
        if (group.jobIds.isNotEmpty && group.jobIds.every(ids.contains)) group,
    ];
    await _removals.playExit([
      ...taskIds.map(_taskRowKey),
      for (final group in emptied) _groupRowKey(group.id),
    ]);
    final removal = _manager.dismissAll(taskIds);
    final gone = removal.taskIds.toSet();
    final kept = [
      for (final id in taskIds)
        if (!gone.contains(id)) _taskRowKey(id),
    ];
    if (kept.isNotEmpty) {
      _removals.restore([
        ...kept,
        for (final group in emptied)
          if (!group.jobIds.every(gone.contains)) _groupRowKey(group.id),
      ]);
    }
    if (removal.isEmpty || !mounted) return;
    final manager = _manager;
    showUndoSnackBar(
      context,
      context.l10n.downloadTasksRemoved(removal.count),
      onUndo: (_) async => manager.restore(removal),
    );
  }

  /// Every successfully finished task — failed and canceled ones may still
  /// be retried, so "clear completed" leaves them.
  List<String> get _completedTaskIds => [
    for (final task in _manager.tasks)
      if (task.status == DownloadStatus.succeeded) task.id,
  ];

  /// Batch-cancel confirm through the shared dialog — its opening is the
  /// explicit-vibration role; canceling deletes partial output, which Undo
  /// could not bring back.
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

  /// Flatten the groups into the group list's entries (§3.1): a group
  /// contributes one header row plus its children only while expanded (D1),
  /// so expanding a several-hundred-item group still builds lazily.
  List<_DownloadEntry> _groupEntries(List<DownloadGroupSnapshot> groups) {
    final entries = <_DownloadEntry>[];
    for (final group in groups) {
      final children = [for (final id in group.jobIds) ?_manager.taskById(id)];
      final expanded = _expandedGroups.contains(group.id);
      entries.add(_GroupHeaderEntry(group, children, expanded: expanded));
      if (expanded) {
        for (final child in children) {
          entries.add(_GroupChildEntry(child, group.id));
        }
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _manager.tasks;
    final groups = _manager.groups;
    final groupedJobIds = {for (final group in groups) ...group.jobIds};
    final groupEntries = _groupEntries(groups);
    // Grouped children render inside their group; a child must not appear
    // at both levels.
    final ungrouped = [
      for (final task in tasks)
        if (!groupedJobIds.contains(task.id)) _TaskEntry(task),
    ];
    final selectedNonTerminal = [
      for (final task in tasks)
        if (_selected.contains(task.id) && !isTerminal(task.status)) task,
    ];
    final selectedTerminal = [
      for (final task in tasks)
        if (_selected.contains(task.id) && isTerminal(task.status)) task,
    ];
    return PopScope(
      // System back exits selection mode instead of popping the page.
      canPop: !_managing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitManaging();
      },
      child: Scaffold(
        appBar: _managing
            ? selectionAppBar(
                context,
                count: _selected.length,
                onClose: _exitManaging,
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
            : AppTopBar(
                title: Text(context.l10n.downloaderSettings),
                actions: [
                  if (tasks.any(
                    (task) => task.status == DownloadStatus.succeeded,
                  ))
                    IconButton(
                      tooltip: context.l10n.downloadClearCompleted,
                      onPressed: () => _removeTasks(_completedTaskIds),
                      icon: const Icon(Icons.cleaning_services_outlined),
                    ),
                  // Spelled out: an icon alone did not read as "manage".
                  if (tasks.isNotEmpty)
                    TextButton(
                      onPressed: _enterManaging,
                      child: Text(context.l10n.manage),
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
                  child: RemovalScope(
                    controller: _removals,
                    child: CustomScrollView(
                      restorationId: 'download-tasks',
                      // Keyed: the ungrouped rows keep their state when the
                      // last group leaves.
                      slivers: [
                        if (groupEntries.isNotEmpty)
                          SliverPadding(
                            key: const ValueKey('groups'),
                            // Each header brings _groupGap above it; the
                            // surfaces keep the old cards' spacing.
                            padding: EdgeInsets.fromLTRB(
                              FuncSpacing.md,
                              FuncSpacing.sm + FuncSpacing.xs - _groupGap,
                              FuncSpacing.md,
                              ungrouped.isEmpty
                                  ? FuncSpacing.sm + FuncSpacing.xs
                                  : 0,
                            ),
                            // One surface per group, drawn around its rows as
                            // they are laid out: the outline follows rows
                            // growing in, folding away and leaving.
                            sliver: SliverSurfaceList.builder(
                              groups: [
                                for (final entry in groupEntries)
                                  (entry as _GroupedEntry).groupId,
                              ],
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainer,
                              borderRadius: FuncShape.card,
                              leadingGap: _groupGap,
                              findChildIndexCallback: (key) =>
                                  _indexOfKey(groupEntries, key),
                              itemBuilder: (context, index) =>
                                  _row(groupEntries[index]),
                            ),
                          ),
                        if (ungrouped.isNotEmpty)
                          SliverPadding(
                            key: const ValueKey('ungrouped'),
                            padding: EdgeInsets.fromLTRB(
                              FuncSpacing.md,
                              groupEntries.isEmpty
                                  ? FuncSpacing.sm
                                  : FuncSpacing.xs,
                              FuncSpacing.md,
                              FuncSpacing.sm,
                            ),
                            sliver: SliverList.builder(
                              itemCount: ungrouped.length,
                              findChildIndexCallback: (key) =>
                                  _indexOfKey(ungrouped, key),
                              itemBuilder: (context, index) =>
                                  _row(ungrouped[index]),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _row(_DownloadEntry entry) => Removable(
    key: ValueKey(entry.key),
    id: entry.key,
    animateIn: _growingRows.contains(entry.key),
    child: switch (entry) {
      _GroupHeaderEntry(:final group, :final children, :final expanded) =>
        Padding(
          // The gap leaves with the header when the group is removed.
          padding: const EdgeInsets.only(top: _groupGap),
          child: _DownloadGroupHeader(
            group: group,
            children: children,
            manager: _manager,
            expanded: expanded,
            onToggleExpanded: () => _toggleGroupExpanded(group.id),
            onRemove: _removeTasks,
          ),
        ),
      _GroupChildEntry(:final task) => _taskRow(task, dense: true),
      _TaskEntry(:final task) => _taskRow(task),
    },
  );

  Widget _taskRow(DownloadTaskSnapshot task, {bool dense = false}) {
    return _DownloadTaskRow(
      task: task,
      manager: _manager,
      managing: _managing,
      selected: _selected.contains(task.id),
      onToggle: () => _toggleSelected(task.id),
      onEnterManaging: () => _enterManaging(task.id),
      onRemove: () => _removeTasks([task.id]),
      dense: dense,
    );
  }
}

String _taskRowKey(String taskId) => 'download-task-$taskId';

/// Space above each group's surface: two groups sit this far apart.
const _groupGap = FuncSpacing.sm;

int? _indexOfKey(List<_DownloadEntry> entries, Key key) {
  if (key is! ValueKey<String>) return null;
  final index = entries.indexWhere((entry) => entry.key == key.value);
  return index < 0 ? null : index;
}

/// Children of an expanding group that grow in: about one screen of rows.
/// Every growing row starts at zero height, so the lazy list would build
/// all of them at once; the rest appear at full size below the fold.
const _maxGrowingRows = 16;
String _groupRowKey(String groupId) => 'download-group-$groupId';

/// Removes task rows (and the headers of groups they empty) with Undo;
/// owned by the page so the Undo prompt outlives the removed rows.
typedef _RemoveTasks = Future<void> Function(List<String> taskIds);

/// The lazy lists' entries (§3.1): a group header, one child of an
/// expanded group, or an ungrouped task.
sealed class _DownloadEntry {
  const _DownloadEntry();

  /// Stable `download-group-*`/`download-task-*` key — tests also count
  /// built rows through this prefix.
  String get key;
}

/// A row of a group: drawn on that group's surface.
sealed class _GroupedEntry extends _DownloadEntry {
  const _GroupedEntry();

  String get groupId;
}

final class _GroupHeaderEntry extends _GroupedEntry {
  const _GroupHeaderEntry(this.group, this.children, {required this.expanded});

  final DownloadGroupSnapshot group;
  final List<DownloadTaskSnapshot> children;
  final bool expanded;

  @override
  String get groupId => group.id;

  @override
  String get key => _groupRowKey(group.id);
}

final class _GroupChildEntry extends _GroupedEntry {
  const _GroupChildEntry(this.task, this.groupId);

  final DownloadTaskSnapshot task;

  @override
  final String groupId;

  @override
  String get key => _taskRowKey(task.id);
}

final class _TaskEntry extends _DownloadEntry {
  const _TaskEntry(this.task);

  final DownloadTaskSnapshot task;

  @override
  String get key => _taskRowKey(task.id);
}

/// One download row's chrome (§5.1): thumbnail, title, status line, and the
/// trailing actions. Below 420dp the actions wrap onto a second line while
/// [titleAction] (selection circle / expand icon) stays on the title row —
/// the same rule `54815ac` set for the old card heading.
class _DownloadRowLayout extends StatelessWidget {
  const _DownloadRowLayout({
    required this.thumbnailUrl,
    this.thumbnailSize = 56,
    required this.title,
    this.titleWraps = false,
    this.titleNote,
    this.subtitle,
    required this.status,
    this.progress,
    this.detail,
    this.errorDetails,
    this.titleAction,
    this.actions = const [],
  });

  final String? thumbnailUrl;
  final double thumbnailSize;
  final String title;

  /// Whether the title wraps in full. Work titles are user content and
  /// stop at two lines; group titles are mostly app copy, which must stay
  /// whole in every language.
  final bool titleWraps;

  /// Trailing note on the title line (the page label).
  final String? titleNote;

  /// Secondary line (the artist).
  final String? subtitle;

  /// Icon + text status line.
  final Widget status;

  /// Progress bar — present only while the state is unfinished (R2).
  final Widget? progress;

  /// Localized failure reason under the status line.
  final String? detail;

  /// Raw error behind the collapsible details disclosure (C8/D1) — `null`
  /// when there is nothing technical to expand.
  final Object? errorDetails;

  /// Element pinned to the end of the title row in both layouts.
  final Widget? titleAction;

  /// Row actions; wrapped onto a second line when compact.
  final List<_DownloadAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final secondary = theme.colorScheme.onSurfaceVariant;
    final captionStyle = textTheme.bodySmall?.copyWith(color: secondary);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 420;
        final textColumn = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: titleWraps ? null : (compact ? 2 : 1),
                    overflow: titleWraps ? null : TextOverflow.ellipsis,
                    style: textTheme.titleMedium,
                  ),
                ),
                if (titleNote != null) ...[
                  const SizedBox(width: FuncSpacing.sm),
                  Text(titleNote!, maxLines: 1, style: captionStyle),
                ],
              ],
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: captionStyle,
              ),
            const SizedBox(height: FuncSpacing.xxs),
            status,
            if (progress != null) ...[
              const SizedBox(height: FuncSpacing.xs),
              progress!,
            ],
            if (detail != null) ...[
              const SizedBox(height: FuncSpacing.xxs),
              Text(detail!, style: captionStyle),
            ],
            if (errorDetails != null) ErrorDetails(error: errorDetails!),
          ],
        );
        final rowContent = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DownloadThumbnail(url: thumbnailUrl, size: thumbnailSize),
            const SizedBox(width: FuncSpacing.md),
            Expanded(child: textColumn),
            if (compact && titleAction != null) titleAction!,
          ],
        );
        final strip = _DownloadActionStrip(actions: actions, compact: compact);
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.lg,
            vertical: FuncSpacing.sm,
          ),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    rowContent,
                    if (actions.isNotEmpty)
                      Align(alignment: Alignment.centerRight, child: strip),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: rowContent),
                    strip,
                    ?titleAction,
                  ],
                ),
        );
      },
    );
  }
}

/// The square artwork thumbnail (R1/R6): decoded at its display size
/// through the shared `PixivImage` cache; no URL keeps a neutral
/// placeholder.
class _DownloadThumbnail extends StatelessWidget {
  const _DownloadThumbnail({required this.url, required this.size});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = this.url;
    return ClipRRect(
      borderRadius: FuncShape.control,
      child: SizedBox.square(
        dimension: size,
        child: ColoredBox(
          color: colorScheme.surfaceContainerHighest,
          child: url == null
              ? Icon(Icons.image_outlined, color: colorScheme.onSurfaceVariant)
              : PixivImage.feed(url, layoutWidth: size, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

/// Icon + text status line; only the icon carries the status color (R3) —
/// tinted text fell below the 4.5:1 contrast floor on the page surface.
class _DownloadStatusLine extends StatelessWidget {
  const _DownloadStatusLine({required this.state, required this.text});

  final DownloadVisualState state;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          downloadVisualIcon(state),
          size: 16,
          color: downloadVisualIconColor(
            theme.colorScheme,
            FuncSemanticTokens.of(context),
            state,
          ),
        ),
        const SizedBox(width: FuncSpacing.xs),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                .tabular,
          ),
        ),
      ],
    );
  }
}

/// One flat or group-child task row (replaces the old card tile). With no
/// card boundary left, the ink paints on a transparent `Material` so taps
/// and long-presses still ripple on the row itself.
class _DownloadTaskRow extends StatelessWidget {
  const _DownloadTaskRow({
    required this.task,
    required this.manager,
    required this.managing,
    required this.selected,
    required this.onToggle,
    required this.onEnterManaging,
    required this.onRemove,
    this.dense = false,
  });

  final DownloadTaskSnapshot task;
  final DownloadManager manager;

  /// In selection mode the row becomes a single selection unit: tap
  /// toggles membership and the action strip disappears (M3/T5).
  final bool managing;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onEnterManaging;
  final VoidCallback onRemove;

  /// Group children render smaller thumbnails aligned under the header's
  /// text column.
  final bool dense;

  /// Localized failure reason under the status line (C8/D1): mapped from
  /// [DownloadTaskSnapshot.failureKind], with the raw error staying behind
  /// [ErrorDetails]. `paused`/`canceled` are not failures and show nothing.
  /// A retryable task without a kind was running or queued when the process
  /// died (recovery keeps the record's null kind), so it says so instead of
  /// "unknown error". Any other kindless record falls back to the generic
  /// category table.
  static String? _failureReason(
    BuildContext context,
    DownloadTaskSnapshot task,
  ) {
    final kind = task.failureKind;
    if (kind == DownloadFailureKind.canceled ||
        kind == DownloadFailureKind.paused) {
      return null;
    }
    if (kind == null && task.status == DownloadStatus.retryable) {
      return context.l10n.downloadFailureInterrupted;
    }
    final mapped = downloadFailureReasonText(context.l10n, kind);
    if (mapped != null) return mapped;
    final error = task.error;
    return error == null
        ? null
        : errorCategoryText(context, categorizeError(error));
  }

  /// Raw error text for the details disclosure — shown only when the row
  /// also reports a failure ([_failureReason] suppresses paused/canceled).
  static Object? _failureDetailsError(DownloadTaskSnapshot task) {
    final kind = task.failureKind;
    if (kind == DownloadFailureKind.canceled ||
        kind == DownloadFailureKind.paused) {
      return null;
    }
    return task.error;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final state = visualStateOfTask(task);
    final info = downloadTaskStatusDetail(state, task);
    final statusText = info == null
        ? downloadVisualText(l10n, state)
        : '${downloadVisualText(l10n, state)} · $info';
    // Outside management the row opens its work; the action strip keeps
    // its own targets.
    return Semantics(
      container: true,
      button: true,
      onTapHint: managing ? null : l10n.downloadOpenWork,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: managing
              ? onToggle
              : () => unawaited(openIllust(context, task.illustId)),
          onLongPress: managing ? null : onEnterManaging,
          // Entering management plays AppHaptics.confirm and toggles play
          // select; the ink response's own vibration would double them.
          enableFeedback: false,
          child: _DownloadRowLayout(
            thumbnailUrl: task.submission?.request.thumbnailUrl,
            thumbnailSize: dense ? 40 : 56,
            title: downloadTaskTitle(task),
            titleNote: downloadTaskPageLabel(l10n, task),
            subtitle: downloadTaskSubtitle(task),
            status: _DownloadStatusLine(state: state, text: statusText),
            progress: downloadVisualShowsProgress(state)
                ? LinearProgressIndicator(
                    value: downloadProgressValue(state, task.progress),
                    borderRadius: FuncShape.pill,
                  )
                : null,
            detail: _failureReason(context, task),
            errorDetails: _failureDetailsError(task),
            titleAction: managing
                ? StateIconSwitcher(
                    value: selected,
                    child: Icon(
                      key: ValueKey('download-select-${task.id}'),
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: selected ? colorScheme.primary : null,
                    ),
                  )
                : null,
            actions: managing ? const [] : _taskActions(context),
          ),
        ),
      ),
    );
  }

  /// §5.7/§8.2 action mapping: 取消 only terminates in-flight work, 移除
  /// drops a terminal record, 继续 resumes a paused anchor (not the retry
  /// icon), 重试 re-attempts a real failure. The row itself opens the work,
  /// so a finished task has no 查看 of its own.
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
          onPressed: onRemove,
        ),
      ],
      DownloadStatus.succeeded || DownloadStatus.orphaned => [
        _DownloadAction(
          label: l10n.downloadRemoveRecord,
          icon: Icons.remove_circle_outline,
          onPressed: onRemove,
        ),
      ],
    };
  }
}

/// A group's single collapsed/expanded header row (replaces the old card
/// section): thumbnail from its first child, a source-aware title, the
/// aggregate status, and the group actions. The whole row toggles the
/// group's expansion — children never enter selection mode through it.
class _DownloadGroupHeader extends StatelessWidget {
  const _DownloadGroupHeader({
    required this.group,
    required this.children,
    required this.manager,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onRemove,
  });

  final DownloadGroupSnapshot group;
  final List<DownloadTaskSnapshot> children;
  final DownloadManager manager;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final _RemoveTasks onRemove;

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
    final colorScheme = Theme.of(context).colorScheme;
    final material = MaterialLocalizations.of(context);
    final state = visualStateOfGroup(
      group,
      everyRetryablePaused: _everyRetryablePaused,
    );
    return Semantics(
      button: true,
      expanded: expanded,
      onTapHint: expanded
          ? material.expandedIconTapHint
          : material.collapsedIconTapHint,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onToggleExpanded,
          child: _DownloadRowLayout(
            thumbnailUrl: children.isEmpty
                ? null
                : children.first.submission?.request.thumbnailUrl,
            title: downloadGroupRowTitle(l10n, children, group.childCount),
            titleWraps: true,
            subtitle: downloadGroupSubtitle(children),
            status: _DownloadStatusLine(
              state: state,
              text: downloadGroupStatusLine(l10n, state, group),
            ),
            progress: downloadVisualShowsProgress(state)
                ? LinearProgressIndicator(
                    value: downloadProgressValue(state, group.progress),
                    borderRadius: FuncShape.pill,
                  )
                : null,
            titleAction: Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              color: colorScheme.onSurfaceVariant,
            ),
            actions: _groupActions(context, children),
          ),
        ),
      ),
    );
  }

  /// Group-level mapping mirrors the per-task table: queued/running
  /// pause+cancel, retryable/failed/canceled resume+cancel, succeeded
  /// 移除, plus 查看 when every child is a page of one work — the header
  /// then stands for that work. A group of several works has no single
  /// work to open; each row opens its own. A fully-terminal orphaned group
  /// can only be removed.
  List<_DownloadAction> _groupActions(
    BuildContext context,
    List<DownloadTaskSnapshot> children,
  ) {
    final l10n = context.l10n;
    void dismissChildren() =>
        unawaited(onRemove([for (final child in children) child.id]));
    final works = {for (final child in children) child.illustId};

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
        if (works.length == 1)
          _DownloadAction(
            label: l10n.downloadViewResult,
            icon: Icons.open_in_new,
            onPressed: () => unawaited(openIllust(context, works.single)),
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
      // finalizing is in-flight teardown — no actions.
      _ => const [],
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
        AppMenuButton<_DownloadAction>(
          onSelected: (_, action) => action.onPressed(),
          entries: [
            for (final action in actions.skip(1))
              AppMenuEntry(
                value: action,
                icon: action.icon,
                label: action.label,
              ),
          ],
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
