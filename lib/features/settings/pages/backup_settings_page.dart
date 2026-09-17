import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/motion/app_overlays.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/settings/settings_section.dart';
import '../../../core/backup/backup_envelope.dart';
import '../../../core/backup/backup_service.dart';
import '../../../l10n/context.dart';

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

  /// Merge/overwrite is an explicit user choice — never implied. The
  /// overwrite note must state that the server mute list is add-only, so
  /// "overwrite" cannot be read as "delete everything remotely first".
  Future<BackupImportStrategy?> _pickStrategy(BackupEnvelope envelope) {
    final l10n = context.l10n;
    return showAppDialog<BackupImportStrategy>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.backupImportStrategyTitle),
        content: Text(
          '${l10n.backupImportPrompt(envelope.muteTags.length, envelope.muteUsers.length, envelope.muteWorkIds.length, envelope.history.length, envelope.accountId ?? '—')}\n\n${l10n.backupImportOverwriteNote}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, BackupImportStrategy.merge),
            child: Text(l10n.backupMerge),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, BackupImportStrategy.overwrite),
            child: Text(l10n.backupOverwrite),
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
      body: ListView(
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
    );
  }
}
