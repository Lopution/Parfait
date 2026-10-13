import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

/// An [InAppWebViewPlatform] whose web views render nothing and accept every
/// call; [lastWidget] exposes the creation params of the latest one. The
/// real implementations are Android/iOS/macOS/Windows only, so a web view
/// cannot build in a Linux widget test without one.
class FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  FakeInAppWebViewWidget? lastWidget;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => lastWidget = FakeInAppWebViewWidget(params);
}

class FakeInAppWebViewWidget extends PlatformInAppWebViewWidget {
  FakeInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
