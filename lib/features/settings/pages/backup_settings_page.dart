import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/motion/app_overlays.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/settings/settings_section.dart';
import '../../../core/backup/backup_envelope.dart';
import '../../../core/backup/backup_service.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

/// Platform file open for backup import. Behind a provider so widget tests
/// can inject bytes without a platform file picker.
final backupFilePickerProvider = Provider<Future<List<int>?> Function()>(
  (ref) => () async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    return file?.readAsBytes();
  },
);

/// Export/import entry for the `pixivfunc.backup.v1` document. Export picks
/// a SAF tree and streams the JSON; import parses the file, asks for the
/// merge/overwrite strategy explicitly, then applies through
/// [BackupService].
class BackupSettingsPage extends ConsumerStatefulWidget {
  const BackupSettingsPage({super.key});

  @override
  ConsumerState<BackupSettingsPage> createState() => _BackupSettingsPageState();
}

class _BackupSettingsPageState extends ConsumerState<BackupSettingsPage> {
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final result = await ref.read(backupServiceProvider).export();
      if (!mounted || result == null) return;
      showAppSnackBar(context, context.l10n.backupExported(result.fileName));
    } on Object catch (error) {
      if (mounted) {
        showAppSnackBar(context, '${context.l10n.backupExportFailed}: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final bytes = await ref.read(backupFilePickerProvider)();
    if (!mounted || bytes == null) return;
    final BackupEnvelope envelope;
    try {
      envelope = BackupEnvelope.parse(bytes);
    } on BackupImportException catch (error) {
      showAppSnackBar(
        context,
        '${context.l10n.backupImportInvalid}: ${error.publicMessage}',
      );
      return;
    }
    final strategy = await _pickStrategy(envelope);
    if (strategy == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(backupServiceProvider)
          .apply(envelope, strategy);
      if (mounted) {
        showAppSnackBar(
          context,
          context.l10n.backupImportDone(
            result.tagsAdded,
            result.usersAdded,
            result.workMutesChanged,
            result.historyRows,
          ),
        );
      }
    } on Object catch (error) {
      if (mounted) {
        showAppSnackBar(context, '${context.l10n.backupImportFailed}: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Merge/overwrite is an explicit two-step choice — never implied (R7):
  /// step 1 picks the strategy among equal-weight options (继续 stays
  /// disabled until a pick), step 2 confirms against the consequence
  /// restated in the title. Both strategies share the same confirm weight —
  /// the old single dialog nudged towards overwrite with the only filled
  /// action.
  Future<BackupImportStrategy?> _pickStrategy(BackupEnvelope envelope) async {
    final l10n = context.l10n;
    final strategy = await showAppDialog<BackupImportStrategy>(
      context: context,
      builder: (dialogContext) => _BackupStrategyChoiceDialog(
        summary: l10n.backupImportPrompt(
          envelope.muteTags.length,
          envelope.muteUsers.length,
          envelope.muteWorkIds.length,
          envelope.history.length,
          envelope.accountId ?? '—',
        ),
      ),
    );
    if (strategy == null || !mounted) return null;
    return _confirmStrategy(envelope, strategy);
  }

  /// Step 2 restates the picked consequence in the title; overwrite keeps
  /// the add-only server-mute note as the body so "覆盖" cannot be read as
  /// "delete everything remotely first".
  Future<BackupImportStrategy?> _confirmStrategy(
    BackupEnvelope envelope,
    BackupImportStrategy strategy,
  ) {
    final l10n = context.l10n;
    return showAppDialog<BackupImportStrategy>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // Landscape/大字号下标题+说明+按钮可能超过弹窗高度——可滚动避免溢出。
        scrollable: true,
        title: Text(switch (strategy) {
          BackupImportStrategy.merge => l10n.backupImportMergeConfirmTitle(
            envelope.muteTags.length,
            envelope.muteUsers.length,
            envelope.muteWorkIds.length,
            envelope.history.length,
          ),
          BackupImportStrategy.overwrite =>
            l10n.backupImportOverwriteConfirmTitle,
        }),
        content: switch (strategy) {
          BackupImportStrategy.merge => null,
          BackupImportStrategy.overwrite => Text(
            l10n.backupImportOverwriteNote,
          ),
        },
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, strategy),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.backupSettings)),
      body: settingsNarrowBody(
        ListView(
          children: [
            SettingsSection(title: Text(l10n.backupSettings)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.backupHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.file_upload_outlined),
              title: Text(l10n.backupExport),
              subtitle: Text(l10n.backupExportHint),
              enabled: !_busy,
              onTap: _export,
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: Text(l10n.backupImport),
              subtitle: Text(l10n.backupImportHint),
              enabled: !_busy,
              onTap: _import,
            ),
          ],
        ),
      ),
    );
  }
}

/// Step 1 of the import flow: file summary plus the two equal-weight
/// strategy options. The same [showAppDialog] presentation serves mobile
/// and desktop, so the action order is identical on both.
/// ListTile+check follows the project selection pattern — RadioListTile is
/// deprecated on this Flutter version.
class _BackupStrategyChoiceDialog extends StatefulWidget {
  const _BackupStrategyChoiceDialog({required this.summary});

  final String summary;

  @override
  State<_BackupStrategyChoiceDialog> createState() =>
      _BackupStrategyChoiceDialogState();
}

class _BackupStrategyChoiceDialogState
    extends State<_BackupStrategyChoiceDialog> {
  BackupImportStrategy? _selected;

  Widget _option({
    required BackupImportStrategy value,
    required String title,
    required String hint,
  }) {
    final selected = _selected == value;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      selected: selected,
      title: Text(title),
      subtitle: Text(hint),
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () => setState(() => _selected = value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      // Same landscape/大字号 overflow guard as the confirm step.
      scrollable: true,
      title: Text(l10n.backupImportStrategyTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.summary),
          const SizedBox(height: 8),
          _option(
            value: BackupImportStrategy.merge,
            title: l10n.backupMerge,
            hint: l10n.backupMergeHint,
          ),
          _option(
            value: BackupImportStrategy.overwrite,
            title: l10n.backupOverwrite,
            hint: l10n.backupOverwriteHint,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(context, _selected),
          child: Text(l10n.continueAction),
        ),
      ],
    );
  }
}
