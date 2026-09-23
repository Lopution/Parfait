import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/comments/comment_translation.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

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
    final items = [
      (TranslationProvider.disabled, context.l10n.translateDisabled),
      (TranslationProvider.baidu, context.l10n.translateBaidu),
      (TranslationProvider.translationLlm, context.l10n.translateLlm),
      (TranslationProvider.google, context.l10n.translateGoogle),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.translateSettings)),
      body: settingsNarrowBody(
        ListView(
          children: [
            for (final item in items)
              ListTile(
                title: Text(item.$2),
                trailing: settings.translationProvider == item.$1
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .selectTranslationProvider(item.$1),
                ),
              ),
            if (settings.translationProvider == TranslationProvider.baidu)
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(context.l10n.translateBaiduCredential),
                subtitle: _credentialStatus(_baiduConfigured),
                onTap: () => _openTranslationCredentials(true),
              ),
            if (settings.translationProvider ==
                TranslationProvider.translationLlm)
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(context.l10n.translateLlmCredential),
                subtitle: _credentialStatus(_llmConfigured),
                onTap: () => _openTranslationCredentials(false),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                context.l10n.translateCredentialHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (settings.translationProvider == TranslationProvider.baidu)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  context.l10n.translateBaiduHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
