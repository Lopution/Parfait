import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:url_launcher/url_launcher.dart';

import '../../app/widgets/feed/feed_states.dart';
import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/auth/oauth_service.dart';
import '../../core/platform/platform_caps.dart';
import '../../l10n/context.dart';
import 'login_navigation_decision.dart';

/// OAuth login WebView for desktop (Windows via `flutter_inappwebview` /
/// WebView2). Same contract as `login_webview_page.dart`: one PKCE session
/// per page, an exact `pixiv://account?code=…` intercept, recoverable vs
/// fatal error surfaces, and `discardSession` on any exit path.
///
/// `shouldOverrideUrlLoading` covers top-frame navigations; server-side
/// 302s can skip it on WebView2, so `onUpdateVisitedHistory` re-runs the
/// same decision as a fallback — the code is already in the URL by then and
/// `pixiv://` cannot load inside the WebView anyway.
class LoginWebViewDesktopPage extends ConsumerStatefulWidget {
  const LoginWebViewDesktopPage({
    super.key,
    required this.oauthService,
    this.create = false,
    this.title = 'Pixiv',
  });

  final OAuthService oauthService;
  final bool create;
  final String title;

  @override
  ConsumerState<LoginWebViewDesktopPage> createState() =>
      _LoginWebViewDesktopPageState();
}

class _LoginWebViewDesktopPageState
    extends ConsumerState<LoginWebViewDesktopPage>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  bool _exchanging = false;
  double? _progress;
  String? _error;
  bool _fatal = false;
  bool _webView2Missing = false;
  late final Uri _initialUrl;

  static final Uri _webView2InstallUri = Uri.parse(
    'https://developer.microsoft.com/microsoft-edge/webview2/',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.create) {
      // Direct signup; login with PKCE happens afterwards.
      _initialUrl = Uri.parse('https://accounts.pixiv.net/signup');
      return;
    }
    // Exactly one PKCE session for this page — same reason as the mobile
    // page: reading a second authorize URL would discard the verifier.
    final session = widget.oauthService.beginSession();
    _initialUrl = session.authorizeUrl;
    if (PlatformCaps.system().isWindows) unawaited(_probeWebView2());
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Cancellation and page disposal must never leave a live verifier.
    widget.oauthService.discardSession();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only a detached engine can no longer complete the flow; transient
    // focus loss (IME, dialog, minimize) keeps the session alive.
    if (state != AppLifecycleState.detached) return;
    _abortLogin(context.l10n.loginPageClosed);
  }

  /// Applies [decideLoginNavigation]; returns true when the navigation must
  /// be cancelled.
  bool _handleNavigation(String rawUrl) {
    return switch (decideLoginNavigation(widget.oauthService, rawUrl)) {
      LoginNavExchange(:final code) => () {
        unawaited(_exchange(code));
        return true;
      }(),
      LoginNavAbort(:final reason) => () {
        _abortLogin(context.l10n.loginCallbackInvalid(reason));
        return true;
      }(),
      LoginNavAllow() => false,
      LoginNavIgnore() => false,
    };
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
      context.pop(true);
    } on OAuthException catch (error) {
      _abortLogin(context.l10n.loginFailed(error.toString()));
    } on Object catch (error) {
      _abortLogin(context.l10n.loginFailedType(error.runtimeType.toString()));
    }
  }

  void _abortLogin(String message) {
    widget.oauthService.discardSession();
    if (!mounted) return;
    setState(() {
      _exchanging = false;
      _error = message;
      _fatal = true;
    });
  }

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
          if (_webView2Missing)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.public_off, size: 56),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      context.l10n.loginWebView2Missing,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
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
            )
          else
            InAppWebView(
              // NOTE: no initialUrlRequest and no useShouldOverrideUrlLoading.
              // On Windows the plugin implements the latter via CDP
              // Fetch.requestPaused, which pauses every Document hop — Pixiv's
              // authorize → post-redirect → login chain dies mid-redirect as
              // CONNECTION_ABORTED. Interception instead runs on
              // onLoadStart (NavigationStarting event) + onUpdateVisitedHistory
              // fallback; a consumed pixiv:// callback never completes loading
              // anyway, we just need the URL.
              initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
              onWebViewCreated: (controller) {
                _controller = controller;
                unawaited(
                  controller.loadUrl(
                    urlRequest: URLRequest(url: WebUri.uri(_initialUrl)),
                  ),
                );
              },
              onLoadStart: (controller, url) {
                if (url == null) return;
                if (_handleNavigation(url.toString())) {
                  controller.stopLoading();
                }
              },
              // Fallback for server-side 302 chains that skip NavigationStarting.
              onUpdateVisitedHistory: (controller, url, isReload) {
                if (url == null) return;
                if (_handleNavigation(url.toString())) {
                  controller.stopLoading();
                }
              },
              onProgressChanged: (controller, progress) {
                if (mounted) setState(() => _progress = progress / 100.0);
              },
              onReceivedError: (controller, request, error) {
                if (request.isForMainFrame == false) return;
                // Surface the failing URL — CONNECTION_ABORTED alone does
                // not say whether the authorize page or a consumed callback
                // produced it.
                _reportRecoverable(
                  context.l10n.loginPageLoadFailed(
                    '${error.type} ${request.url}',
                  ),
                );
              },
              onReceivedHttpError: (controller, request, response) {
                if (request.isForMainFrame == false) return;
                _reportRecoverable(
                  context.l10n.loginNetworkError(
                    '${response.statusCode} ${request.url}',
                  ),
                );
              },
            ),
          if (_exchanging)
            // Opaque scrim identical to the mobile page's loading surface.
            const ColoredBox(color: Colors.black38, child: FeedLoading()),
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
                          _fatal
                              ? TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: Text(context.l10n.reopen),
                                )
                              : TextButton(
                                  onPressed: () =>
                                      setState(() => _error = null),
                                  child: Text(context.l10n.dismiss),
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
