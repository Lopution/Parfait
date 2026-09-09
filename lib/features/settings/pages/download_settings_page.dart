import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/motion/replica_page_route.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../core/download/download_destination.dart';
import '../../../core/download/naming_rule.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';
import 'download_destination_page.dart';

class DownloadSettingsPage extends ConsumerStatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  ConsumerState<DownloadSettingsPage> createState() =>
      _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends ConsumerState<DownloadSettingsPage> {
  late final TextEditingController _templateController;
  late final FocusNode _templateFocusNode;
  int? _draftMaxDownloads;

  @override
  void initState() {
    super.initState();
    _templateController = TextEditingController();
    _templateFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _templateController.dispose();
    _templateFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'downloadSettings',
      );
    }
    _draftMaxDownloads ??= settings.maxDownloadCount;
    final namingRule = settings.namingRule;
    if (!_templateFocusNode.hasFocus &&
        _templateController.text != (namingRule.template ?? '')) {
      _templateController.text = namingRule.template ?? '';
    }
    final destination = settings.downloadDestination;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.downloadSettings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${context.l10n.maxDownloadCount}: $_draftMaxDownloads',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Slider(
            min: 1,
            max: 10,
            divisions: 9,
            value: (_draftMaxDownloads ?? settings.maxDownloadCount).toDouble(),
            label: '$_draftMaxDownloads',
            onChanged: (value) =>
                setState(() => _draftMaxDownloads = value.round()),
            onChangeEnd: (value) => _saveMaxDownloads(value.round()),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.saveLocation),
            subtitle: Text(_destinationText(context, destination)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              ReplicaPageRoute<void>(
                builder: (_) => const DownloadDestinationPage(),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
            child: Text(
              context.l10n.namingPreset,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final preset in NamingPreset.values)
            ListTile(
              title: Text(_namingPresetText(context, preset)),
              trailing: namingRule.preset == preset
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .setNamingRule(NamingRule(preset: preset)),
              ),
            ),
          if (namingRule.preset == NamingPreset.custom) ...[
            TextField(
              controller: _templateController,
              focusNode: _templateFocusNode,
              decoration: InputDecoration(
                labelText: context.l10n.namingTemplate,
                hintText: settingsText(context, 'namingTemplateHint'),
                errorText: !NamingRule.isValidTemplate(_templateController.text)
                    ? context.l10n.namingTemplateInvalid
                    : null,
              ),
              maxLength: 128,
              onChanged: (_) => setState(() {}),
            ),
            Text(
              '${context.l10n.namingPreview}: '
              '${_previewName(context, namingRule.preset == NamingPreset.custom ? NamingRule(preset: NamingPreset.custom, template: _templateController.text) : namingRule)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.namingTemplateVariables(
                '{artist}',
                '{title}',
                '{id}',
                '{page}',
                '{ext}',
                '{date}',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            FilledButton(
              onPressed: () async {
                final template = _templateController.text.trim();
                if (!NamingRule.isValidTemplate(template)) return;
                final saved = await persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .setNamingRule(
                        NamingRule(
                          preset: NamingPreset.custom,
                          template: template,
                        ),
                      ),
                );
                if (saved && context.mounted) {
                  showAppSnackBar(context, context.l10n.saved);
                }
              },
              child: Text(context.l10n.save),
            ),
          ],
        ],
      ),
    );
  }

  String _previewName(BuildContext context, NamingRule rule) {
    final preview = rule.preview(
      illustId: 123456,
      pageIndex: 0,
      extension: 'jpg',
      artist: '作者名',
      title: '作品标题',
      date: DateTime(2026, 9, 1),
    );
    return preview;
  }

  Future<void> _saveMaxDownloads(int value) async {
    final previous = _draftMaxDownloads;
    final saved = await persistSettings(
      context,
      () => ref.read(settingsProvider.notifier).setMaxDownloadCount(value),
    );
    if (!saved && mounted) {
      final committed = ref.read(settingsProvider).value?.maxDownloadCount;
      setState(() => _draftMaxDownloads = committed ?? previous);
    }
  }
}

String _destinationText(BuildContext context, DownloadDestination destination) {
  return switch (destination.kind) {
    DownloadDestinationKind.pixivAlbum => context.l10n.saveLocationPixivAlbum,
    DownloadDestinationKind.customAlbum =>
      '${context.l10n.saveLocationCustomAlbum} '
          '(${destination.customAlbumName})',
    DownloadDestinationKind.safFolder => context.l10n.saveLocationSafFolder,
  };
}

String _namingPresetText(BuildContext context, NamingPreset preset) {
  return switch (preset) {
    NamingPreset.id => context.l10n.namingPresetId,
    NamingPreset.artistTitleId => context.l10n.namingPresetArtistTitleId,
    NamingPreset.titleId => context.l10n.namingPresetTitleId,
    NamingPreset.custom => context.l10n.namingPresetCustom,
  };
}
