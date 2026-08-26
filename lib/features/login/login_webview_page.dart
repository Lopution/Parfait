import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/oauth_service.dart';
import '../../core/auth/pkce.dart';

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

class _LoginWebViewPageState extends ConsumerState<LoginWebViewPage> {
  late final WebViewController _controller;
  bool _exchanging = false;
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.create) {
      // Direct signup; login with PKCE happens afterwards.
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (request) => NavigationDecision.navigate,
          onWebResourceError: (error) =>
              _fail('页面加载失败 (${error.errorType ?? error.errorCode})'),
        ))
        ..loadRequest(Uri.parse('https://accounts.pixiv.net/signup'));
      return;
    }
    final session = widget.oauthService.beginSession();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _onNavigationRequest,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress / 100.0);
        },
        onHttpError: (error) =>
            _fail('网络错误 (HTTP ${error.response?.statusCode})'),
        onWebResourceError: (error) =>
            _fail('页面加载失败 (${error.errorType ?? error.errorCode})'),
      ))
      ..loadRequest(session.authorizeUrl);
  }

  @override
  void dispose() {
    // Cancellation and page disposal must never leave a live verifier behind.
    widget.oauthService.discardSession();
    super.dispose();
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final parsed = widget.oauthService.validateRedirect(Uri.parse(request.url));
    switch (parsed) {
      case PixivCallbackCode(:final code):
        _exchange(code);
        return NavigationDecision.prevent;
      case PixivCallbackInvalid(:final reason):
        _fail('登录回调无效: $reason');
        return NavigationDecision.prevent;
      case PixivCallbackOther():
        return NavigationDecision.navigate;
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
      await ref.read(accountStoreProvider.notifier).upsertAccount(
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
    }
  }

  void _fail(String message) {
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
