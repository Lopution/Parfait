import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/widgets/danger_filled_button.dart';
import '../../app/widgets/desktop_file_drop_target.dart';
import '../../app/format/app_format.dart';
import '../../app/haptics/app_haptics.dart';
import '../../app/layout/content_widths.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/removal.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/pull_to_refresh.dart';
import '../../app/widgets/app_dialog.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/entity_row.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/localnovel/local_novel_decoder.dart';
import '../../core/localnovel/local_novel_repository.dart';
import '../../core/localnovel/local_novel_store.dart';
import '../../core/platform/saf_tree.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/icons/app_icons.dart';

/// The imported-TXT library: list rows (title/size/import time), an import
/// action, and delete — reading itself is wired by the local reader route.
class LocalNovelsPage extends ConsumerStatefulWidget {
  const LocalNovelsPage({super.key});

  @override
  ConsumerState<LocalNovelsPage> createState() => _LocalNovelsPageState();
}

class _LocalNovelsPageState extends ConsumerState<LocalNovelsPage> {
  final _removals = RemovalController();

  @override
  void dispose() {
    _removals.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(localNovelStoreProvider);
    return Scaffold(
      appBar: AppTopBar(
        contentWidth: ContentWidths.management,
        title: Text(context.l10n.localNovelsTitle),
        actions: [
          IconButton(
            tooltip: context.l10n.localNovelsImport,
            onPressed: () => _import(context, ref),
            icon: const Icon(AppIcons.folderOpen),
          ),
        ],
      ),
      // Management-list cap (parent §5.5): left-aligned inside embedded
      // workspaces to follow AppTopBar (PAGE-23), centered standalone.
      body: DesktopFileDropTarget(
        hint: context.l10n.localNovelsDropHint,
        icon: AppIcons.fileImport,
        onFilesDropped: (paths) => unawaited(_handleDroppedFiles(paths)),
        child: ContentWidthCap(
          maxWidth: ContentWidths.management,
          alignStart: EmbeddedHeaderScope.isActiveOf(context),
          child: async.when(
            loading: () => const FeedLoading(),
            error: (error, _) => FeedError(
              title: context.l10n.localNovelsLoadFailed,
              error: error,
              retryLabel: context.l10n.retry,
              onRetry: () => ref.invalidate(localNovelStoreProvider),
            ),
            data: (novels) {
              if (novels.isEmpty) {
                return FeedEmpty(
                  icon: AppIcons.localNovel,
                  title: context.l10n.localNovelsEmpty,
                  actionLabel: context.l10n.localNovelsImport,
                  actionIcon: AppIcons.folderOpen,
                  onAction: () => unawaited(_import(context, ref)),
                );
              }
              return PullToRefresh(
                onRefresh: () async => ref.invalidate(localNovelStoreProvider),
                child: RemovalScope(
                  controller: _removals,
                  child: SmoothWheelScroll(
                    builder: (context, controller, physics) => ListView.builder(
                      controller: controller,
                      physics: physics,
                      restorationId: 'local-novels',
                      itemCount: novels.length,
                      itemBuilder: (context, index) => Removable(
                        id: novels[index].id,
                        child: _LocalNovelTile(novel: novels[index]),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) => _runImport(
    context,
    () => ref.read(localNovelStoreProvider.notifier).importPicked(),
  );

  Future<void> _handleDroppedFiles(List<String> paths) async {
    final txtPaths = [
      for (final path in paths)
        if (p.extension(path).toLowerCase() == '.txt') path,
    ];
    if (txtPaths.isEmpty) {
      if (!mounted) return;
      showAppSnackBar(context, context.l10n.localNovelsDropUnsupported);
      return;
    }
    for (final path in txtPaths) {
      if (!mounted) return;
      await _runImport(
        context,
        () => ref.read(localNovelStoreProvider.notifier).importFilePath(path),
      );
    }
  }

  Future<void> _runImport(
    BuildContext context,
    Future<LocalNovel?> Function() action,
  ) async {
    try {
      final novel = await action();
      if (!context.mounted || novel == null) return;
      showAppSnackBar(
        context,
        novel.encoding == LocalNovelEncoding.utf8Lossy
            ? context.l10n.localNovelsImportedLossy
            : context.l10n.localNovelsImported(novel.title),
      );
    } on DocumentTooLargeException catch (error) {
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        context.l10n.errorWithReason(
          context.l10n.localNovelsImportFailed,
          context.l10n.importFileTooLarge(error.maxMegabytes),
        ),
      );
    } on LocalNovelTooLargeException catch (error) {
      if (!context.mounted) return;
      final reason = switch (error.kind) {
        LocalNovelLimitKind.chars => context.l10n.localNovelsTooManyChars(
          error.limit,
        ),
        LocalNovelLimitKind.paragraphs =>
          context.l10n.localNovelsTooManyParagraphs(error.limit),
      };
      showAppSnackBar(
        context,
        context.l10n.errorWithReason(
          context.l10n.localNovelsImportFailed,
          reason,
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      showErrorSnackBar(
        context,
        action: context.l10n.localNovelsImportFailed,
        error: error,
      );
    }
  }
}

enum _LocalNovelAction { delete }

class _LocalNovelTile extends ConsumerWidget {
  const _LocalNovelTile({required this.novel});

  final LocalNovel novel;

  /// `readOffset` is a real reading cursor: null = never opened (no
  /// progress text at all), 0 = a record at the start (renders "0%") —
  /// the two states are not interchangeable.
  int? get _progressPercent {
    final offset = novel.readOffset;
    if (offset == null) return null;
    if (novel.charCount <= 0) return 0;
    return (offset / novel.charCount * 100).round().clamp(0, 100);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final percent = _progressPercent;
    final meta = [
      context.l10n.localNovelsChars(novel.charCount),
      AppFormat.date(context, novel.importedAt),
      if (percent != null) context.l10n.localNovelContinue(percent),
    ].join(' · ');
    return EntityRow(
      // The menu button's glyph ends on the margin (LAYOUT-15).
      padding: const EdgeInsetsDirectional.fromSTEB(
        FuncSpacing.lg,
        FuncSpacing.md,
        FuncSpacing.lg - EdgeIconButtons.glyphInset,
        FuncSpacing.md,
      ),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: FuncShape.control,
        ),
        child: const Icon(AppIcons.localNovel),
      ),
      title: novel.title,
      meta: meta,
      // The primary action is "continue reading" — announce the progress
      // so the affordance is audible, not only visible.
      semanticLabel: '${novel.title}, $meta',
      onTap: () => openLocalNovelReader(context, novel.id),
      // A row-anchored menu, not a sheet: one action does not need a
      // surface rising from the screen edge.
      trailing: AppMenuButton<_LocalNovelAction>(
        entries: [
          AppMenuEntry(
            value: _LocalNovelAction.delete,
            icon: AppIcons.trash,
            label: context.l10n.localNovelsDelete,
          ),
        ],
        onSelected: (_, action) => switch (action) {
          // Deleting removes the imported file — irreversible, so it keeps
          // its confirmation (D5).
          _LocalNovelAction.delete => unawaited(_confirmDelete(context)),
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    // Opening the destructive confirm surface is the explicit-vibration
    // role (parent §5.6); the neutral overflow menu stays silent.
    AppHaptics.confirm();
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(context.l10n.localNovelsDelete),
        content: Text(context.l10n.localNovelsDeleteConfirm(novel.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.l10n.cancel),
          ),
          DangerFilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(context.l10n.localNovelsDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    // The provider container outlives the tile — a defunct WidgetRef
    // would throw if the list rebuilt while the dialog was open.
    final store = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(localNovelStoreProvider.notifier);
    final failed = deferErrorSnackBar(
      context,
      action: context.l10n.localNovelsDeleteFailed,
    );
    final removals = RemovalScope.of(context);
    await removals.playExit([novel.id]);
    try {
      await store.delete(novel);
    } on Object catch (error, stack) {
      removals.restore([novel.id]);
      failed(error, stack);
    }
  }
}
