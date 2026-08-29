import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/replica_switch_tile.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/account_transfer.dart';
import '../../core/auth/account_transfer_service.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/network/compat/network_contracts.dart';
import '../../core/network/compat/network_providers.dart';
import '../../core/settings/settings_controller.dart';
import 'login_webview_page.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({
    super.key,
    this.isFirst = false,
    this.onRegister,
    this.onLogin,
    this.onClipboardLogin,
  });

  final bool isFirst;
  final VoidCallback? onRegister;
  final VoidCallback? onLogin;
  final VoidCallback? onClipboardLogin;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  NetworkMode _networkMode = NetworkMode.automatic;
  bool _help = false;
  bool _clipboardBusy = false;

  @override
  void initState() {
    super.initState();
    _networkMode = ref.read(networkAccessPolicyProvider).mode;
  }

  void _openLoginWebview({bool create = false}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginWebViewPage(
          oauthService: ref.read(oauthServiceProvider),
          create: create,
        ),
      ),
    );
  }

  void _importFromClipboard() {
    if (_clipboardBusy) return;
    setState(() => _clipboardBusy = true);
    unawaited(() async {
      try {
        final result = await ref
            .read(accountTransferServiceProvider)
            .importFromClipboard();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_loginText('accountTransferImported'))),
        );
        if (!result.clipboardCleared) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_loginText('accountTransferClipboardReplaced')),
            ),
          );
        }
      } on AccountTransferException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_loginTransferErrorText(error.code))),
          );
        }
      } finally {
        if (mounted) setState(() => _clipboardBusy = false);
      }
    }());
  }

  String _loginText(String key) => ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );

  String _loginTransferErrorText(AccountTransferErrorCode code) {
    final key = switch (code) {
      AccountTransferErrorCode.corrupt => 'accountTransferCorrupt',
      AccountTransferErrorCode.credentialInvalid =>
        'accountTransferCredentialInvalid',
      AccountTransferErrorCode.verificationUnavailable =>
        'accountTransferVerificationUnavailable',
      AccountTransferErrorCode.noUsableAccount => 'accountTransferNoAccount',
      AccountTransferErrorCode.credentialUnavailable =>
        'accountTransferCredentialUnavailable',
      AccountTransferErrorCode.clipboardUnavailable =>
        'accountTransferClipboardUnavailable',
      AccountTransferErrorCode.storageFailure =>
        'accountTransferStorageFailure',
    };
    return _loginText(key);
  }

  @override
  Widget build(BuildContext context) {
    return ref
        .watch(settingsProvider)
        .when(
          loading: () => const ReplicaScaffold(child: SizedBox.shrink()),
          error: (error, stackTrace) =>
              const ReplicaScaffold(child: SizedBox.shrink()),
          data: (settings) {
            final language = ReplicaLanguage.fromTag(settings.languageTag);
            String text(String key) => ReplicaStrings.text(language, key);
            final onClipboardLogin =
                widget.onClipboardLogin ?? _importFromClipboard;
            final title = Text(
              text('loginTitle'),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            );

            return ReplicaScaffold(
              title: widget.isFirst ? null : title,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: MediaQuery.sizeOf(context).width * .1,
                ),
                child: Column(
                  children: [
                    const Spacer(),
                    if (widget.isFirst) title,
                    const Spacer(flex: 2),
                    SizedBox(
                      height: MediaQuery.sizeOf(context).height * .4,
                      child: Column(
                        children: [
                          ReplicaSwitchTile(
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 6,
                            ),
                            value: _networkMode == NetworkMode.automatic,
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    text('networkCompatibility'),
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => setState(() => _help = !_help),
                                  child: Icon(
                                    Icons.info_outline,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            onTap: () {
                              setState(() {
                                _networkMode =
                                    _networkMode == NetworkMode.automatic
                                    ? NetworkMode.directOnly
                                    : NetworkMode.automatic;
                              });
                              ref
                                  .read(networkAccessPolicyProvider)
                                  .setMode(_networkMode);
                            },
                          ),
                          const Divider(),
                          if (_help)
                            RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondary,
                                ),
                                children: [
                                  TextSpan(
                                    text: text('networkCompatibilityHint'),
                                  ),
                                  TextSpan(
                                    text: text('getMoreHelp'),
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          if (_help) ...[
                            Text(
                              text('accountTransferWarning'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              text('useLoginWithClipboardHint'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ReplicaButton(
                                label: text('useLoginWithClipboard'),
                                backgroundColor: FuncTokens.primary,
                                foregroundColor: Colors.white,
                                onPressed: onClipboardLogin,
                              ),
                            ),
                          ] else
                            Row(
                              children: [
                                Expanded(
                                  child: ReplicaButton(
                                    label: text('register'),
                                    backgroundColor: Colors.white,
                                    foregroundColor: FuncTokens.primary,
                                    borderColor: FuncTokens.primary,
                                    onPressed:
                                        widget.onRegister ??
                                        () => _openLoginWebview(create: true),
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  child: ReplicaButton(
                                    label: text('login'),
                                    backgroundColor: FuncTokens.primary,
                                    foregroundColor: Colors.white,
                                    onPressed:
                                        widget.onLogin ??
                                        () => _openLoginWebview(),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Text(
                      text('loginAgree'),
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      text('userAgreement'),
                      style: const TextStyle(
                        fontSize: 14,
                        color: FuncTokens.primary,
                      ),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            );
          },
        );
  }
}
