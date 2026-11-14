import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/danger_filled_button.dart';
import '../../../app/haptics/app_haptics.dart';
import '../../../app/layout/content_widths.dart';
import '../../../app/layout/input_modality.dart';
import '../../../app/motion/app_overlays.dart';
import '../../../app/motion/removal.dart';
import '../../../app/motion/state_icon_switcher.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/display_actions.dart';
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

part 'download_task_rows.dart';

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
  String? _lastToggledTaskId;
  ValueListenable<TickerModeData>? _tickerMode;
  ModalRoute<dynamic>? _route;

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
        if (_lastToggledTaskId != null &&
            _manager.taskById(_lastToggledTaskId!) == null) {
          _lastToggledTaskId = null;
        }
        _expandedGroups.removeWhere(
          (id) => _manager.groups.every((group) => group.id != id),
        );
        if (_managing && _manager.tasks.isEmpty) {
          _managing = false;
          _lastToggledTaskId = null;
        }
        setState(() {});
      }
    });
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    unawaited(
      _manager.recover().whenComplete(() {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode = TickerMode.getValuesNotifier(context);
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    unawaited(_changes?.cancel());
    _removals.dispose();
    super.dispose();
  }

  static bool _isPointer(BuildContext context) =>
      (InputModalityScope.maybeOf(context) ??
          defaultInputModalityFor(Theme.of(context).platform)) ==
      InputModality.pointer;

  static bool _isEditingFocused() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  bool _onKeyEvent(KeyEvent event) {
    if (!mounted || !_managing || event is! KeyDownEvent) return false;
    if (!(_tickerMode?.value.enabled ?? true) || !(_route?.isCurrent ?? true)) {
      return false;
    }
    if (_isEditingFocused() || !_isPointer(context)) return false;
    final kbd = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyA &&
        (kbd.isControlPressed || kbd.isMetaPressed) &&
        !kbd.isAltPressed) {
      _selectAll();
      return true;
    }
    return false;
  }

  void _enterManaging([String? taskId]) {
    // Entering management mode is the explicit-vibration role (§5.6).
    AppHaptics.confirm();
    setState(() {
      _managing = true;
      if (taskId != null) {
        _selected.add(taskId);
        _lastToggledTaskId = taskId;
      }
    });
  }

  void _exitManaging() {
    setState(() {
      _managing = false;
      _selected.clear();
      _lastToggledTaskId = null;
    });
  }

  void _toggleSelected(String taskId) {
    AppHaptics.select();
    setState(() {
      if (!_selected.remove(taskId)) _selected.add(taskId);
      _lastToggledTaskId = taskId;
    });
  }

  void _handleToggle(String taskId, List<String> orderedTaskIds) {
    if (_isPointer(context) &&
        HardwareKeyboard.instance.isShiftPressed &&
        _lastToggledTaskId != null) {
      final start = orderedTaskIds.indexOf(_lastToggledTaskId!);
      final end = orderedTaskIds.indexOf(taskId);
      if (start >= 0 && end >= 0) {
        final lo = math.min(start, end);
        final hi = math.max(start, end);
        AppHaptics.select();
        setState(() {
          _selected.addAll(orderedTaskIds.sublist(lo, hi + 1));
          _lastToggledTaskId = taskId;
        });
        return;
      }
    }
    _toggleSelected(taskId);
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
    if (!mounted) return;
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
      for (final group in _shownGroups)
        if (group.jobIds.every(ids.contains)) group,
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
          DangerFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(title),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Groups drawn with a header. A group of one (a one-page work's
  /// download, or a group down to its last task) is just that task: it
  /// takes a plain row, with no header to open first.
  List<DownloadGroupSnapshot> get _shownGroups => [
    for (final group in _manager.groups)
      if (group.jobIds.length > 1) group,
  ];

  /// The list's entries (§3.1), the newest submission first: a group by
  /// its own, its pages in order under its header; a task outside a shown
  /// group by its own. A group contributes its children only while
  /// expanded (D1), so expanding a several-hundred-item group still builds
  /// lazily.
  List<_DownloadEntry> _entries(List<DownloadTaskSnapshot> tasks) {
    final groups = _shownGroups;
    // Grouped children render inside their group; a child must not appear
    // at both levels.
    final grouped = {for (final group in groups) ...group.jobIds};
    final items = [
      for (final group in groups)
        (group.submission.submittedAt, _groupEntries(group)),
      for (final task in tasks)
        if (!grouped.contains(task.id))
          (task.submission?.submittedAt, [_TaskEntry(task)]),
    ].reversed.indexed.toList();
    // Ties (and undated tasks) keep the manager's order, reversed: the
    // later submission first.
    items.sort((a, b) {
      final (aIndex, (aAt, _)) = a;
      final (bIndex, (bAt, _)) = b;
      final byTime = aAt == null || bAt == null || aAt == bAt
          ? 0
          : bAt.compareTo(aAt);
      return byTime != 0 ? byTime : aIndex.compareTo(bIndex);
    });
    return [for (final (_, (_, entries)) in items) ...entries];
  }

  List<_DownloadEntry> _groupEntries(DownloadGroupSnapshot group) {
    final children = [for (final id in group.jobIds) ?_manager.taskById(id)];
    final expanded = _expandedGroups.contains(group.id);
    return [
      _GroupHeaderEntry(group, children, expanded: expanded),
      if (expanded)
        for (final child in children) _GroupChildEntry(child, group.id),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _manager.tasks;
    final entries = _entries(tasks);
    final orderedTaskIds = [
      for (final entry in entries)
        if (entry case _GroupChildEntry(:final task))
          task.id
        else if (entry case _TaskEntry(:final task))
          task.id,
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
                contentWidth: ContentWidths.management,
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
                contentWidth: ContentWidths.management,
                title: Text(context.l10n.downloaderSettings),
                actions: [
                  // Spelled out: an icon alone did not read as "manage".
                  // Clearing is named in the overflow, as on the history
                  // page; it stays there, disabled, until a task is done,
                  // so "manage" never shifts.
                  if (tasks.isNotEmpty) ...[
                    TextButton(
                      onPressed: _enterManaging,
                      child: Text(context.l10n.manage),
                    ),
                    AppMenuButton<VoidCallback>(
                      entries: [
                        AppMenuEntry(
                          value: () =>
                              unawaited(_removeTasks(_completedTaskIds)),
                          icon: Icons.cleaning_services_outlined,
                          label: context.l10n.downloadClearCompleted,
                          enabled: tasks.any(
                            (task) => task.status == DownloadStatus.succeeded,
                          ),
                        ),
                      ],
                      onSelected: (_, clear) => clear(),
                    ),
                  ],
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
                      slivers: [
                        SliverPadding(
                          // A group header brings _groupGap above it; the
                          // surfaces keep the old cards' spacing.
                          padding: EdgeInsets.fromLTRB(
                            FuncSpacing.md,
                            entries.first is _GroupedEntry
                                ? FuncSpacing.sm + FuncSpacing.xs - _groupGap
                                : FuncSpacing.sm,
                            FuncSpacing.md,
                            entries.last is _GroupedEntry
                                ? FuncSpacing.sm + FuncSpacing.xs
                                : FuncSpacing.sm,
                          ),
                          // One surface per group, drawn around its rows as
                          // they are laid out: the outline follows rows
                          // growing in, folding away and leaving. A task on
                          // its own is a plain row.
                          sliver: SliverSurfaceList.builder(
                            groups: [
                              for (final entry in entries)
                                if (entry case _GroupedEntry(:final groupId))
                                  groupId
                                else
                                  null,
                            ],
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainer,
                            borderRadius: FuncShape.card,
                            leadingGap: _groupGap,
                            findChildIndexCallback: (key) =>
                                _indexOfKey(entries, key),
                            itemBuilder: (context, index) => _row(
                              entries[index],
                              orderedTaskIds: orderedTaskIds,
                              afterSurface:
                                  index > 0 &&
                                  entries[index - 1] is _GroupedEntry,
                            ),
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

  /// [afterSurface]: a plain row right under a group's surface keeps a
  /// little off it.
  Widget _row(
    _DownloadEntry entry, {
    required List<String> orderedTaskIds,
    required bool afterSurface,
  }) => Removable(
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
      _GroupChildEntry(:final task) => _taskRow(
        task,
        orderedTaskIds: orderedTaskIds,
        dense: true,
      ),
      _TaskEntry(:final task) => Padding(
        padding: EdgeInsets.only(top: afterSurface ? FuncSpacing.xs : 0),
        child: _taskRow(task, orderedTaskIds: orderedTaskIds),
      ),
    },
  );

  Widget _taskRow(
    DownloadTaskSnapshot task, {
    required List<String> orderedTaskIds,
    bool dense = false,
  }) {
    return _DownloadTaskRow(
      task: task,
      manager: _manager,
      managing: _managing,
      selected: _selected.contains(task.id),
      onToggle: () => _handleToggle(task.id, orderedTaskIds),
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
