import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/mute/mute_models.dart';
import '../../core/mute/mute_store.dart';
import '../../l10n/context.dart';
import '../clipboard.dart';
import '../haptics/app_haptics.dart';
import '../motion/app_overlays.dart';
import '../theme/func_semantic_tokens.dart';
import 'errors/error_details.dart';
import 'inline_translation.dart';
import 'unmute_undo.dart';

/// Direct tag action menu (R3), opened by a long press on a tag: search,
/// copy, translate — always offered, a Pixiv translation may be missing or
/// partial — and, where the caller passes them, mute/unmute and the batch
/// mute mode. Every action but translate closes the sheet first; the
/// translation shows inside the sheet.
Future<void> showTagActionsSheet(
  BuildContext context, {
  required String tag,
  required VoidCallback onSearch,
  bool muted = false,
  VoidCallback? onToggleMute,
  VoidCallback? onMuteMode,
}) {
  AppHaptics.longPress();
  return showAppBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _TagActions(
      tag: tag,
      muted: muted,
      onSearch: onSearch,
      onCopy: () => unawaited(
        copyToClipboard(context, tag, message: context.l10n.tagCopied),
      ),
      onToggleMute: onToggleMute,
      onMuteMode: onMuteMode,
    ),
  );
}

/// Mutes or unmutes [tag]; a failure shows the error, a landed unmute
/// offers Undo.
Future<void> toggleTagMute(
  BuildContext context,
  MuteStore store,
  String tag, {
  required bool muted,
}) async {
  try {
    await store.toggleTag(tag);
  } on Object catch (error) {
    if (context.mounted) {
      showErrorSnackBar(context, action: context.l10n.muteFailed, error: error);
    }
    return;
  }
  if (muted && context.mounted) showUnmuteUndo(context, MuteKey.tag(tag));
}

class _TagActions extends ConsumerStatefulWidget {
  const _TagActions({
    required this.tag,
    required this.muted,
    required this.onSearch,
    required this.onCopy,
    this.onToggleMute,
    this.onMuteMode,
  });

  final String tag;
  final bool muted;
  final VoidCallback onSearch;
  final VoidCallback onCopy;
  final VoidCallback? onToggleMute;
  final VoidCallback? onMuteMode;

  @override
  ConsumerState<_TagActions> createState() => _TagActionsState();
}

class _TagActionsState extends ConsumerState<_TagActions>
    with InlineTranslation {
  /// Closes the sheet, then runs [action] against the page below.
  VoidCallback _closing(VoidCallback action) => () {
    Navigator.of(context).pop();
    action();
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final onToggleMute = widget.onToggleMute;
    final onMuteMode = widget.onMuteMode;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.search),
              title: Text(l10n.tagActionSearch),
              onTap: _closing(widget.onSearch),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: Text(l10n.tagActionCopy),
              onTap: _closing(widget.onCopy),
            ),
            ListTile(
              leading: const Icon(Icons.translate),
              title: Text(
                translationShown
                    ? l10n.translationHide
                    : l10n.tagActionTranslate,
              ),
              enabled: !translating,
              onTap: () => unawaited(toggleTranslation([widget.tag])),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
              child: TranslationPanel(
                translating: translating,
                translations: translations,
                failure: translationFailure,
                copyable: true,
              ),
            ),
            if (onToggleMute != null)
              ListTile(
                leading: Icon(
                  widget.muted
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                title: Text(
                  widget.muted ? l10n.tagActionUnmute : l10n.tagActionMute,
                ),
                onTap: _closing(onToggleMute),
              ),
            if (onMuteMode != null)
              ListTile(
                leading: const Icon(Icons.playlist_add_check),
                title: Text(l10n.tagActionMuteMode),
                onTap: _closing(onMuteMode),
              ),
          ],
        ),
      ),
    );
  }
}
