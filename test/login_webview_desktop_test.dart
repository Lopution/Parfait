import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/features/login/login_webview_desktop_page.dart';
import 'package:pixiv_func/features/login/login_webview_error_card.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

/// Minimal InAppWebView platform stub — no implementation registers on the
/// Linux test host, so the page cannot build without one (same pattern as
/// reverse_image_search_page_test.dart).
class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  _FakeInAppWebViewWidget? lastWidget;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => lastWidget = _FakeInAppWebViewWidget(params);
}

class _FakeInAppWebViewWidget extends PlatformInAppWebViewWidget {
  _FakeInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Records the calls the page issues through the controller facade.
class _FakePlatformController extends PlatformInAppWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  final loadedUrls = <String>[];
  var reloadCount = 0;

  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {
    loadedUrls.add(urlRequest.url.toString());
  }

  @override
  Future<void> reload() async {
    reloadCount++;
  }

  @override
  Future<void> stopLoading() async {}

  @override
  void dispose({bool isKeepAlive = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  late _FakeInAppWebViewPlatform platform;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
    platform = _FakeInAppWebViewPlatform();
    InAppWebViewPlatform.instance = platform;
  });

  Future<InAppWebViewController> pumpDesktopLogin(
    WidgetTester tester, {
    bool create = false,
  }) async {
    final platformController = _FakePlatformController(
      const PlatformInAppWebViewControllerCreationParams(id: 'test'),
    );
    final controller = InAppWebViewController.fromPlatform(
      platform: platformController,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: accountProviderOverrides(),
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: LoginWebViewDesktopPage(
            oauthService: OAuthService(exchangeTimeout: Duration.zero),
            create: create,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Simulate the platform finishing WebView creation.
    platform.lastWidget!.params.onWebViewCreated?.call(controller);
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('desktop page builds the shared error card hierarchy', (
    tester,
  ) async {
    final controller = await pumpDesktopLogin(tester);

    expect(find.byType(InAppWebView), findsOneWidget);
    // The initial load went through the controller facade.
    expect(
      (controller.platform as _FakePlatformController).loadedUrls,
      isNotEmpty,
    );

    // A main-frame resource error surfaces the shared recoverable card:
    // reload + dismiss.
    platform.lastWidget!.params.onReceivedError?.call(
      controller,
      WebResourceRequest(
        url: WebUri('https://accounts.pixiv.net/login'),
        isForMainFrame: true,
      ),
      WebResourceError(
        description: 'aborted',
        type: WebResourceErrorType.CONNECTION_ABORTED,
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byType(LoginWebViewErrorCard);
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('重新加载')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('知道了')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('重新登录')),
      findsNothing,
    );
  });

  testWidgets('desktop fatal card offers the session restart', (tester) async {
    final controller = await pumpDesktopLogin(tester);

    // Engine detach is the fatal path: the PKCE session is discarded and
    // the card must offer the in-place restart instead of a mere reload.
    // Detached also disables frame scheduling, so resume afterwards to
    // let the recorded setState actually build the card.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    final card = find.byType(LoginWebViewErrorCard);
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('重新登录')),
      findsOneWidget,
    );
    expect(find.descendant(of: card, matching: find.text('知道了')), findsNothing);

    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();

    // The restart loads a fresh authorize URL into the same WebView.
    final platform = controller.platform as _FakePlatformController;
    expect(platform.loadedUrls.length, greaterThanOrEqualTo(2));
    expect(
      platform.loadedUrls.last,
      contains('https://app-api.pixiv.net/web/v1/login'),
    );
    expect(find.byType(LoginWebViewErrorCard), findsNothing);
  });

  testWidgets('signup fatal card offers reload, never a session restart', (
    tester,
  ) async {
    final controller = await pumpDesktopLogin(tester, create: true);
    final platform = controller.platform as _FakePlatformController;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    final card = find.byType(LoginWebViewErrorCard);
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('重新登录')),
      findsNothing,
    );
    expect(
      find.descendant(of: card, matching: find.text('重新加载')),
      findsOneWidget,
    );

    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(platform.reloadCount, 1);
    expect(find.byType(LoginWebViewErrorCard), findsNothing);
  });
}
