import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/func_tokens.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/replica_switch_tile.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../app/motion/replica_page_route.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/account_transfer.dart';
import '../../core/auth/account_transfer_service.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/network/compat/network_contracts.dart' as network_contracts;
import '../../core/network/compat/network_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import 'login_webview_page.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/lookup.dart';
import '../../l10n/context.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({
    super.key,
    this.isFirst = false,
    this.returnToHomeOnSuccess = false,
    this.onRegister,
    this.onLogin,
    this.onClipboardLogin,
  });

  final bool isFirst;

  /// Startup/onboarding login is a gate route.  Once the WebView reports a
  /// confirmed account, remove the gate stack so the rebuilt StartupGate can
  /// show Home immediately.  Settings keeps this false so adding an account
  /// does not unexpectedly close the settings flow.
  final bool returnToHomeOnSuccess;
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
    _networkMode = switch (ref.read(networkAccessPolicyProvider).mode) {
      network_contracts.NetworkMode.automatic => NetworkMode.automatic,
      network_contracts.NetworkMode.directOnly => NetworkMode.directOnly,
    };
  }

  Future<void> _openLoginWebview({bool create = false}) async {
    // R7 was cancelled: the first login always uses the stable webview_flutter
    // path (C16). The native interception entry is removed.
    final result = await Navigator.of(context).push<bool>(
      ReplicaPageRoute<bool>(
        builder: (_) => LoginWebViewPage(
          oauthService: ref.read(oauthServiceProvider),
          create: create,
        ),
      ),
    );
    if (!mounted || result != true || !widget.returnToHomeOnSuccess) return;
    // The account store is updated before the WebView pops.  Popping the
    // onboarding/login routes now lets StartupGate rebuild to Home without
    // leaving the user stranded on a stale login surface.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _persistNetworkMode(NetworkMode mode) {
    unawaited(() async {
      try {
        await ref.read(settingsProvider.notifier).setNetworkMode(mode);
      } on Object catch (error) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          '${_loginText('settingsWriteFailed')}: $error',
        );
      }
    }());
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
        showAppSnackBar(context, _loginText('accountTransferImported'));
        if (!result.clipboardCleared) {
          showAppSnackBar(
            context,
            _loginText('accountTransferClipboardReplaced'),
          );
        }
      } on AccountTransferException catch (error) {
        if (mounted) {
          showAppSnackBar(context, _loginTransferErrorText(error.code));
        }
      } finally {
        if (mounted) setState(() => _clipboardBusy = false);
      }
    }());
  }

  String _loginText(String key) => l10nLookup(context.l10n, key);

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
          loading: () => const ReplicaScaffold(
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => ReplicaScaffold(
            child: SettingsLoadError(
              error: error,
              onRetry: () => ref.read(settingsProvider.notifier).reload(),
            ),
          ),
          data: (settings) => _buildSettings(context, settings),
        );
  }

  Widget _buildSettings(BuildContext context, AppSettings settings) {
    final language = ReplicaLanguage.fromTag(settings.languageTag);
    String text(String key) => l10nLookupFor(language.locale, key);
    final onClipboardLogin = widget.onClipboardLogin ?? _importFromClipboard;
    final title = Text(
      text('loginTitle'),
      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
    );

    return ReplicaScaffold(
      title: widget.isFirst ? null : title,
      child: _buildBody(
        context,
        title: title,
        text: text,
        onClipboardLogin: onClipboardLogin,
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required Text title,
    required String Function(String) text,
    required VoidCallback onClipboardLogin,
  }) {
    return Padding(
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
            child: _buildNetworkOptions(
              context,
              text: text,
              onClipboardLogin: onClipboardLogin,
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
    );
  }

  Widget _buildNetworkOptions(
    BuildContext context, {
    required String Function(String) text,
    required VoidCallback onClipboardLogin,
  }) {
    return Column(
      children: [
        ReplicaSwitchTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 6),
          value: _networkMode == NetworkMode.automatic,
          title: _buildNetworkTitle(context, text),
          onTap: _toggleNetworkMode,
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
                TextSpan(text: text('networkCompatibilityHint')),
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
        ..._buildLoginActions(text, onClipboardLogin),
      ],
    );
  }

  Widget _buildNetworkTitle(
    BuildContext context,
    String Function(String) text,
  ) {
    return Row(
      children: [
        Flexible(
          child: Text(
            text('networkCompatibility'),
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
    );
  }

  void _toggleNetworkMode() {
    setState(() {
      _networkMode = _networkMode == NetworkMode.automatic
          ? NetworkMode.directOnly
          : NetworkMode.automatic;
    });
    ref.read(networkAccessPolicyProvider).setMode(switch (_networkMode) {
      NetworkMode.automatic => network_contracts.NetworkMode.automatic,
      NetworkMode.directOnly => network_contracts.NetworkMode.directOnly,
    });
    _persistNetworkMode(_networkMode);
  }

  List<Widget> _buildLoginActions(
    String Function(String) text,
    VoidCallback onClipboardLogin,
  ) {
    if (_help) {
      return [
        Text(
          text('accountTransferWarning'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
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
            foregroundColor: FuncTokens.lightBackground,
            onPressed: onClipboardLogin,
          ),
        ),
      ];
    }
    return [
      Row(
        children: [
          Expanded(
            child: ReplicaButton(
              label: text('register'),
              backgroundColor: FuncTokens.lightBackground,
              foregroundColor: FuncTokens.primary,
              borderColor: FuncTokens.primary,
              onPressed:
                  widget.onRegister ?? () => _openLoginWebview(create: true),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: ReplicaButton(
              label: text('login'),
              backgroundColor: FuncTokens.primary,
              foregroundColor: FuncTokens.lightBackground,
              onPressed: widget.onLogin ?? () => _openLoginWebview(),
            ),
          ),
        ],
      ),
    ];
  }
}
