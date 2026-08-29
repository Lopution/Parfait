import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/oauth_service.dart';
import '../../core/auth/pkce.dart';

/// OAuth login WebView.
///
/// Loads the Pixiv authorize URL for a fresh one-use PKCE session and only
/// treats an exact `pixiv://account?code=...` redirect as a completed login.
///
/// Where the login page navigates in between is Pixiv's business: its own
/// oauth host, a captcha vendor, or a third-party identity provider. The
/// security boundary is the PKCE session and the exact callback match, not a
/// host allowlist — an allowlist can only lag behind Pixiv and break sign-in.
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
  late final WebViewController _controller;
  bool _exchanging = false;
  double? _progress;
  String? _error;

  /// Whether [_error] describes a state the page cannot navigate out of.
  /// Recoverable errors leave the PKCE session alive so the user can keep
  /// using the same login page.
  bool _fatal = false;
  Uri? _mainFrameUri;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.create) {
      // Direct signup; login with PKCE happens afterwards.
      final signupUrl = Uri.parse('https://accounts.pixiv.net/signup');
      _mainFrameUri = signupUrl;
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: _onSignupNavigationRequest,
            onPageStarted: _onPageStarted,
            onUrlChange: _onUrlChange,
            onHttpError: _onHttpError,
            onWebResourceError: _onWebResourceError,
          ),
        )
        ..loadRequest(signupUrl);
      return;
    }
    final session = widget.oauthService.beginSession();
    _mainFrameUri = session.authorizeUrl;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageStarted: _onPageStarted,
          onUrlChange: _onUrlChange,
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress / 100.0);
          },
          onHttpError: _onHttpError,
          onWebResourceError: _onWebResourceError,
        ),
      )
      ..loadRequest(session.authorizeUrl);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Cancellation and page disposal must never leave a live verifier behind.
    widget.oauthService.discardSession();
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
    _abortLogin('页面已关闭，请重新打开');
  }

  NavigationDecision _onSignupNavigationRequest(NavigationRequest request) {
    final uri = _parseNavigationUri(request.url);
    if (uri != null) _mainFrameUri = uri;
    return NavigationDecision.navigate;
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final uri = _parseNavigationUri(request.url);
    if (uri == null) return NavigationDecision.navigate;
    final parsed = widget.oauthService.validateRedirect(uri);
    switch (parsed) {
      case PixivCallbackCode(:final code):
        _exchange(code);
        return NavigationDecision.prevent;
      case PixivCallbackInvalid(:final reason):
        // The callback was consumed with unusable parameters; the verifier
        // cannot be reused for another attempt.
        _abortLogin('登录回调无效: $reason');
        return NavigationDecision.prevent;
      case PixivCallbackOther():
        // Every other destination is the login page doing its own work.
        _mainFrameUri = uri;
        return NavigationDecision.navigate;
    }
  }

  void _onPageStarted(String rawUrl) {
    final uri = _parseNavigationUri(rawUrl);
    if (uri != null) _mainFrameUri = uri;
  }

  void _onUrlChange(UrlChange change) {
    final rawUrl = change.url;
    if (rawUrl == null) return;
    final uri = _parseNavigationUri(rawUrl);
    if (uri != null) _mainFrameUri = uri;
  }

  void _onHttpError(HttpResponseError error) {
    // Android reports HTTP errors for every resource, not just the document.
    // A failed tracker, stylesheet or captcha asset must not discard an
    // otherwise usable PKCE session and make the next Pixiv navigation look
    // foreign.
    final requestUri = error.request?.uri;
    final mainFrameUri = _mainFrameUri;
    if (requestUri != null &&
        mainFrameUri != null &&
        requestUri != mainFrameUri) {
      return;
    }
    // A main-document 4xx is routinely a form-validation or risk-control
    // response that the user can retry in place.
    _reportRecoverable('网络错误 (HTTP ${error.response?.statusCode})');
  }

  void _onWebResourceError(WebResourceError error) {
    // WebView surfaces subresource failures through this callback as well.
    // Only a main-frame failure is worth reporting, and it stays retryable.
    if (error.isForMainFrame == false) return;
    _reportRecoverable('页面加载失败 (${error.errorType ?? error.errorCode})');
  }

  Uri? _parseNavigationUri(String raw) {
    try {
      return Uri.parse(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> _exchange(String code) async {
    if (_exchanging) return;
    setState(() {
      _exchanging = true;
      _error = null;
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
            ),
            result.credential,
          );
      if (!mounted) return;
      // The StartupGate reacts to the new usable account and shows Home.
      Navigator.of(context).pop(true);
    } on OAuthException catch (error) {
      // The authorization code was already consumed by this exchange.
      _abortLogin('登录失败: $error');
    } on Object catch (error) {
      _abortLogin('登录失败 (${error.runtimeType})');
    }
  }

  /// Ends the login attempt. The PKCE verifier is discarded, so the page can
  /// no longer complete a sign-in and must be reopened.
  void _abortLogin(String message) {
    widget.oauthService.discardSession();
    if (!mounted) return;
    setState(() {
      _exchanging = false;
      _error = message;
      _fatal = true;
    });
  }

  /// Reports a transient problem without touching the PKCE session. A
  /// form-validation status code or a failed page load must not turn into a
  /// permanently dead WebView.
  void _reportRecoverable(String message) {
    if (!mounted || _fatal) return;
    setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _progress != null && _progress! < 1.0
              ? LinearProgressIndicator(value: _progress, minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_exchanging)
            const ColoredBox(
              color: Colors.black38,
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Align(
              alignment: Alignment.bottomLeft,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(child: Text(_error!)),
                          // A fatal error leaves no usable session behind, so
                          // the action closes the page instead of pretending
                          // the WebView can still be used.
                          _fatal
                              ? TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('重新打开'),
                                )
                              : TextButton(
                                  onPressed: () =>
                                      setState(() => _error = null),
                                  child: const Text('知道了'),
                                ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
