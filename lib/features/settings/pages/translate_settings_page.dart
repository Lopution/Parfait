import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/motion/spring_size.dart';
import '../../../app/motion/state_fade.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/app_menu_button.dart';
import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_menu_tile.dart';
import '../../../app/widgets/settings/settings_tile.dart';
import '../../../core/translation/translation_service.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';
import '../settings_catalog.dart';

class TranslateSettingsPage extends ConsumerStatefulWidget {
  const TranslateSettingsPage({super.key});

  @override
  ConsumerState<TranslateSettingsPage> createState() =>
      _TranslateSettingsPageState();
}

class _TranslateSettingsPageState extends ConsumerState<TranslateSettingsPage> {
  /// Key-existence probes behind the credential entry summaries (D8):
  /// they answer "configured?" without loading secret values. Re-read
  /// when the credentials route pops — the sub-page may have written or
  /// cleared keys while this route was covered.
  Future<bool>? _baiduConfigured;
  Future<bool>? _llmConfigured;

  @override
  void initState() {
    super.initState();
    _refreshCredentials();
  }

  void _refreshCredentials() {
    final store = ref.read(translationCredentialStoreProvider);
    _baiduConfigured = store.hasBaidu();
    _llmConfigured = store.hasLlm();
  }

  Future<void> _openTranslationCredentials(bool baidu) async {
    final provider = baidu ? 'baidu' : 'llm';
    await context.push<void>('/settings/translate/credentials/$provider');
    if (mounted) setState(_refreshCredentials);
  }

  /// The account or credential row of [provider], if it has one.
  Widget? _providerRow(TranslationProvider provider) => switch (provider) {
    TranslationProvider.baidu => SettingsTile(
      icon: Icons.key_outlined,
      title: context.l10n.translateBaiduCredential,
      subtitle: _credentialStatus(_baiduConfigured),
      onTap: () => _openTranslationCredentials(true),
    ),
    TranslationProvider.translationLlm => SettingsTile(
      icon: Icons.key_outlined,
      title: context.l10n.translateLlmCredential,
      subtitle: _credentialStatus(_llmConfigured),
      onTap: () => _openTranslationCredentials(false),
    ),
    _ => null,
  };

  /// Subtitle under a credential entry. Pending or a store error renders
  /// nothing — the summary never invents a state.
  Widget _credentialStatus(Future<bool>? configured) {
    return FutureBuilder<bool>(
      future: configured,
      builder: (context, snapshot) {
        final state = snapshot.data;
        if (state == null) return const SizedBox.shrink();
        return Text(
          state
              ? context.l10n.settingsCredentialConfigured
              : context.l10n.settingsCredentialNotConfigured,
        );
      },
    );
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
        titleKey: 'translateSettings',
      );
    }
    final provider = settings.translationProvider;
    final items = [
      (TranslationProvider.disabled, context.l10n.translateDisabled),
      (TranslationProvider.baidu, context.l10n.translateBaidu),
      (TranslationProvider.translationLlm, context.l10n.translateLlm),
      (TranslationProvider.indexTranslate, context.l10n.translateIndex),
      (TranslationProvider.google, context.l10n.translateGoogle),
    ];
    return Scaffold(
      appBar: AppTopBar(title: Text(context.l10n.translateSettings)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            // A provider's own row comes and goes with it: the group
            // springs to its new height and the row fades in.
            SpringSize(
              child: SettingsGroup(
                setting: Setting.translationProvider,
                children: [
                  for (final item in items)
                    SettingsChoiceTile(
                      title: Text(item.$2),
                      selected: provider == item.$1,
                      onTap: () => persistSettings(
                        context,
                        () => ref
                            .read(settingsProvider.notifier)
                            .selectTranslationProvider(item.$1),
                      ),
                    ),
                  if (_providerRow(provider) case final row?)
                    StateFade(kind: provider, child: row),
                ],
              ),
            ),
            SettingsGroup(
              children: [
                SettingsMenuTile<IndexTranslateModel>(
                  setting: Setting.indexTranslateModel,
                  value: settings.indexTranslateModel,
                  options: [
                    for (final model in IndexTranslateModel.values)
                      AppMenuEntry(
                        value: model,
                        label: switch (model) {
                          IndexTranslateModel.twoB =>
                            context.l10n.translateIndexModel2B,
                          IndexTranslateModel.nineB =>
                            context.l10n.translateIndexModel9B,
                          IndexTranslateModel.thirtyFiveBA3B =>
                            context.l10n.translateIndexModel35B,
                        },
                      ),
                  ],
                  onChanged: provider == TranslationProvider.indexTranslate
                      ? (model) => persistSettings(
                          context,
                          () => ref
                              .read(settingsProvider.notifier)
                              .selectIndexTranslateModel(model),
                        )
                      : null,
                ),
                SettingsControl(
                  setting: Setting.indexTranslateThinking,
                  subtitle: Text(context.l10n.translateIndexThinkingHint),
                  value: settings.indexTranslateThinking,
                  onChanged: provider == TranslationProvider.indexTranslate
                      ? (enabled) => persistSettings(
                          context,
                          () => ref
                              .read(settingsProvider.notifier)
                              .setIndexTranslateThinking(enabled),
                        )
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
