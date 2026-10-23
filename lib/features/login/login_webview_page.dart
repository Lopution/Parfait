import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/web_navigation_guard.dart';
import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/oauth_service.dart';
import '../../core/logging/crash_log.dart';
import '../../core/network/local_network_address.dart';
import '../../core/platform/local_network.dart';
import '../../core/platform/platform_caps.dart';

import '../../l10n/context.dart';
import 'login_navigation_decision.dart';
import 'login_session_restart.dart';
import 'login_webview_error_card.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// OAuth login WebView.
///
/// Loads the Pixiv authorize URL for a fresh one-use PKCE session and only
/// treats an exact `pixiv://account?code=...` redirect as a completed login.
///
/// Where the login page navigates in between is Pixiv's business: its own
/// oauth host, a captcha vendor, or a third-party identity provider. The
/// security boundary is the PKCE session and the exact callback match, not a
/// host allowlist — an allowlist can only lag behind Pixiv and break sign-in.
///
/// The callback is caught where [WebNavigationGuard] catches navigations;
/// where that is as a navigation starts (Windows), server-side 302s can skip
/// the event, so the history update runs the same decision as a fallback:
/// the code is already in the URL by then and `pixiv://` cannot load inside
/// the WebView anyway.
class LoginWebViewPage extends ConsumerStatefulWidget {
  const LoginWebViewPage({
    super.key,
    required this.oauthService,
    this.create = false,
    this.title = 'Pixiv',
  });

  final OAuthService oauthService;

  /// When true, loads the signup page directly (beta56 register flow).
  final bool create;
  final String title;

  @override
  ConsumerState<LoginWebViewPage> createState() => _LoginWebViewPageState();
}

