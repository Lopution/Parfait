import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../app/motion/state_icon_switcher.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/bookmark_switch_button.dart';
import '../../../../app/widgets/prompt_anchor.dart';
import '../../../../core/download/download_providers.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/illust/illust_download_controller.dart';
import '../../../../l10n/context.dart';

/// The detail page's floating actions, in thumb reach at the bottom:
/// download (with its progress and saved state), comments, and bookmark,
/// which wears a tonal circle as the page's main action.
///
/// One themed surface with separate buttons — no dividers, no segments.
/// [visibility] (1 shown, 0 hidden) slides it below the screen edge and
/// fades it; the page drives it from scrolling. It is the page's prompt anchor, so a
/// snackbar rests above it and moves with it.
class DetailActionBar extends StatefulWidget {
  const DetailActionBar({
    super.key,
    required this.entity,
    required this.visibility,
    required this.onDownload,
    required this.onComments,
  });

  /// Height of the toolbar surface itself.
  static const double height = 64;

  /// Gap between the toolbar and the bottom safe edge.
  static const double margin = FuncSpacing.lg;

  /// What the bar covers at the screen bottom while shown; the page pads
  /// its scroll end by this so the last content can clear it.
  static double restingExtent(BuildContext context) =>
      height + margin + MediaQuery.paddingOf(context).bottom;

  final IllustEntity entity;
  final Animation<double> visibility;
  final VoidCallback onDownload;
  final VoidCallback onComments;

  @override
  State<DetailActionBar> createState() => _DetailActionBarState();
}

class _DetailActionBarState extends State<DetailActionBar> {
  /// The height the bar covers right now, for the prompt anchor.
  final _visibleExtent = ValueNotifier<double>(0);
  double _restingExtent = 0;

  @override
  void initState() {
    super.initState();
    widget.visibility.addListener(_publish);
  }

  @override
  void didUpdateWidget(covariant DetailActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.visibility, widget.visibility)) {
      oldWidget.visibility.removeListener(_publish);
      widget.visibility.addListener(_publish);
    }
  }

  @override
  void dispose() {
    widget.visibility.removeListener(_publish);
    _visibleExtent.dispose();
    super.dispose();
  }

  void _publish() =>
      _visibleExtent.value = _restingExtent * widget.visibility.value;

  @override
  Widget build(BuildContext context) {
    _restingExtent = DetailActionBar.restingExtent(context);
    // Written during build: the anchor only relayouts on it.
    _publish();
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final toolbar = Material(
      color: colors.surfaceContainerHigh,
      elevation: 3,
      shadowColor: colors.shadow,
      shape: StadiumBorder(side: BorderSide(color: colors.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(FuncSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DownloadAction(
              entity: widget.entity,
              onPressed: widget.onDownload,
            ),
            const SizedBox(width: FuncSpacing.sm),
            IconButton(
              tooltip: l10n.commentTitle,
              onPressed: widget.onComments,
              icon: const Icon(Icons.mode_comment_outlined),
            ),
            const SizedBox(width: FuncSpacing.sm),
            DecoratedBox(
              decoration: ShapeDecoration(
                color: colors.secondaryContainer,
                shape: const CircleBorder(),
              ),
              child: BookmarkSwitchButton(
                illustId: widget.entity.id,
                title: widget.entity.title,
              ),
            ),
          ],
        ),
      ),
    );
    return PromptAnchor(
      extent: _visibleExtent,
      child: FadeTransition(
        opacity: widget.visibility,
        child: AnimatedBuilder(
          animation: widget.visibility,
          builder: (context, child) {
            final shown = widget.visibility.value;
            // Hidden means gone for touch and screen readers too.
            return ExcludeSemantics(
              excluding: shown == 0,
              child: IgnorePointer(
                ignoring: shown == 0,
                child: Transform.translate(
                  offset: Offset(0, (1 - shown) * _restingExtent),
                  child: child,
                ),
              ),
            );
          },
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: DetailActionBar.margin),
            child: Center(heightFactor: 1, child: toolbar),
          ),
        ),
      ),
    );
  }
}

/// Download every page; the icon follows the whole work: a ring while
/// pages are in flight, a check once all are saved, an alert after a
/// failure. It follows the manager's change stream itself, so progress
/// ticks redraw this button rather than the page.
class _DownloadAction extends ConsumerStatefulWidget {
  const _DownloadAction({required this.entity, required this.onPressed});

  final IllustEntity entity;
  final VoidCallback onPressed;

  @override
  ConsumerState<_DownloadAction> createState() => _DownloadActionState();
}

class _DownloadActionState extends ConsumerState<_DownloadAction> {
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = ref.read(downloadManagerProvider).changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final save = ref
        .watch(illustDownloadControllerProvider)
        .workStateFor(widget.entity);
    final colors = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final progress = save.progress;
    return IconButton(
      tooltip: switch (save.state) {
        IllustPageSaveState.none => l10n.downloadAll,
        IllustPageSaveState.downloading => l10n.downloadRunning,
        IllustPageSaveState.exist => l10n.detailDownloaded,
        IllustPageSaveState.error => l10n.downloadFailed,
      },
      onPressed: widget.onPressed,
      icon: StateIconSwitcher(
        value: save.state,
        child: switch (save.state) {
          IllustPageSaveState.downloading => SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(
              // Nothing measured yet (queued, unknown length): spin.
              value: progress == null || progress == 0 ? null : progress,
              strokeWidth: 2.5,
            ),
          ),
          IllustPageSaveState.exist => Icon(
            Icons.download_done,
            color: colors.primary,
          ),
          IllustPageSaveState.error => Icon(
            Icons.error_outline,
            color: colors.error,
          ),
          IllustPageSaveState.none => const Icon(Icons.file_download_outlined),
        },
      ),
    );
  }
}
