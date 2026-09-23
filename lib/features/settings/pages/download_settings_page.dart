import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/widgets/app_snack_bar.dart';
import '../../../core/download/naming_rule.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

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
  bool _templateDirty = false;

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
    // The sync respects the draft: an uncommitted edit survives unrelated
    // rebuilds (slider preview, preset taps) until Save commits or the
    // leave-guard drops it.
    if (!_templateDirty &&
        _templateController.text != (namingRule.template ?? '')) {
      _templateController.text = namingRule.template ?? '';
    }
    final destination = settings.downloadDestination;
    return guardDraft(
      dirty: _templateDirty,
      child: Scaffold(
        appBar: AppBar(title: Text(context.l10n.downloadSettings)),
        body: settingsNarrowBody(
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '${context.l10n.maxDownloadCount}: $_draftMaxDownloads',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              // immediate-with-preview (D2): the thumb previews
              // `_draftMaxDownloads`, the write commits on release and a
              // failure rolls the draft back to the persisted count.
              Slider(
                min: 1,
                max: 10,
                divisions: 9,
                value: (_draftMaxDownloads ?? settings.maxDownloadCount)
                    .toDouble(),
                label: '$_draftMaxDownloads',
                onChanged: (value) =>
                    setState(() => _draftMaxDownloads = value.round()),
                onChangeEnd: (value) => _saveMaxDownloads(value.round()),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  context.l10n.maxDownloadCountHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.saveLocation),
                subtitle: Text(downloadDestinationLabel(context, destination)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    context.push<void>('/settings/download/destination'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.downloadCaption),
                subtitle: Text(context.l10n.downloadCaptionHint),
                value: settings.downloadCaption,
                onChanged: (enabled) => persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .setDownloadCaption(enabled),
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
                  title: Text(namingPresetLabel(context, preset)),
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
                    errorText:
                        !NamingRule.isValidTemplate(_templateController.text)
                        ? context.l10n.namingTemplateInvalid
                        : null,
                  ),
                  maxLength: 128,
                  onChanged: (_) => setState(() => _templateDirty = true),
                ),
                Text(
                  '${context.l10n.namingPreview}: '
                  '${_previewName(context, namingRule.preset == NamingPreset.custom ? NamingRule(preset: NamingPreset.custom, template: _templateController.text) : namingRule)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.namingTemplateVariables(
                    NamingRule.supportedVariables
                        .map((name) => '{$name}')
                        .join(' '),
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                // An invalid template disables the action instead of
                // silently no-op'ing — the errorText already explains why.
                FilledButton(
                  onPressed:
                      NamingRule.isValidTemplate(_templateController.text)
                      ? _saveTemplate
                      : null,
                  child: Text(context.l10n.save),
                ),
              ],
            ],
          ),
        ),
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

  Future<void> _saveTemplate() async {
    final template = _templateController.text.trim();
    if (!NamingRule.isValidTemplate(template)) return;
    final saved = await persistSettings(
      context,
      () => ref
          .read(settingsProvider.notifier)
          .setNamingRule(
            NamingRule(preset: NamingPreset.custom, template: template),
          ),
    );
    if (saved && mounted) {
      setState(() => _templateDirty = false);
      showAppSnackBar(context, context.l10n.saved);
    }
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
