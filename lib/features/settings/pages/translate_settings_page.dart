import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/motion/app_overlays.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/settings/settings_choice_tile.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_tile.dart';
import '../../../core/translation/translation_credentials.dart';
import '../../../core/translation/translation_service.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';
import '../settings_catalog.dart';
import 'doubao_login_page.dart';

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
  Future<bool>? _doubaoSignedIn;

  @override
  void initState() {
    super.initState();
    _refreshCredentials();
  }

  void _refreshCredentials() {
    final store = ref.read(translationCredentialStoreProvider);
    _baiduConfigured = store.hasBaidu();
    _llmConfigured = store.hasLlm();
    _doubaoSignedIn = store.hasDoubao();
  }

  Future<void> _openTranslationCredentials(bool baidu) async {
    final provider = baidu ? 'baidu' : 'llm';
    await context.push<void>('/settings/translate/credentials/$provider');
    if (mounted) setState(_refreshCredentials);
  }

  Future<void> _openDoubaoLogin() async {
    await context.push<bool>('/settings/translate/doubao-login');
    if (mounted) setState(_refreshCredentials);
  }

  /// Signing out forgets the saved session and the WebView's doubao.com
  /// cookies, so the next login starts from the login form.
  Future<void> _signOutDoubao() async {
    final l10n = context.l10n;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.translateDoubaoSignOut),
        content: Text(l10n.translateDoubaoSignOutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.translateDoubaoSignOutAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(translationCredentialStoreProvider).deleteDoubao();
      await ref.read(doubaoWebCookiesProvider).clear();
    } on TranslationCredentialsStoreException {
      if (mounted) {
        showAppSnackBar(context, l10n.translateCredentialsStoreError);
      }
    }
    if (mounted) setState(_refreshCredentials);
  }

  Widget _doubaoAccount() {
    return FutureBuilder<bool>(
      future: _doubaoSignedIn,
      builder: (context, snapshot) {
        final signedIn = snapshot.data;
        final l10n = context.l10n;
        return SettingsTile(
          icon: Icons.account_circle_outlined,
          title: l10n.translateDoubaoAccount,
          subtitle: signedIn == null
              ? null
              : Text(
                  signedIn
                      ? l10n.translateDoubaoSignedIn
                      : l10n.translateDoubaoSignedOut,
                ),
          // Pending or a store error: the row waits instead of guessing.
          onTap: switch (signedIn) {
            true => () => unawaited(_signOutDoubao()),
            false => () => unawaited(_openDoubaoLogin()),
            null => () {},
          },
        );
      },
    );
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
      (TranslationProvider.doubao, context.l10n.translateDoubao),
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
            SettingsGroup(
              setting: Setting.translationProvider,
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.translateCredentialHint),
                  if (settings.translationProvider ==
                      TranslationProvider.baidu) ...[
                    const SizedBox(height: FuncSpacing.xs),
                    Text(context.l10n.translateBaiduHint),
                  ],
                  if (settings.translationProvider ==
                      TranslationProvider.doubao) ...[
                    const SizedBox(height: FuncSpacing.xs),
                    Text(context.l10n.translateDoubaoHint),
                  ],
                ],
              ),
              children: [
                for (final item in items)
                  SettingsChoiceTile(
                    title: Text(item.$2),
                    selected: settings.translationProvider == item.$1,
                    onTap: () => persistSettings(
                      context,
                      () => ref
                          .read(settingsProvider.notifier)
                          .selectTranslationProvider(item.$1),
                    ),
                  ),
                if (settings.translationProvider == TranslationProvider.baidu)
                  SettingsTile(
                    icon: Icons.key_outlined,
                    title: context.l10n.translateBaiduCredential,
                    subtitle: _credentialStatus(_baiduConfigured),
                    onTap: () => _openTranslationCredentials(true),
                  ),
                if (settings.translationProvider ==
                    TranslationProvider.translationLlm)
                  SettingsTile(
                    icon: Icons.key_outlined,
                    title: context.l10n.translateLlmCredential,
                    subtitle: _credentialStatus(_llmConfigured),
                    onTap: () => _openTranslationCredentials(false),
                  ),
                if (settings.translationProvider == TranslationProvider.doubao)
                  _doubaoAccount(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
