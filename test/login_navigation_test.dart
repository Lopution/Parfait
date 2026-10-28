import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/settings/app_settings.dart' hide NetworkMode;
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/app/widgets/replica_switch_tile.dart';
import 'package:parfait/features/login/login_page.dart';
import 'package:parfait/features/login/login_webview_error_card.dart';
import 'package:parfait/features/login/login_webview_page.dart';

import 'helpers/fake_account.dart';
import 'helpers/fake_webview.dart';
import 'helpers/localized_app.dart';

/// The login page's web view as its platform drives it.
class _WebView {
  _WebView(this.params);

  final PlatformInAppWebViewWidgetCreationParams params;
  final controller = FakeInAppWebViewController();

  /// Asks before a main-frame navigation, as Android does.
  Future<NavigationActionPolicy?> navigate(String url) async =>
      params.shouldOverrideUrlLoading!(
        controller.facade,
        NavigationAction(
          request: URLRequest(url: WebUri(url)),
          isForMainFrame: true,
        ),
      );

  void httpError(String url, int status, {bool mainFrame = true}) =>
      params.onReceivedHttpError!(
        controller.facade,
        WebResourceRequest(url: WebUri(url), isForMainFrame: mainFrame),
        WebResourceResponse(statusCode: status),
      );

  void loadError(
    String url,
    WebResourceErrorType type, {
    bool mainFrame = true,
  }) => params.onReceivedError!(
    controller.facade,
    WebResourceRequest(url: WebUri(url), isForMainFrame: mainFrame),
    WebResourceError(type: type, description: 'failed'),
  );
}

/// Counts beginSession() calls so a test can prove a fatal card restarted
/// the PKCE session instead of just reloading or closing the page.
class _SpyOAuthService extends OAuthService {
  _SpyOAuthService() : super(exchangeTimeout: Duration.zero);

  var beginCount = 0;
  Uri? lastAuthorizeUrl;

  @override
  ({Uri authorizeUrl, String sessionId, String state}) beginSession() {
    beginCount++;
    final session = super.beginSession();
    lastAuthorizeUrl = session.authorizeUrl;
    return session;
  }
}

/// Holds the token exchange until [result] completes.
const _exchanged = OAuthResult(
  accountId: '7',
  credential: Credential(accessToken: 'a', refreshToken: 'r'),
  profile: OAuthUserProfile(userId: 7, name: 'n'),
);

class _HeldExchange extends OAuthService {
  _HeldExchange() : super(exchangeTimeout: Duration.zero);

  final result = Completer<OAuthResult>();

  @override
  Future<OAuthResult> exchangeCode(String code) => result.future;
}

/// Settings storage that fails a fixed number of reads, then succeeds.
/// Retry has to be observable as a real second read, not a rebuild.
class _FlakySettingsRepository implements SettingsRepository {
  _FlakySettingsRepository({required this.failures});

  int failures;
  int loadCount = 0;

  @override
  Future<AppSettings> load() async {
    loadCount++;
    if (failures > 0) {
      failures--;
      throw const SettingsRepositoryException('load', 'disk is gone');
    }
    return AppSettings.defaults();
  }

  @override
  Future<void> save(AppSettings settings) async {}
}

