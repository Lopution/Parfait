import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

/// An [InAppWebViewPlatform] whose web views render nothing and accept every
/// call; [lastWidget] exposes the creation params of the latest one. The
/// real implementations are Android/iOS/macOS/Windows only, so a web view
/// cannot build in a Linux widget test without one. WebView2 reports as
/// installed.
class FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  FakeInAppWebViewWidget? lastWidget;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => lastWidget = FakeInAppWebViewWidget(params);

  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      _FakeWebViewEnvironment();
}

class FakeInAppWebViewWidget extends PlatformInAppWebViewWidget {
  FakeInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Records the calls a page makes through its controller; [facade] is what
/// the platform hands to `onWebViewCreated`.
class FakeInAppWebViewController extends PlatformInAppWebViewController {
  FakeInAppWebViewController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'test'),
      );

  late final facade = InAppWebViewController.fromPlatform(platform: this);
  final loadedUrls = <String>[];
  var reloadCount = 0;
  var stopCount = 0;

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
  Future<void> stopLoading() async {
    stopCount++;
  }

  @override
  void dispose({bool isKeepAlive = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FakeWebViewEnvironment extends PlatformWebViewEnvironment {
  _FakeWebViewEnvironment()
    : super.implementation(const PlatformWebViewEnvironmentCreationParams());

  @override
  Future<String?> getAvailableVersion({
    String? browserExecutableFolder,
  }) async => '1.0';

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
