import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/platform/platform_caps.dart';

/// Where an embedded [InAppWebView] stops a navigation the page hands
/// elsewhere: an OAuth callback, a link the app opens itself.
///
/// Before the navigation (`shouldOverrideUrlLoading`) wherever the platform
/// allows it, server-side redirects included. Android cancels the main
/// frame's navigation, asks [stops] and loads the URL again with its headers
/// when allowed, as webview_flutter did; subframes are not asked, since
/// `loadUrl` cannot load one. Windows implements the hook through CDP
/// `Fetch.requestPaused`, which pauses every document hop: Pixiv's authorize
/// → post-redirect → login chain died mid-redirect as CONNECTION_ABORTED.
/// There the navigation is stopped as it starts ([onLoadStart]).
class WebNavigationGuard {
  WebNavigationGuard(PlatformCaps caps, this.stops)
    : beforeLoad = !caps.isWindows;

  /// Whether the main frame's navigation to a URL must not go on; it may
  /// act on the URL (open a page, exchange a code).
  final bool Function(String url) stops;

  /// Whether navigations are asked about before they happen.
  final bool beforeLoad;

  InAppWebViewSettings get settings => InAppWebViewSettings(
    javaScriptEnabled: true,
    useShouldOverrideUrlLoading: beforeLoad,
  );

  Future<NavigationActionPolicy?> Function(
    InAppWebViewController controller,
    NavigationAction action,
  )?
  get shouldOverrideUrlLoading => beforeLoad ? _beforeLoad : null;

  void Function(InAppWebViewController controller, WebUri? url)?
  get onLoadStart => beforeLoad ? null : stopAsStarted;

  Future<NavigationActionPolicy?> _beforeLoad(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final url = action.request.url;
    if (url == null || !action.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }
    return stops(url.toString())
        ? NavigationActionPolicy.CANCEL
        : NavigationActionPolicy.ALLOW;
  }

  /// Stops a navigation that has started, when [stops] says so.
  void stopAsStarted(InAppWebViewController controller, WebUri? url) {
    if (url == null) return;
    if (stops(url.toString())) controller.stopLoading();
  }
}
