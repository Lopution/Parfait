import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/network_policy.dart';
import 'package:pixiv_func/core/network/compat/network_providers.dart';
import 'package:pixiv_func/app/widgets/replica_button.dart';
import 'package:pixiv_func/app/widgets/replica_switch_tile.dart';
import 'package:pixiv_func/features/login/login_page.dart';
import 'package:pixiv_func/features/login/login_webview_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Minimal WebView platform stub so pages can build in widget tests.
class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakeWebViewController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(super.params) : super.implementation();

  Uri? lastLoadedUrl;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    lastLoadedUrl = params.uri;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation() {
    latest = this;
  }

  static _FakeNavigationDelegate? latest;

  NavigationRequestCallback? navigationRequest;
  WebResourceErrorCallback? webResourceError;
  HttpResponseErrorCallback? httpError;
  PageEventCallback? pageStarted;
  UrlChangeCallback? urlChange;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback? onNavigationRequest,
  ) async {
    navigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback? onPageStarted) async {
    pageStarted = onPageStarted;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback? onPageFinished) async {}

  @override
  Future<void> setOnProgress(ProgressCallback? onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback? onWebResourceError,
  ) async {
    webResourceError = onWebResourceError;
  }

  @override
  Future<void> setOnUrlChange(UrlChangeCallback? onUrlChange) async {
    urlChange = onUrlChange;
  }

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback? onHttpAuthRequest,
  ) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback? onHttpError) async {
    httpError = onHttpError;
  }

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback? onSslAuthError) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _NoCredentialStore implements CredentialStore {
  const _NoCredentialStore();

  @override
  Future<Credential?> read(String accountId) async => null;

  @override
  Future<void> write(String accountId, Credential credential) async {}

  @override
  Future<void> delete(String accountId) async {}
}

class _EmptyMetadataRepository implements AccountMetadataRepository {
  const _EmptyMetadataRepository();

