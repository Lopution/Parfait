import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/display_actions.dart';
import '../../../app/widgets/settings/settings_action_tile.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_group_content.dart';
import '../../../core/download/download_destination.dart';
import '../../../core/platform/saf_tree.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../saf_tree_name.dart';
import '../settings_helpers.dart';
import '../../../app/clipboard.dart';
import '../settings_catalog.dart';
import '../../../app/layout/content_widths.dart';
import '../../../app/icons/app_icons.dart';
import '../../../app/icons/ui_icons.dart';

/// Single-entry save location chooser (D5): album vs SAF folder. Album
/// defaults to the built-in Parfait album with an optional custom name;
/// folder mode only accepts the system SAF tree URI.
class DownloadDestinationPage extends ConsumerStatefulWidget {
  const DownloadDestinationPage({super.key});

  @override
  ConsumerState<DownloadDestinationPage> createState() =>
      _DownloadDestinationPageState();
}

class _DownloadDestinationPageState
    extends ConsumerState<DownloadDestinationPage> {
  late final TextEditingController _albumController;

  /// The custom album name is a draft (explicit 保存 commit), so an
  /// uncommitted edit counts as dirty for the leave guard — same contract
  /// as the browse custom source and download naming template fields.
  bool _albumDirty = false;

  @override
  void initState() {
    super.initState();
    _albumController = TextEditingController();
  }

  @override
  void dispose() {
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _saveAlbum() async {
    final trimmed = _albumController.text.trim();
    final DownloadDestination next;
    final String? committedName;
    if (trimmed.isEmpty) {
      next = DownloadDestination.builtin;
      committedName = null;
    } else {
      final name = DownloadDestination.normalizeAlbumName(trimmed);
      if (name == null) {
        showAppSnackBar(context, context.l10n.saveLocationAlbumInvalid);
        return;
      }
      next = DownloadDestination.customAlbum(name);
      committedName = name;
    }
    final saved = await persistSettings(
      context,
      () => ref.read(settingsProvider.notifier).setDownloadDestination(next),
    );
    if (saved && mounted) {
      // Committed: the draft became the persisted value, so leaving no
      // longer needs the discard prompt — unless it was edited during the
      // write, when it is a newer draft.
      final currentTrimmed = _albumController.text.trim();
      setState(
        () => _albumDirty = committedName == null
            ? currentTrimmed.isNotEmpty
            : DownloadDestination.normalizeAlbumName(currentTrimmed) !=
                  committedName,
      );
      showAppSnackBar(context, context.l10n.saved);
    }
  }

  Future<void> _resetDestination() async {
    final saved = await persistSettings(
      context,
      () => ref
          .read(settingsProvider.notifier)
          .setDownloadDestination(DownloadDestination.builtin),
    );
    if (saved && mounted) {
      _albumController.clear();
      setState(() => _albumDirty = false);
      showAppSnackBar(context, context.l10n.saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(context, ref, state, titleKey: 'saveLocation');
    }
    final destination = settings.downloadDestination;
    // A dirty field is the user's uncommitted draft: never sync the
    // persisted value over it. A clean field tracks the stored name.
    if (!_albumDirty &&
        _albumController.text != (destination.customAlbumName ?? '')) {
      _albumController.text = destination.customAlbumName ?? '';
    }
    final trimmedAlbum = _albumController.text.trim();
    final savedAlbum = destination.customAlbumName?.trim() ?? '';
    final canSaveAlbum = trimmedAlbum != savedAlbum;
    final hasCustomDestination =
        destination.isSafFolder || savedAlbum.isNotEmpty;
    final platform = Theme.of(context).platform;
    final isIOS = platform == TargetPlatform.iOS;
    final isDesktop =
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
    return guardDraft(
      dirty: _albumDirty,
      child: Scaffold(
        appBar: AppTopBar(
          contentWidth: ContentWidths.settings,
          title: Text(context.l10n.saveLocation),
        ),
        body: settingsNarrowBody(
          ListView(
            padding: const EdgeInsets.only(
              top: FuncSpacing.sm,
              bottom: FuncSpacing.xl,
            ),
            children: [
              SettingsGroup(
                setting: Setting.saveLocationAlbum,
                children: [
                  SettingsChoiceTile(
                    title: Text(
                      isDesktop
                          ? context.l10n.saveLocationDesktopFolder
                          : context.l10n.saveLocationAlbum,
                    ),
                    selected: !destination.isSafFolder,
                    onTap: () => persistSettings(
                      context,
                      () => ref
                          .read(settingsProvider.notifier)
                          .setDownloadDestination(DownloadDestination.builtin),
                    ),
                  ),
                  // The field and its save are one row.
                  SettingsGroupContent(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _albumController,
                          decoration: InputDecoration(
                            labelText: isDesktop
                                ? context
                                      .l10n
                                      .saveLocationDesktopCustomSubfolder
                                : context.l10n.saveLocationCustomAlbum,
                            helperText:
                                context.l10n.saveLocationCustomAlbumHint,
                            helperMaxLines: 3,
                          ),
                          maxLength: 64,
                          onChanged: (value) => setState(
                            () => _albumDirty =
                                value != (destination.customAlbumName ?? ''),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: canSaveAlbum ? _saveAlbum : null,
                            child: Text(context.l10n.save),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!isIOS)
                SettingsGroup(
                  setting: Setting.saveLocationSafFolder,
                  children: [
                    SettingsChoiceTile(
                      title: Text(
                        isDesktop
                            ? context.l10n.saveLocationDesktopCustomFolder
                            : context.l10n.saveLocationSafFolder,
                      ),
                      selected: destination.isSafFolder,
                      onTap: () => _pickSafFolder(),
                    ),
                    if (destination.isSafFolder)
                      Builder(
                        builder: (context) {
                          final rawUri = destination.safTreeUri ?? '';
                          final isBookmark = isMacosSecurityBookmark(rawUri);
                          final copiedMessage = isDesktop
                              ? context.l10n.saveLocationPathCopied
                              : context.l10n.saveLocationUriCopied;
                          void copyPath() => unawaited(
                            _copySafUri(rawUri, copiedMessage: copiedMessage),
                          );
                          return GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onSecondaryTapUp: isBookmark
                                ? null
                                : (details) => unawaited(
                                    showDisplayActions(
                                      context,
                                      position: details.globalPosition,
                                      kind: details.kind,
                                      onLongPress: copyPath,
                                      actions: [
                                        DisplayAction(
                                          icon: AppIcons.copy,
                                          label: context.l10n.copy,
                                          onSelected: copyPath,
                                        ),
                                      ],
                                    ),
                                  ),
                            child: ListTile(
                              leading: const Icon(UiIcons.checkCircle),
                              selected: true,
                              // Headline is the human-readable tree name (or macOS
                              // bookmark label); raw URIs/paths drop to a truncated
                              // subtitle and stay reachable via copy button, context
                              // menu, or touch long-press.
                              title: Text(
                                safTreeDisplayName(context.l10n, rawUri),
                              ),
                              subtitle: isBookmark
                                  ? null
                                  : Text(
                                      rawUri,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              trailing: isBookmark
                                  ? null
                                  : IconButton(
                                      tooltip: context.l10n.copy,
                                      icon: const Icon(AppIcons.copy),
                                      onPressed: copyPath,
                                    ),
                              onLongPress: isBookmark ? null : copyPath,
                              // The copy's success haptic confirms the long press;
                              // the tile's own vibration would double it.
                              enableFeedback: false,
                            ),
                          );
                        },
                      ),
                  ],
                ),
              if (hasCustomDestination)
                SettingsGroup(
                  children: [
                    SettingsActionTile(
                      icon: UiIcons.reset,
                      title: Text(context.l10n.restoreDefault),
                      onTap: () => unawaited(_resetDestination()),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickSafFolder() async {
    final uri = await ref.read(safTreePickerProvider).pickTree();
    if (uri == null || !mounted) return;
    final saved = await persistSettings(
      context,
      () => ref
          .read(settingsProvider.notifier)
          .setDownloadDestination(DownloadDestination.safFolder(uri)),
    );
    if (saved && mounted) {
      showAppSnackBar(context, context.l10n.saved);
    }
  }

  /// Long-press on the picked SAF/folder tile copies the raw tree URI or path —
  /// the truncated subtitle is enough to recognize the pick, copying keeps
  /// the technical identifier reachable for support/debugging.
  Future<void> _copySafUri(String? uri, {String? copiedMessage}) async {
    if (uri == null || uri.isEmpty) return;
    await copyToClipboard(
      context,
      uri,
      message: copiedMessage ?? context.l10n.saveLocationUriCopied,
    );
  }
}
