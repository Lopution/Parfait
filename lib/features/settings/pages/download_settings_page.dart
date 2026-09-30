import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_group_content.dart';
import '../../../app/widgets/settings/settings_tile.dart';
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
            padding: const EdgeInsets.only(
              top: FuncSpacing.sm,
              bottom: FuncSpacing.xl,
            ),
            children: [
              SettingsGroup(
                footer: Text(context.l10n.maxDownloadCountHint),
                children: [
                  SettingsGroupContent(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${context.l10n.maxDownloadCount}: $_draftMaxDownloads',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  // immediate-with-preview (D2): the thumb previews
                  // `_draftMaxDownloads`, the write commits on release and a
                  // failure rolls the draft back to the persisted count.
                  SettingsGroupContent(
                    child: Slider(
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
                  ),
                ],
              ),
              SettingsGroup(
                children: [
                  SettingsTile(
                    title: context.l10n.saveLocation,
                    subtitle: Text(
                      downloadDestinationLabel(context, destination),
                    ),
                    onTap: () =>
                        context.push<void>('/settings/download/destination'),
                  ),
                  SettingsControl(
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
                ],
              ),
              SettingsGroup(
                title: Text(context.l10n.namingPreset),
                children: [
                  for (final preset in NamingPreset.values)
                    SettingsChoiceTile(
                      title: Text(namingPresetLabel(context, preset)),
                      selected: namingRule.preset == preset,
                      onTap: () => persistSettings(
                        context,
                        () => ref
                            .read(settingsProvider.notifier)
                            .setNamingRule(NamingRule(preset: preset)),
                      ),
                    ),
                  if (namingRule.preset == NamingPreset.custom) ...[
                    SettingsGroupContent(
                      child: TextField(
                        controller: _templateController,
                        focusNode: _templateFocusNode,
                        decoration: InputDecoration(
                          labelText: context.l10n.namingTemplate,
                          // The hint is the template syntax itself: the
                          // parameterized getter can't go through the
                          // key-based `settingsText` lookup (it would return
                          // the raw key).
                          hintText: context.l10n.namingTemplateHint(
                            '{artist}',
                            '{title}',
                            '{id}',
                            '{page}',
                            '{ext}',
                          ),
                          errorText:
                              !NamingRule.isValidTemplate(
                                _templateController.text,
                              )
                              ? context.l10n.namingTemplateInvalid
                              : null,
                        ),
                        maxLength: 128,
                        onChanged: (_) => setState(() => _templateDirty = true),
                      ),
                    ),
                    SettingsGroupContent(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${context.l10n.namingPreview}: '
                          '${_previewName(context, namingRule.preset == NamingPreset.custom ? NamingRule(preset: NamingPreset.custom, template: _templateController.text) : namingRule)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    SettingsGroupContent(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          context.l10n.namingTemplateVariables(
                            NamingRule.supportedVariables
                                .map((name) => '{$name}')
                                .join(' '),
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    // An invalid template disables the action instead of
                    // silently no-op'ing — the errorText already explains
                    // why.
                    SettingsGroupContent(
                      child: FilledButton(
                        onPressed:
                            NamingRule.isValidTemplate(_templateController.text)
                            ? _saveTemplate
                            : null,
                        child: Text(context.l10n.save),
                      ),
                    ),
                  ],
                ],
              ),
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
