import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/app/widgets/replica_button.dart';
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
  ) =>
      _FakeWebViewController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      _FakeWebViewWidget(params);
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
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback? onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback? onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback? onPageFinished) async {}

  @override
  Future<void> setOnProgress(ProgressCallback? onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback? onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback? onUrlChange) async {}

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback? onHttpAuthRequest,
  ) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback? onHttpError) async {}

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
  });

  Widget wrap() {
    return ProviderScope(
      overrides: [
        credentialStoreProvider.overrideWithValue(const _NoCredentialStore()),
        accountMetadataRepositoryProvider.overrideWithValue(
          const _EmptyMetadataRepository(),
        ),
        oauthServiceProvider
            .overrideWithValue(OAuthService(exchangeTimeout: Duration.zero)),
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
}
