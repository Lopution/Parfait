part of 'download_tasks_page.dart';

/// The lazy list's entries (§3.1): a group header, one child of an
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
/// trailing actions. Below 420dp the actions fold into one button and a
/// menu; they move onto a second line only when the text beside them would
/// keep less than [_minInlineTextWidth], while [titleAction] (selection
/// circle / expand icon) stays on the title row.
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

  /// Element pinned to the end of the title row in both layouts.
  final Widget? titleAction;

  /// Row actions; wrapped onto a second line when the row is too narrow.
  final List<_DownloadAction> actions;

  /// The narrowest text column the actions may stand beside: about ten
  /// characters of the title.
  static const _minInlineTextWidth = 160.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final secondary = theme.colorScheme.onSurfaceVariant;
    final captionStyle = textTheme.bodySmall?.copyWith(color: secondary);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 420;
        final buttons =
            (compact ? math.min(actions.length, 2) : actions.length) +
            (titleAction == null ? 0 : 1);
        final textWidth =
            constraints.maxWidth -
            2 * FuncSpacing.lg -
            thumbnailSize -
            FuncSpacing.md -
            buttons * kMinInteractiveDimension;
        final wraps = actions.isNotEmpty && textWidth < _minInlineTextWidth;
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
          ],
        );
        final rowContent = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DownloadThumbnail(url: thumbnailUrl, size: thumbnailSize),
            const SizedBox(width: FuncSpacing.md),
            Expanded(child: textColumn),
            if (wraps && titleAction != null) titleAction!,
          ],
        );
        final strip = _DownloadActionStrip(actions: actions, compact: compact);
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.lg,
            vertical: FuncSpacing.sm,
          ),
          child: wraps
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    rowContent,
                    if (actions.isNotEmpty)
                      Align(alignment: Alignment.centerRight, child: strip),
                  ],
                )
              // The actions end the row, so a group's sit in the same
              // column as its rows', its expand icon just before them.
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: rowContent),
                    ?titleAction,
                    strip,
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
  /// [DownloadTaskSnapshot.failureKind]; the raw error went to the crash
  /// log when the task failed. `paused`/`canceled` are not failures and
  /// show nothing.
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
          onSecondaryTapUp: managing
              ? null
              : (details) => unawaited(
                  showDisplayActions(
                    context,
                    position: details.globalPosition,
                    onLongPress: onEnterManaging,
                    actions: [
                      DisplayAction(
                        icon: Icons.checklist_outlined,
                        label: l10n.manage,
                        onSelected: onEnterManaging,
                      ),
                    ],
                  ),
                ),
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