void main() {
  late FakeInAppWebViewPlatform platform;

  setUp(() {
    platform = FakeInAppWebViewPlatform();
    InAppWebViewPlatform.instance = platform;
  });

  Future<_WebView> pumpLoginPage(
    WidgetTester tester, {
    OAuthService? service,
    bool create = false,
    PlatformCaps? caps,
    FakeAccountMetadataRepository? accounts,
  }) async {
    final oauth = service ?? OAuthService(exchangeTimeout: Duration.zero);
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          ...accountProviderOverrides(metadataRepository: accounts),
          oauthServiceProvider.overrideWithValue(oauth),
          if (caps != null) platformCapsProvider.overrideWithValue(caps),
        ],
        home: LoginWebViewPage(oauthService: oauth, create: create),
      ),
    );
    await tester.pumpAndSettle();
    final webView = _WebView(platform.lastWidget!.params);
    webView.params.onWebViewCreated!(webView.controller.facade);
    await tester.pumpAndSettle();
    return webView;
  }

  testWidgets(
    'subresource errors do not invalidate subsequent Pixiv login navigation',
    (tester) async {
      final webView = await pumpLoginPage(tester);

      webView.httpError(
        'https://s.pximg.net/accounts/assets/app.js',
        404,
        mainFrame: false,
      );
      webView.loadError(
        'https://www.recaptcha.net/recaptcha/enterprise.js',
        WebResourceErrorType.TIMEOUT,
        mainFrame: false,
      );
      await tester.pump();

      expect(
        await webView.navigate(
          'https://accounts.pixiv.net/login?prompt=select_account',
        ),
        NavigationActionPolicy.ALLOW,
      );
      expect(find.byType(LoginWebViewErrorCard), findsNothing);
    },
  );

  testWidgets('carries every destination the Pixiv login page chooses', (
    tester,
  ) async {
    final webView = await pumpLoginPage(tester);

    // Pixiv hands the flow to its own oauth host, to captcha vendors and to
    // third-party identity providers. All of it is one real login.
    const urls = [
      'https://oauth.secure.pixiv.net/auth/authorize',
      'https://accounts.google.com/o/oauth2/v2/auth',
      'https://appleid.apple.com/auth/authorize',
      'https://www.facebook.com/v23.0/dialog/oauth',
      'https://api.weibo.com/oauth2/authorize',
      'https://www.recaptcha.net/recaptcha/enterprise/anchor',
    ];
    for (final url in urls) {
      expect(
        await webView.navigate(url),
        NavigationActionPolicy.ALLOW,
        reason: url,
      );
    }
    await tester.pump();
    expect(find.byType(LoginWebViewErrorCard), findsNothing);
  });

  // The login page must survive the ordinary interruptions of a real sign-in:
  // backgrounding to read a mail code, a blocked side link, and a
  // main-document status code. None of them may kill the PKCE session.
  testWidgets('backgrounding the app keeps the login session usable', (
    tester,
  ) async {
    final webView = await pumpLoginPage(tester);

    // Reading a verification code in a mail app walks the full foreground
    // exit sequence and comes back.
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }

    expect(find.text('页面已暂停，请重新打开'), findsNothing);
    expect(
      await webView.navigate('https://accounts.pixiv.net/login?ref=mail'),
      NavigationActionPolicy.ALLOW,
    );
  });

  testWidgets('a main-document HTTP error stays retryable', (tester) async {
    final webView = await pumpLoginPage(tester);

    webView.httpError('https://accounts.pixiv.net/login', 400);
    await tester.pump();

    expect(find.text('网络错误（HTTP 400 accounts.pixiv.net）'), findsOneWidget);
    expect(find.text('重新打开'), findsNothing);
    expect(
      await webView.navigate('https://accounts.pixiv.net/login?retry=1'),
      NavigationActionPolicy.ALLOW,
    );
  });

  testWidgets('an invalid OAuth callback ends the attempt', (tester) async {
    final webView = await pumpLoginPage(tester);

    expect(
      await webView.navigate('pixiv://account?error=access_denied'),
      NavigationActionPolicy.CANCEL,
    );
    await tester.pump();

    // A consumed verifier cannot complete a sign-in, so the card offers to
    // restart the session in place rather than to dismiss. Browsing itself
    // is not blocked.
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('重新打开'), findsNothing);
    expect(find.text('知道了'), findsNothing);

    // The headline is plain copy; the developer reason only appears behind
    // the details disclosure.
    expect(find.text('登录回调无效，请重新登录'), findsOneWidget);
    expect(find.textContaining('missing code'), findsNothing);
    await tester.tap(find.text('详情'));
    await tester.pump();
    expect(find.text('missing code'), findsOneWidget);
  });

  testWidgets('leaving during the token exchange drops its outcome', (
    tester,
  ) async {
    // Left while the exchange runs, or once it is back but its save waits
    // behind another account write.
    for (final (fails, queued) in [
      (true, false),
      (false, false),
      (false, true),
    ]) {
      await tester.pumpWidget(const SizedBox());
      final service = _HeldExchange();
      final accounts = FakeAccountMetadataRepository();
      final webView = await pumpLoginPage(
        tester,
        service: service,
        accounts: accounts,
      );
      final saves = Completer<void>();
      if (queued) {
        accounts.saveGate = saves.future;
        final container = ProviderScope.containerOf(
          tester.element(find.byType(LoginWebViewPage)),
        );
        await container.read(accountStoreProvider.future);
        final store = container.read(accountStoreProvider.notifier);
        unawaited(store.updateAccount(testerAccount));
      }
      await webView.navigate('pixiv://account?code=abc');
      await tester.pump();
      if (queued) service.result.complete(_exchanged);
      await tester.pump();
      // Left the way the app leaves it: the providers stay.
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .pushReplacement(
              MaterialPageRoute<void>(builder: (_) => const SizedBox()),
            ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LoginWebViewPage), findsNothing);
      if (fails) {
        service.result.completeError(StateError('exchange failed'));
      } else if (!queued) {
        service.result.complete(_exchanged);
      }
      saves.complete();
      await tester.pump();
      final reason = 'fails: $fails, queued: $queued';
      expect(tester.takeException(), isNull, reason: reason);
      expect(
        accounts.accounts.map((account) => account.id),
        isEmpty,
        reason: 'leaving is a cancel; $reason',
      );
    }
  });

  testWidgets('Windows stops the callback as it starts or lands in history', (
    tester,
  ) async {
    // WebView2 is not asked before navigations (see WebNavigationGuard):
    // the page stops the callback when it starts, and when a server-side
    // redirect only shows up as a history update.
    final webView = await pumpLoginPage(
      tester,
      caps: const PlatformCaps(isWindows: true),
    );
    expect(webView.params.shouldOverrideUrlLoading, isNull);
    final facade = webView.controller.facade;

    webView.params.onLoadStart!(
      facade,
      WebUri('https://accounts.pixiv.net/login'),
    );
    expect(webView.controller.stopCount, 0);

    webView.params.onUpdateVisitedHistory!(
      facade,
      WebUri('pixiv://account?error=access_denied'),
      false,
    );
    await tester.pump();
    expect(webView.controller.stopCount, 1);
    expect(find.text('登录回调无效，请重新登录'), findsOneWidget);
  });

  testWidgets('a recoverable error card reloads the page in place', (
    tester,
  ) async {
    final webView = await pumpLoginPage(tester);

    webView.httpError('https://accounts.pixiv.net/login', 400);
    await tester.pump();
    expect(find.text('网络错误（HTTP 400 accounts.pixiv.net）'), findsOneWidget);

    await tester.tap(find.text('重新加载'));
    await tester.pump();

    // Reload re-runs the current document — the route stays put.
    expect(webView.controller.reloadCount, 1);
    expect(find.text('网络错误（HTTP 400 accounts.pixiv.net）'), findsNothing);
    expect(find.byType(LoginWebViewPage), findsOneWidget);
  });

  testWidgets('the fatal card restarts the PKCE session in place', (
    tester,
  ) async {
    final service = _SpyOAuthService();
    final webView = await pumpLoginPage(tester, service: service);
    final controller = webView.controller;
    expect(service.beginCount, 1);
    expect(controller.loadedUrls, ['${service.lastAuthorizeUrl}']);

    expect(
      await webView.navigate('pixiv://account?error=access_denied'),
      NavigationActionPolicy.CANCEL,
    );
    await tester.pump();
    expect(find.text('重新登录'), findsOneWidget);

    await tester.tap(find.text('重新登录'));
    await tester.pump();

    // Restart means a real second PKCE session whose fresh authorize URL is
    // loaded into the same WebView — not a page reopen.
    expect(service.beginCount, 2);
    expect(controller.loadedUrls.last, '${service.lastAuthorizeUrl}');
    expect(controller.reloadCount, 0);
    expect(find.text('重新登录'), findsNothing);
    expect(find.byType(LoginWebViewPage), findsOneWidget);
    // The new session is live: normal Pixiv navigation still proceeds.
    expect(
      await webView.navigate('https://accounts.pixiv.net/login?retry=1'),
      NavigationActionPolicy.ALLOW,
    );
  });

  testWidgets('signup mode fatal card offers reload, never a session restart', (
    tester,
  ) async {
    final webView = await pumpLoginPage(tester, create: true);
    final controller = webView.controller;
    expect(controller.loadedUrls, ['https://accounts.pixiv.net/signup']);

    // Engine detach is the fatal path reachable in signup mode. Detach
    // disables frame production, so resume before asserting the card.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(find.text('重新登录'), findsNothing);
    expect(find.text('重新加载'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    expect(controller.reloadCount, 1);

    // After the reload the fatal flag must be gone too — otherwise a
    // follow-up main-frame failure is swallowed by _reportRecoverable's
    // `if (_fatal) return` guard and the WebView fails silently.
    webView.loadError(
      'https://accounts.pixiv.net/signup',
      WebResourceErrorType.HOST_LOOKUP,
    );
    await tester.pump();
    expect(find.text('页面加载失败'), findsOneWidget);
  });

  testWidgets('error messages carry type and host, never the full URL', (
    tester,
  ) async {
    final webView = await pumpLoginPage(tester);

    webView.loadError(
      'https://accounts.pixiv.net/login?code=secret&state=abc',
      WebResourceErrorType.TIMEOUT,
    );
    await tester.pump();

    // '<type> <host>' behind the details disclosure: the query string must
    // not leak into the card.
    expect(find.text('页面加载失败'), findsOneWidget);
    await tester.tap(find.text('详情'));
    await tester.pump();
    expect(find.text('TIMEOUT accounts.pixiv.net'), findsOneWidget);
    expect(find.textContaining('code=secret'), findsNothing);

    // HTTP errors follow the same '<status> <host>' contract.
    await tester.tap(find.text('知道了'));
    await tester.pump();
    webView.httpError('https://accounts.pixiv.net/login?ref=x', 403);
    await tester.pump();
    expect(find.text('网络错误（HTTP 403 accounts.pixiv.net）'), findsOneWidget);
    expect(find.textContaining('ref=x'), findsNothing);
  });

  testWidgets('login compatibility switch changes the real network policy', (
    tester,
  ) async {
    final policy = NetworkAccessPolicy();
    addTearDown(policy.dispose);
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          networkAccessPolicyProvider.overrideWithValue(policy),
          ...accountProviderOverrides(),
          oauthServiceProvider.overrideWithValue(
            OAuthService(exchangeTimeout: Duration.zero),
          ),
        ],
        home: LoginPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(policy.mode, NetworkMode.automatic);
    await tester.tap(find.byType(ReplicaSwitchTile));
    expect(policy.mode, NetworkMode.directOnly);
  });

  group('C11: settings read failure on the login page', () {
    Widget wrapWithRepository(SettingsRepository repository) => ProviderScope(
      // Riverpod 3 retries a failed provider build on its own backoff. That
      // is real app behaviour, but it makes the read count here ambiguous —
      // switch it off so every load is one the page actually asked for.
      retry: (retryCount, error) => null,
      overrides: [
        settingsRepositoryProvider.overrideWithValue(repository),
        ...accountProviderOverrides(),
        oauthServiceProvider.overrideWithValue(
          OAuthService(exchangeTimeout: Duration.zero),
        ),
      ],
      child: localizedApp(home: LoginPage()),
    );

    testWidgets('retry performs a real second read and recovers', (
      tester,
    ) async {
      final repository = _FlakySettingsRepository(failures: 1);
      await tester.pumpWidget(wrapWithRepository(repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-load-retry')));
      await tester.pumpAndSettle();

      expect(repository.loadCount, 2, reason: 'retry re-reads storage');
      expect(find.byKey(const Key('settings-load-error')), findsNothing);
      expect(find.byType(ReplicaButton), findsNWidgets(2));
    });
  });
}
