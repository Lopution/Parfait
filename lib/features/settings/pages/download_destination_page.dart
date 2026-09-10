import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/app_snack_bar.dart';
import '../../../core/download/download_destination.dart';
import '../../../core/platform/saf_tree.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

/// Single-entry save location chooser (D5): album vs SAF folder. Album
/// defaults to the built-in PixivFunc album with an optional custom name;
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
  late final FocusNode _albumFocusNode;

  @override
  void initState() {
    super.initState();
    _albumController = TextEditingController();
    _albumFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _albumController.dispose();
    _albumFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(context, ref, state, titleKey: 'saveLocation');
    }
    final destination = settings.downloadDestination;
    if (!_albumFocusNode.hasFocus &&
        _albumController.text != (destination.customAlbumName ?? '')) {
      _albumController.text = destination.customAlbumName ?? '';
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.saveLocation)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: Text(context.l10n.saveLocationAlbum),
            trailing: !destination.isSafFolder
                ? Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
            onTap: () => persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setDownloadDestination(DownloadDestination.builtin),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 0, 0),
            child: TextField(
              controller: _albumController,
              focusNode: _albumFocusNode,
              decoration: InputDecoration(
                labelText: context.l10n.saveLocationCustomAlbum,
                helperText: context.l10n.saveLocationCustomAlbumHint,
              ),
              maxLength: 64,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 4, 0, 0),
            child: FilledButton.tonal(
              onPressed: () async {
                final name = DownloadDestination.normalizeAlbumName(
                  _albumController.text,
                );
                if (name == null) {
                  showAppSnackBar(
                    context,
                    context.l10n.saveLocationAlbumInvalid,
                  );
                  return;
                }
                final saved = await persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .setDownloadDestination(
                        DownloadDestination.customAlbum(name),
                      ),
                );
                if (saved && context.mounted) {
                  showAppSnackBar(context, context.l10n.saved);
                }
              },
              child: Text(context.l10n.saveLocationUseCustomAlbum),
            ),
          ),
          const Divider(),
          ListTile(
            title: Text(context.l10n.saveLocationSafFolder),
            subtitle: Text(context.l10n.saveLocationSafFolderHint),
            trailing: destination.isSafFolder
                ? Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
            onTap: () => _pickSafFolder(),
          ),
          if (destination.isSafFolder)
            ListTile(
              leading: const Icon(Icons.check_circle),
              title: Text(context.l10n.saveLocationSafPicked),
              subtitle: Text(destination.safTreeUri ?? ''),
            ),
        ],
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
}
