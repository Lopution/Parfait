import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/motion/replica_page_route.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';
import 'translation_credentials_page.dart';

class TranslateSettingsPage extends ConsumerWidget {
  const TranslateSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      body: ListView(
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
              onTap: () => _openTranslationCredentials(context, ref, true),
            ),
          if (settings.translationProvider ==
              TranslationProvider.translationLlm)
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(context.l10n.translateLlmCredential),
              onTap: () => _openTranslationCredentials(context, ref, false),
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
    );
  }

  void _openTranslationCredentials(
    BuildContext context,
    WidgetRef ref,
    bool baidu,
  ) {
    Navigator.of(context).push<void>(
      ReplicaPageRoute<void>(
        builder: (_) => TranslationCredentialsPage(baidu: baidu),
      ),
    );
  }
}
