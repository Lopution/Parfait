import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/oauth_service.dart';
import '../../core/auth/pkce.dart';
import '../../core/network/compat/network_contracts.dart';
import '../../core/network/compat/network_providers.dart';
import '../../core/network/compat/webview_route.dart';

/// OAuth login WebView.
///
/// Loads the verified Pixiv authorize URL for a fresh one-use PKCE session
/// and only treats an exact `pixiv://account?code=...` redirect as a
/// completed login. Everything else is a normal navigation. TLS errors and
/// user cancellation discard the session.
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
  WebViewRouteSession? _routeSession;
  bool _routeInvalidated = false;
  bool _disposed = false;
  bool _exchanging = false;
  double? _progress;
  String? _error;
  Uri? _mainFrameUri;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.create) {
      // Direct signup; login with PKCE happens afterwards.
      final signupUrl = Uri.parse('https://accounts.pixiv.net/signup');
      _mainFrameUri = signupUrl;
      _prepareRouteSession(signupUrl);
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
    _prepareRouteSession(session.authorizeUrl);
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
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    // Cancellation and page disposal must never leave a live verifier behind.
    widget.oauthService.discardSession();
    unawaited(_closeRouteSession(WebViewRouteInvalidationReason.pageDisposed));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _fail('页面已暂停，请重新打开');
  }

  void _prepareRouteSession(Uri uri) {
    // Keep the synchronous direct validation in front of the asynchronous
    // capability probe so malformed production URLs fail at construction.
    ref
        .read(webViewRoutePolicyProvider)
        .validateDirect(uri, purpose: PixivDestinationPurpose.accountsWeb);
    unawaited(_openRouteSession(uri));
  }

  Future<void> _openRouteSession(Uri uri) async {
    try {
      final session = await WebViewRouteSession.open(
        policy: ref.read(webViewRoutePolicyProvider),
        uri: uri,
        purpose: PixivDestinationPurpose.accountsWeb,
      );
      if (!mounted || _disposed || _routeInvalidated) {
        await session.close();
        return;
      }
      _routeSession = session;
    } on Object catch (error) {
      if (mounted) _fail('WebView 路由不可用 (${error.runtimeType})');
    }
  }

  Future<void> _closeRouteSession(WebViewRouteInvalidationReason reason) async {
    _routeInvalidated = true;
    final session = _routeSession;
    _routeSession = null;
    if (session != null) await session.invalidate(reason);
  }

  NavigationDecision _onSignupNavigationRequest(NavigationRequest request) {
    final uri = _parseNavigationUri(request.url);
    if (uri == null || !_isAllowedWebNavigation(uri)) {
      _fail('已拒绝非 Pixiv WebView 导航');
      return NavigationDecision.prevent;
    }
    _mainFrameUri = uri;
    return NavigationDecision.navigate;
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final uri = _parseNavigationUri(request.url);
    if (uri == null) {
      _fail('登录导航地址无效');
      return NavigationDecision.prevent;
    }
    final parsed = widget.oauthService.validateRedirect(uri);
    switch (parsed) {
      case PixivCallbackCode(:final code):
        _exchange(code);
        return NavigationDecision.prevent;
      case PixivCallbackInvalid(:final reason):
        _fail('登录回调无效: $reason');
        return NavigationDecision.prevent;
      case PixivCallbackOther():
        if (uri.scheme != 'http' && uri.scheme != 'https') {
          _fail('已拒绝非 HTTPS Pixiv 登录导航');
          return NavigationDecision.prevent;
        }
        if (!_isAllowedWebNavigation(uri)) {
          _fail('已拒绝非 Pixiv 登录导航');
          return NavigationDecision.prevent;
        }
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
    _fail('网络错误 (HTTP ${error.response?.statusCode})');
  }

  void _onWebResourceError(WebResourceError error) {
    // WebView surfaces subresource failures through this callback as well.
    // Only a main-frame failure terminates the login attempt.
    if (error.isForMainFrame == false) return;
    _fail('页面加载失败 (${error.errorType ?? error.errorCode})');
  }

  Uri? _parseNavigationUri(String raw) {
    try {
      return Uri.parse(raw);
    } on FormatException {
      return null;
    }
  }

  bool _isAllowedWebNavigation(Uri uri) {
    try {
      final session = _routeSession;
      if (_routeInvalidated && session == null) return false;
      if (session != null) {
        session.validate(uri);
      } else {
        ref
            .read(webViewRoutePolicyProvider)
            .validateDirect(uri, purpose: PixivDestinationPurpose.accountsWeb);
      }
      return true;
    } on Object {
      return false;
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
      _fail('登录失败: $error');
    } on Object catch (error) {
      _fail('登录失败 (${error.runtimeType})');
    }
  }

  void _fail(String message) {
    widget.oauthService.discardSession();
    unawaited(_closeRouteSession(WebViewRouteInvalidationReason.authFailure));
    if (!mounted) return;
    setState(() {
      _exchanging = false;
      _error = message;
    });
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
                          TextButton(
                            onPressed: () => setState(() => _error = null),
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
