import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/feed/feed_states.dart';
import '../../../core/platform/platform_caps.dart';
import '../../../core/translation/doubao_web_translation.dart';
import '../../../core/translation/translation_credentials.dart';
import '../../../core/translation/translation_service.dart';
import '../../../l10n/context.dart';

/// The doubao.com session in the app's shared WebView cookie store.
abstract interface class DoubaoWebCookies {
  /// The `Cookie` header for www.doubao.com once a login session exists,
  /// otherwise null.
  Future<String?> sessionCookie();

  /// Removes doubao.com cookies only; other sites (pixiv) keep theirs.
  Future<void> clear();
}

final doubaoWebCookiesProvider = Provider<DoubaoWebCookies>(
  (ref) => const _InAppDoubaoWebCookies(),
);

class _InAppDoubaoWebCookies implements DoubaoWebCookies {
  const _InAppDoubaoWebCookies();

  static final _site = WebUri('https://www.doubao.com');

  /// Set by the ByteDance passport once the user has signed in.
  static const _sessionCookieNames = {'sessionid', 'sessionid_ss', 'sid_tt'};

  @override
  Future<String?> sessionCookie() async {
    final cookies = await CookieManager.instance().getCookies(url: _site);
    final signedIn = cookies.any(
      (cookie) =>
          _sessionCookieNames.contains(cookie.name) &&
          '${cookie.value}'.isNotEmpty,
    );
    if (!signedIn) return null;
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  @override
  Future<void> clear() async {
    final manager = CookieManager.instance();
    // Host-only cookies, then the ones scoped to the whole domain.
    await manager.deleteCookies(url: _site);
    await manager.deleteCookies(url: _site, domain: '.doubao.com');
  }
}

/// Signs in to doubao.com in a WebView and saves the session for the
/// Doubao translation engine. Pops `true` once a session is saved.
class DoubaoLoginPage extends ConsumerStatefulWidget {
  const DoubaoLoginPage({super.key});

  @override
  ConsumerState<DoubaoLoginPage> createState() => _DoubaoLoginPageState();
}

class _DoubaoLoginPageState extends ConsumerState<DoubaoLoginPage> {
  /// The login dialog is part of a single-page app, so a finished login
  /// does not always load a page; the cookie store is also checked on a
  /// timer while the page is open.
  static const _pollInterval = Duration(seconds: 2);

  InAppWebViewController? _controller;
  Timer? _poll;
  double? _progress;
  Object? _loadError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(_pollInterval, (_) => unawaited(_capture()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /// Saves the session if one exists. Returns whether one was found.
  Future<bool> _capture() async {
    if (_saving) return true;
    final cookie = await ref.read(doubaoWebCookiesProvider).sessionCookie();
    if (cookie == null || !mounted || _saving) return cookie != null;
    _saving = true;
    try {
      await ref
          .read(translationCredentialStoreProvider)
          .writeDoubao(
            DoubaoWebSession(cookie: cookie, teaUuid: newDoubaoTeaUuid()),
          );
    } on TranslationCredentialsStoreException {
      _saving = false;
      if (mounted) {
        showAppSnackBar(context, context.l10n.translateCredentialsStoreError);
      }
      return true;
    }
    _poll?.cancel();
    if (mounted) context.pop(true);
    return true;
  }

  Future<void> _done() async {
    if (await _capture() || !mounted) return;
    showAppSnackBar(context, context.l10n.doubaoLoginNotDetected);
  }

  void _reload() {
    setState(() => _loadError = null);
    unawaited(_controller?.reload());
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    return Scaffold(
      appBar: AppTopBar(
        title: Text(context.l10n.doubaoLoginTitle),
        actions: [
          TextButton(
            onPressed: () => unawaited(_done()),
            child: Text(context.l10n.doubaoLoginDone),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: progress != null && progress < 1.0
              ? LinearProgressIndicator(value: progress, minHeight: 2)
              : const SizedBox(height: FuncSpacing.xxs),
        ),
      ),
      body: Stack(
        children: [
          InAppWebView(
            // Loaded from onWebViewCreated, and URL overrides only on
            // Android: see the Windows note in the Pixiv login WebView.
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              userAgent: DoubaoWebTranslationTransport.userAgent,
              useShouldOverrideUrlLoading: PlatformCaps.system().isAndroid,
              // The desktop site, zoomed out to fit and pinch-zoomable.
              useWideViewPort: true,
              loadWithOverviewMode: true,
              supportZoom: true,
              builtInZoomControls: true,
              displayZoomControls: false,
            ),
            onWebViewCreated: (controller) {
              _controller = controller;
              unawaited(
                controller.loadUrl(
                  urlRequest: URLRequest(
                    url: WebUri.uri(DoubaoWebTranslationTransport.home),
                  ),
                ),
              );
            },
            // App links (Douyin, Doubao app) cannot open inside the WebView.
            shouldOverrideUrlLoading: (controller, action) async {
              final scheme = action.request.url?.scheme;
              return scheme == 'http' || scheme == 'https'
                  ? NavigationActionPolicy.ALLOW
                  : NavigationActionPolicy.CANCEL;
            },
            onLoadStop: (controller, url) => unawaited(_capture()),
            onUpdateVisitedHistory: (controller, url, isReload) =>
                unawaited(_capture()),
            onProgressChanged: (controller, value) {
              if (mounted) setState(() => _progress = value / 100.0);
            },
            onReceivedError: (controller, request, error) {
              if (request.isForMainFrame == false || !mounted) return;
              // Type and host only: the query is not worth echoing.
              setState(() => _loadError = '${error.type} ${request.url.host}');
            },
          ),
          if (_loadError != null)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: FeedError(
                  title: context.l10n.loginPageLoadFailed,
                  error: _loadError,
                  onRetry: _reload,
                  retryLabel: context.l10n.retry,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
