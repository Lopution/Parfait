import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/replica_switch_tile.dart';
import '../../core/auth/account_store.dart';
import '../../core/i18n/replica_strings.dart';
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
  bool _useLocalReverseProxy = false;
  bool _help = false;

  void _openLoginWebview({bool create = false}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LoginWebViewPage(
        oauthService: ref.read(oauthServiceProvider),
        create: create,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ref.watch(settingsProvider).when(
          loading: () => const ReplicaScaffold(child: SizedBox.shrink()),
          error: (error, stackTrace) => const ReplicaScaffold(child: SizedBox.shrink()),
          data: (settings) {
            final language = ReplicaLanguage.fromTag(settings.languageTag);
            String text(String key) => ReplicaStrings.text(language, key);
            final title = Text(
              text('loginTitle'),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            );

            return ReplicaScaffold(
              title: widget.isFirst ? null : title,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: MediaQuery.sizeOf(context).width * .1),
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
                            contentPadding: const EdgeInsets.symmetric(vertical: 6),
                            value: _useLocalReverseProxy,
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    text('localReverseProxy'),
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => setState(() => _help = !_help),
                                  child: Icon(
                                    Icons.info_outline,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            onTap: () => setState(
                              () => _useLocalReverseProxy = !_useLocalReverseProxy,
                            ),
                          ),
                          const Divider(),
                          if (_help)
                            RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Theme.of(context).colorScheme.onSecondary,
                                ),
                                children: [
                                  TextSpan(text: text('reverseProxyHint')),
                                  TextSpan(
                                    text: text('getMoreHelp'),
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          if (_help) ...[
                            Text(
                              text('useLoginWithClipboardHint'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ReplicaButton(
                                label: text('useLoginWithClipboard'),
                                backgroundColor: FuncTokens.primary,
                                foregroundColor: Colors.white,
                                onPressed: widget.onClipboardLogin ?? () {},
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
                                    onPressed: widget.onRegister ??
                                    () => _openLoginWebview(create: true),
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Expanded(
                                  child: ReplicaButton(
                                    label: text('login'),
                                    backgroundColor: FuncTokens.primary,
                                    foregroundColor: Colors.white,
                                    onPressed: widget.onLogin ??
                                        () => _openLoginWebview(),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Text(text('loginAgree'), style: const TextStyle(fontSize: 14)),
                    Text(
                      text('userAgreement'),
                      style: const TextStyle(fontSize: 14, color: FuncTokens.primary),
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
