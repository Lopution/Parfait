import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/mute/mute_models.dart';
import '../../core/mute/mute_store.dart';
import '../../l10n/context.dart';
import '../clipboard.dart';
import '../haptics/app_haptics.dart';
import '../motion/app_overlays.dart';
import '../theme/func_semantic_tokens.dart';
import 'display_actions.dart';
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
  Offset? position,
  PointerDeviceKind? kind,
}) {
  AppHaptics.longPress();
  Future<void> sheet({bool translate = false}) => showAppAdaptivePopover<void>(
    context: context,
    anchorContext: context,
    position: position,
    maxWidth: 340,
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
      autoTranslate: translate,
    ),
  );
  if (position == null) return sheet();
  // A pointer's secondary click: the same entries as the panel, beside the
  // pointer (R11). Translation needs the panel's inline result, so that
  // entry opens the panel already translating.
  final l10n = context.l10n;
  return showDisplayActions(
    context,
    position: position,
    kind: kind,
    onLongPress: () => unawaited(sheet()),
    actions: [
      DisplayAction(
        icon: Icons.search,
        label: l10n.tagActionSearch,
        onSelected: onSearch,
      ),
      DisplayAction(
        icon: Icons.copy_outlined,
        label: l10n.tagActionCopy,
        onSelected: () => unawaited(
          copyToClipboard(context, tag, message: context.l10n.tagCopied),
        ),
      ),
      DisplayAction(
        icon: Icons.translate,
        label: l10n.tagActionTranslate,
        onSelected: () => unawaited(sheet(translate: true)),
      ),
      if (onToggleMute != null)
        DisplayAction(
          icon: muted
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          label: muted ? l10n.tagActionUnmute : l10n.tagActionMute,
          onSelected: onToggleMute,
        ),
      if (onMuteMode != null)
        DisplayAction(
          icon: Icons.playlist_add_check,
          label: l10n.tagActionMuteMode,
          onSelected: onMuteMode,
        ),
    ],
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
    this.autoTranslate = false,
  });

  final String tag;
  final bool muted;
  final VoidCallback onSearch;
  final VoidCallback onCopy;
  final VoidCallback? onToggleMute;
  final VoidCallback? onMuteMode;

  /// The panel is the translation result surface: open it already asking.
  final bool autoTranslate;

  @override
  ConsumerState<_TagActions> createState() => _TagActionsState();
}

class _TagActionsState extends ConsumerState<_TagActions>
    with InlineTranslation {
  @override
  void initState() {
    super.initState();
    if (!widget.autoTranslate) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(toggleTranslation([widget.tag]));
    });
  }

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
    final failure = translationFailure;
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
            // A failure is this row's state: the reason as its subtitle, the
            // error color on its icon only for an error — translation that
            // is off or not set up is not one (THEME-08). The row hides a
            // translation; after a failure it asks again.
            ListTile(
              leading: Icon(
                Icons.translate,
                color: failure == null || translationNotSetUp(failure)
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
              title: Text(
                translations != null
                    ? l10n.translationHide
                    : l10n.tagActionTranslate,
              ),
              subtitle: failure == null
                  ? null
                  : Text(translationFailureText(context, failure)),
              trailing: failure != null && translationNeedsSettings(failure)
                  ? TextButton(
                      onPressed: () => openTranslationSettings(context),
                      child: Text(l10n.translationOpenSettings),
                    )
                  : null,
              enabled: !translating,
              onTap: () => unawaited(
                failure == null
                    ? toggleTranslation([widget.tag])
                    : retryTranslation([widget.tag]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
              child: TranslationPanel(
                translating: translating,
                translations: translations,
                // Shown on the row above.
                failure: null,
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