  @override
  Future<AccountMetadataSnapshot> load() async =>
      const AccountMetadataSnapshot(accounts: []);

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    WebViewPlatform.instance = _FakeWebViewPlatform();
    _FakeNavigationDelegate.latest = null;
  });

  Widget wrap() {
    return ProviderScope(
      overrides: [
        credentialStoreProvider.overrideWithValue(const _NoCredentialStore()),
        accountMetadataRepositoryProvider.overrideWithValue(
          const _EmptyMetadataRepository(),
        ),
        oauthServiceProvider.overrideWithValue(
          OAuthService(exchangeTimeout: Duration.zero),
        ),
      ],
      child: const MaterialApp(home: LoginPage()),
    );
  }

  testWidgets('login button opens the OAuth WebView page', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ReplicaButton).last);
    await tester.pumpAndSettle();

    expect(find.byType(LoginWebViewPage), findsOneWidget);
  });

  testWidgets('register button opens the signup WebView page', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ReplicaButton).first);
    await tester.pumpAndSettle();

    expect(find.byType(LoginWebViewPage), findsOneWidget);
  });

  testWidgets(
    'subresource errors do not invalidate subsequent Pixiv login navigation',
    (tester) async {
      final service = OAuthService(exchangeTimeout: Duration.zero);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            credentialStoreProvider.overrideWithValue(
              const _NoCredentialStore(),
            ),
            accountMetadataRepositoryProvider.overrideWithValue(
              const _EmptyMetadataRepository(),
            ),
            oauthServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(home: LoginWebViewPage(oauthService: service)),
        ),
      );
      await tester.pumpAndSettle();

      final delegate = _FakeNavigationDelegate.latest;
      expect(delegate, isNotNull);
      expect(delegate!.navigationRequest, isNotNull);
      expect(delegate.webResourceError, isNotNull);
      expect(delegate.httpError, isNotNull);

      delegate.pageStarted?.call('https://accounts.pixiv.net/login');
      delegate.httpError!.call(
        HttpResponseError(
          request: WebResourceRequest(
            uri: Uri.parse('https://s.pximg.net/accounts/assets/app.js'),
          ),
          response: const WebResourceResponse(uri: null, statusCode: 404),
        ),
      );
      delegate.webResourceError!.call(
        const WebResourceError(
          errorCode: -7,
          description: 'subresource timeout',
          errorType: WebResourceErrorType.timeout,
          isForMainFrame: false,
          url: 'https://www.recaptcha.net/recaptcha/enterprise.js',
        ),
      );
      await tester.pump();

      final decision = await delegate.navigationRequest!.call(
        const NavigationRequest(
          url: 'https://accounts.pixiv.net/login?prompt=select_account',
          isMainFrame: true,
        ),
      );
      expect(decision, NavigationDecision.navigate);
      expect(find.text('已拒绝非 Pixiv 登录导航'), findsNothing);
    },
  );

  testWidgets('carries every destination the Pixiv login page chooses', (
    tester,
  ) async {
    final service = OAuthService(exchangeTimeout: Duration.zero);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          credentialStoreProvider.overrideWithValue(const _NoCredentialStore()),
          accountMetadataRepositoryProvider.overrideWithValue(
            const _EmptyMetadataRepository(),
          ),
          oauthServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(home: LoginWebViewPage(oauthService: service)),
      ),
    );
    await tester.pumpAndSettle();

    final delegate = _FakeNavigationDelegate.latest;
    expect(delegate, isNotNull);
    expect(delegate!.navigationRequest, isNotNull);
    delegate.pageStarted?.call('https://accounts.pixiv.net/login');

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
      final decision = await delegate.navigationRequest!.call(
        NavigationRequest(url: url, isMainFrame: true),
      );
      expect(decision, NavigationDecision.navigate, reason: url);
    }
    await tester.pump();
    expect(find.textContaining('已拒绝'), findsNothing);
  });

  // The login page must survive the ordinary interruptions of a real sign-in:
  // backgrounding to read a mail code, a blocked side link, and a
  // main-document status code. None of them may kill the PKCE session.
  Future<OAuthService> pumpLoginPage(WidgetTester tester) async {
    final service = OAuthService(exchangeTimeout: Duration.zero);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          credentialStoreProvider.overrideWithValue(const _NoCredentialStore()),
          accountMetadataRepositoryProvider.overrideWithValue(
            const _EmptyMetadataRepository(),
          ),
          oauthServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(home: LoginWebViewPage(oauthService: service)),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  Future<NavigationDecision> navigateTo(
    _FakeNavigationDelegate delegate,
    String url,
  ) async => delegate.navigationRequest!.call(
    NavigationRequest(url: url, isMainFrame: true),
  );

  testWidgets('backgrounding the app keeps the login session usable', (
    tester,
  ) async {
    await pumpLoginPage(tester);
    final delegate = _FakeNavigationDelegate.latest!;
    delegate.pageStarted?.call('https://accounts.pixiv.net/login');

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
      await navigateTo(delegate, 'https://accounts.pixiv.net/login?ref=mail'),
      NavigationDecision.navigate,
    );
  });

  testWidgets('a main-document HTTP error stays retryable', (tester) async {
    await pumpLoginPage(tester);
    final delegate = _FakeNavigationDelegate.latest!;
    delegate.pageStarted?.call('https://accounts.pixiv.net/login');

    delegate.httpError!.call(
      HttpResponseError(
        request: WebResourceRequest(
          uri: Uri.parse('https://accounts.pixiv.net/login'),
        ),
        response: const WebResourceResponse(uri: null, statusCode: 400),
      ),
    );
    await tester.pump();

    expect(find.text('网络错误 (HTTP 400)'), findsOneWidget);
    expect(find.text('重新打开'), findsNothing);
    expect(
      await navigateTo(delegate, 'https://accounts.pixiv.net/login?retry=1'),
      NavigationDecision.navigate,
    );
  });

  testWidgets('an invalid OAuth callback ends the attempt', (tester) async {
    await pumpLoginPage(tester);
    final delegate = _FakeNavigationDelegate.latest!;
    delegate.pageStarted?.call('https://accounts.pixiv.net/login');

    expect(
      await navigateTo(delegate, 'pixiv://account?error=access_denied'),
      NavigationDecision.prevent,
    );
    await tester.pump();

    // A consumed verifier cannot complete a sign-in, so the card offers to
    // reopen the page rather than to dismiss. Browsing itself is not blocked.
    expect(find.text('重新打开'), findsOneWidget);
    expect(find.text('知道了'), findsNothing);
  });

  testWidgets('login compatibility switch changes the real network policy', (
    tester,
  ) async {
    final policy = NetworkAccessPolicy();
    addTearDown(policy.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          networkAccessPolicyProvider.overrideWithValue(policy),
          credentialStoreProvider.overrideWithValue(const _NoCredentialStore()),
          accountMetadataRepositoryProvider.overrideWithValue(
            const _EmptyMetadataRepository(),
          ),
          oauthServiceProvider.overrideWithValue(
            OAuthService(exchangeTimeout: Duration.zero),
          ),
        ],
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(policy.mode, NetworkMode.automatic);
    await tester.tap(find.byType(ReplicaSwitchTile));
    expect(policy.mode, NetworkMode.directOnly);
  });
}