class _LoginWebViewPageState extends ConsumerState<LoginWebViewPage>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  late final WebNavigationGuard _guard;
  bool _exchanging = false;
  double? _progress;
  String? _error;

  /// Raw error shown behind the card's details disclosure; `null` when
  /// [_error] is a crafted message with nothing technical to expand.
  Object? _errorDetails;

  /// Whether [_error] describes a state the page cannot navigate out of.
  /// Recoverable errors leave the PKCE session alive so the user can keep
  /// using the same login page.
  bool _fatal = false;
  bool _webView2Missing = false;

  /// The page a load before any other loads: the signup page or the
  /// current session's authorize URL.
  late Uri _startUrl;

  /// Whether a page has started loading; until then a reload has nothing
  /// to reload and loads [_startUrl] instead.
  bool _loaded = false;

  static final Uri _webView2InstallUri = Uri.parse(
    'https://developer.microsoft.com/microsoft-edge/webview2/',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final caps = ref.read(platformCapsProvider);
    // Signup has no PKCE session; login with PKCE happens afterwards.
    _guard = WebNavigationGuard(
      caps,
      widget.create ? (_) => false : _decideNavigation,
    );
    if (widget.create) {
      _startUrl = Uri.parse('https://accounts.pixiv.net/signup');
    } else {
      // Create exactly one PKCE session for this page. Calling
      // beginSession() while only reading the URL discards the verifier
      // that the next call would need, making the visible authorize URL and
      // exchange state diverge.
      _startUrl = widget.oauthService.beginSession().authorizeUrl;
    }
    if (caps.isWindows) unawaited(_probeWebView2());
  }

  /// WebView2 is a runtime dependency, not bundled: on systems without it
  /// the platform view fails late and silently, so probe up front and show
  /// an actionable install prompt instead.
  Future<void> _probeWebView2() async {
    String? version;
    try {
      version = await WebViewEnvironment.getAvailableVersion();
    } on Object {
      version = null;
    }
    if (!mounted || version != null) return;
    setState(() => _webView2Missing = true);
  }

  /// Loads [url], or reloads the current page when it is null.
  ///
  /// The page connects through the system proxy, which may sit on the
  /// local network: without the permission the load would hang until it
  /// times out, so the card reports it at once instead. Every load and
  /// reload checks again; the proxy or the grant may have changed.
  Future<void> _load(Uri? url) async {
    try {
      await ref.read(localNetworkGateProvider).ensureProxy();
    } on LocalNetworkBlocked catch (error) {
      if (!mounted) return;
      _reportRecoverable(context.l10n.errorLocalNetwork, error: error);
      return;
    }
    final controller = _controller;
    if (!mounted || controller == null) return;
    if (url == null) return controller.reload();
    _loaded = true;
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Cancellation and page disposal must never leave a live verifier behind.
    widget.oauthService.discardSession();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the foreground is a normal part of signing in: reading a mail
    // verification code, an identity provider's account chooser, password
    // autofill and a full-screen IME all report inactive/paused/hidden.
    // Discarding the PKCE session there makes the login unusable on return.
    // Only a detached engine can no longer complete the flow.
    if (state != AppLifecycleState.detached) return;
    _abortLogin(context.l10n.loginPageClosed);
  }

  /// Applies [decideLoginNavigation]; returns true when the navigation must
  /// be stopped (callback consumed or invalid).
  bool _decideNavigation(String rawUrl) {
    return switch (decideLoginNavigation(widget.oauthService, rawUrl)) {
      LoginNavExchange(:final code) => () {
        unawaited(_exchange(code));
        return true;
      }(),
      LoginNavAbort(:final reason) => () {
        // The callback was consumed with unusable parameters; the verifier
        // cannot be reused for another attempt.
        _abortLogin(context.l10n.loginCallbackInvalid, error: reason);
        return true;
      }(),
      LoginNavAllow() || LoginNavIgnore() => false,
    };
  }

  void _onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    // WebView surfaces subresource failures through this callback as well.
    // Only a main-frame failure is worth reporting, and it stays retryable.
    if (request.isForMainFrame == false) return;
    // '<type> <host>' says which host produced the failure without echoing
    // the full URL into the card's details.
    _reportRecoverable(
      context.l10n.loginPageLoadFailed,
      error: describeWebViewFailure(error.type, request.url),
    );
  }

  void _onReceivedHttpError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceResponse response,
  ) {
    // Android reports HTTP errors for every resource, not just the document.
    // A failed tracker, stylesheet or captcha asset must not discard an
    // otherwise usable PKCE session.
    if (request.isForMainFrame == false) return;
    // A main-document 4xx is routinely a form-validation or risk-control
    // response that the user can retry in place.
    _reportRecoverable(
      context.l10n.loginNetworkError(
        describeWebViewFailure(response.statusCode ?? 'unknown', request.url),
      ),
    );
  }

  Future<void> _exchange(String code) async {
    if (_exchanging) return;
    setState(() {
      _exchanging = true;
      _error = null;
      _errorDetails = null;
    });
    try {
      final result = await widget.oauthService.exchangeCode(code);
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
      if (!mounted) return;
      // The StartupGate reacts to the new usable account and shows Home.
      context.pop(true);
    } on Object catch (error, stackTrace) {
      // The authorization code was already consumed by this exchange.
      CrashLog.record(error, stackTrace);
      _abortLogin(context.l10n.loginFailed, error: error);
    }
  }

  /// Ends the login attempt. The PKCE verifier is discarded, so the session
  /// must be rebuilt in place ([_restartLogin]) before sign-in can complete.
  void _abortLogin(String message, {Object? error}) {
    widget.oauthService.discardSession();
    if (!mounted) return;
    setState(() {
      _exchanging = false;
      _error = message;
      _errorDetails = error;
      _fatal = true;
    });
  }

  /// Reports a transient problem without touching the PKCE session. A
  /// form-validation status code or a failed page load must not turn into a
  /// permanently dead WebView.
  void _reportRecoverable(String message, {Object? error}) {
    if (!mounted || _fatal) return;
    setState(() {
      _error = message;
      _errorDetails = error;
    });
  }

  /// Reloads the current document in place. For a recoverable error this
  /// retries the failed page; in signup mode there is no PKCE session, so
  /// it is also the fatal card's only restart action. Clearing `_fatal`
  /// with the card keeps `_reportRecoverable` reporting errors after the
  /// reload — a stale fatal flag would swallow them silently.
  void _reload() {
    setState(() {
      _error = null;
      _errorDetails = null;
      _fatal = false;
    });
    unawaited(_load(_loaded ? null : _startUrl));
  }

  /// Restarts the OAuth attempt without leaving the page: beginSession()
  /// discards the dead verifier and the fresh authorize URL is loaded into
  /// the same WebView.
  void _restartLogin() {
    final authorizeUrl = restartLoginSession(widget.oauthService);
    setState(() {
      _exchanging = false;
      _error = null;
      _errorDetails = null;
      _fatal = false;
      _startUrl = authorizeUrl;
    });
    unawaited(_load(authorizeUrl));
  }

  Widget _webView() => InAppWebView(
    // No initialUrlRequest: the first load goes through [_load] and its
    // local network check like every other.
    initialSettings: _guard.settings,
    onWebViewCreated: (controller) {
      _controller = controller;
      unawaited(_load(_startUrl));
    },
    shouldOverrideUrlLoading: _guard.shouldOverrideUrlLoading,
    onLoadStart: _guard.onLoadStart,
    onUpdateVisitedHistory: _guard.beforeLoad
        ? null
        : (controller, url, isReload) => _guard.stopAsStarted(controller, url),
    onProgressChanged: (controller, progress) {
      if (mounted) setState(() => _progress = progress / 100.0);
    },
    onReceivedError: _onReceivedError,
    onReceivedHttpError: _onReceivedHttpError,
  );

  Widget _webView2Prompt(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.public_off, size: 56),
        const SizedBox(height: FuncSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
          child: Text(
            context.l10n.loginWebView2Missing,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: FuncSpacing.md),
        FilledButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: Text(context.l10n.loginInstallWebView2),
          onPressed: () => unawaited(
            launchUrl(
              _webView2InstallUri,
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _progress != null && _progress! < 1.0
              ? LinearProgressIndicator(value: _progress, minHeight: 2)
              : const SizedBox(height: FuncSpacing.xxs),
        ),
      ),
      body: Stack(
        children: [
          if (_webView2Missing) _webView2Prompt(context) else _webView(),
          if (_exchanging)
            // This opaque black scrim is a deliberate replica loading
            // surface, independent of the app theme brightness.
            const ColoredBox(
              color: Colors.black38,
              child: Center(child: CircularProgressIndicator()),
            ),
          // Shared error surface — the card owns the action-set contract:
          // recoverable → reload + dismiss; fatal → restart the dead PKCE
          // session in place (signup mode has no session, so it can only
          // reload the document).
          if (_error != null)
            LoginWebViewErrorCard(
              message: _error!,
              error: _errorDetails,
              fatal: _fatal,
              signup: widget.create,
              onReload: _reload,
              onRestart: _restartLogin,
              onDismiss: () => setState(() {
                _error = null;
                _errorDetails = null;
              }),
            ),
        ],
      ),
    );
  }
}
