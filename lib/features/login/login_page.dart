import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/replica_button.dart';
import '../../app/widgets/replica_scaffold.dart';
import '../../app/widgets/replica_switch_tile.dart';
import '../../app/widgets/scrollable_form_shell.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/account_transfer.dart';
import '../../core/auth/account_transfer_service.dart';
import '../../core/auth/pkce.dart';
import '../../core/i18n/replica_language.dart';
import '../../core/logging/crash_log.dart';
import '../../core/network/compat/network_contracts.dart' as network_contracts;
import '../../core/network/compat/network_providers.dart';
import '../../core/platform/intent_router.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
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
    this.callback,
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
  final AccountCallbackRoute? callback;

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
      network_contracts.NetworkMode.compatPrefer => NetworkMode.compatPrefer,
    };
    if (widget.callback != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_handleExternalCallback());
      });
    }
  }

  Future<void> _handleExternalCallback() async {
    final callback = widget.callback;
    if (callback == null) return;
    final uri = Uri(
      scheme: 'pixiv',
      host: 'account',
      queryParameters: {
        'code': callback.code,
        if (callback.state != null) 'state': callback.state!,
      },
    );
    final service = ref.read(oauthServiceProvider);
    final parsed = service.validateRedirect(uri);
    switch (parsed) {
      case PixivCallbackCode(:final code):
        try {
          final result = await service.exchangeCode(code);
          if (!mounted) return;
          await ref
              .read(accountStoreProvider.notifier)
              .upsertAccount(
                Account(
                  id: result.accountId,
                  userId: result.profile.userId,
                  name: result.profile.name,
                  mailAddress: result.profile.mailAddress,
                  profileImageUrl: result.profile.profileImageUrl,
                  isPremium: result.profile.isPremium,
                ),
                result.credential,
              );
          if (mounted) context.go('/recommended');
        } on Object catch (error, stackTrace) {
          if (mounted) {
            showErrorSnackBar(
              context,
              action: context.l10n.loginFailed,
              error: error,
              stack: stackTrace,
            );
          }
        }
      case PixivCallbackInvalid(:final reason):
        // The reason is a developer diagnostic, not copy — it goes to the
        // crash log and the SnackBar stays a plain sentence.
        CrashLog.record(StateError('login callback invalid: $reason'));
        if (mounted) {
          showAppSnackBar(context, context.l10n.loginCallbackInvalid);
        }
      case PixivCallbackOther():
        break;
    }
  }

  Future<void> _openLoginWebview({bool create = false}) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.loginProxyNoticeTitle),
        content: Text(context.l10n.loginProxyNoticeBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.loginProxyNoticeCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.loginProxyNoticeContinue),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // R7 was cancelled: the first login always uses the stable webview_flutter
    // path (C16). The native interception entry is removed.
    final result = await context.push<bool>(
      Uri(
        path: '/login/web',
        queryParameters: create ? {'create': 'true'} : null,
      ).toString(),
    );
    if (!mounted || result != true || !widget.returnToHomeOnSuccess) return;
    // The account store is updated before the WebView pops.  Popping the
    // onboarding/login routes now lets StartupGate rebuild to Home without
    // leaving the user stranded on a stale login surface.
    context.go('/recommended');
  }

  void _persistNetworkMode(NetworkMode mode) {
    unawaited(() async {
      try {
        await ref.read(settingsProvider.notifier).setNetworkMode(mode);
      } on Object catch (error) {
        if (!mounted) return;
        showErrorSnackBar(
          context,
          action: _loginText('settingsWriteFailed'),
          error: error,
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
          loading: () => const ReplicaScaffold(child: FeedLoading()),
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
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
    );

    return ScrollableFormShell(
      title: widget.isFirst ? null : title,
      // The first-run variant shows the title inside the scrollable body —
      // same treatment as the onboarding pages sharing this shell.
      header: widget.isFirst ? title : const SizedBox.shrink(),
      content: _buildNetworkOptions(context, text: text),
      primaryAction: _buildMainActions(text),
      secondary: _buildSecondary(
        context,
        text: text,
        onClipboardLogin: onClipboardLogin,
      ),
    );
  }

  Widget _buildNetworkOptions(
    BuildContext context, {
    required String Function(String) text,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReplicaSwitchTile(
          contentPadding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
          value: _networkMode == NetworkMode.automatic,
          title: _buildNetworkTitle(context, text),
          onTap: _toggleNetworkMode,
        ),
        const Divider(),
      ],
    );
  }

  /// The register/login row is the page's primary action and stays in place
  /// regardless of the help toggle — `_help` only reveals the network
  /// compatibility note below it, it never replaces this row.
  Widget _buildMainActions(String Function(String) text) {
    return Row(
      children: [
        Expanded(
          child: ReplicaButton(
            label: text('register'),
            backgroundColor: FuncTokens.lightBackground,
            foregroundColor: Theme.of(context).colorScheme.primary,
            borderColor: Theme.of(context).colorScheme.primary,
            onPressed:
                widget.onRegister ?? () => _openLoginWebview(create: true),
          ),
        ),
        const SizedBox(width: FuncSpacing.lg),
        Expanded(
          child: ReplicaButton(
            label: text('login'),
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: FuncTokens.lightBackground,
            onPressed: widget.onLogin ?? () => _openLoginWebview(),
          ),
        ),
      ],
    );
  }

  Widget _buildSecondary(
    BuildContext context, {
    required String Function(String) text,
    required VoidCallback onClipboardLogin,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_help) ...[
          Text(
            text('networkCompatibilityHint'),
            style: FuncSemanticTokens.of(context).body.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: FuncSpacing.md),
        ],
        // Clipboard import is an action (idle/busy/success/error): while
        // busy the button is disabled and its label carries a small
        // progress indicator — ReplicaButton has no loading variant, so
        // a disabled OutlinedButton is the equivalent secondary form.
        OutlinedButton(
          onPressed: _clipboardBusy ? null : onClipboardLogin,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_clipboardBusy) ...[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: FuncSpacing.sm),
              ],
              Flexible(
                child: Text(
                  text('useLoginWithClipboard'),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: FuncSpacing.sm),
        // Where the data comes from, then the shared clipboard risk note
        // (also shown by the settings export dialog).
        Text(
          '${text('loginClipboardHint')}\n${text('accountTransferWarning')}',
          textAlign: TextAlign.center,
          style: FuncSemanticTokens.of(context).caption,
        ),
        const SizedBox(height: FuncSpacing.md),
        Text(
          text('loginAgree'),
          textAlign: TextAlign.center,
          style: FuncSemanticTokens.of(context).body,
        ),
        TextButton(
          onPressed: () => context.push<void>('/user-agreement'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.primary,
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            text('userAgreement'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
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
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: FuncSpacing.sm),
        IconButton(
          onPressed: () => setState(() => _help = !_help),
          tooltip: text('networkCompatibility'),
          icon: Icon(
            Icons.info_outline,
            color: Theme.of(context).colorScheme.primary,
          ),
          iconSize: 20,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
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
      NetworkMode.compatPrefer => network_contracts.NetworkMode.compatPrefer,
    });
    _persistNetworkMode(_networkMode);
  }
}
