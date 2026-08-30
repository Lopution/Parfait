import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../../core/network/compat/network_policy.dart';
import 'login_intercept_controller.dart';

/// Android PlatformView wrapper for the login WebView with request
/// interception (PRD R7 / design.md §WebView 方案 A).
///
/// Only meaningful on Android; on other platforms this widget is unusable
/// and callers must keep webview_flutter (the login page keeps both paths
/// via a settings-controlled switch).
///
/// Events (pageStarted, urlChanged, progress, webResourceError) arrive from
/// the native WebViewClient through the interception events channel; the
/// navigation decision (PKCE callback interception) is answered in Dart via
/// [onNavigationDecision].
class LoginInterceptedWebView extends StatefulWidget {
  const LoginInterceptedWebView({
    super.key,
    required this.policy,
    required this.initialUrl,
    required this.onPageStarted,
    required this.onUrlChanged,
    required this.onProgress,
    this.onWebResourceError,
    this.onNavigationDecision,
  });

  final NetworkAccessPolicy policy;
  final String initialUrl;
  final void Function(String url) onPageStarted;
  final void Function(String url) onUrlChanged;
  final void Function(double progress) onProgress;
  final void Function(String description)? onWebResourceError;

  /// Answers "may the WebView navigate to [url]?"; null = always allow.
  /// Returning false prevents the native navigation (used for the
  /// `pixiv://account?code=` callback: Dart exchanges the code and the
  /// native WebView stops).
  final bool Function(String url)? onNavigationDecision;

  @override
  State<LoginInterceptedWebView> createState() =>
      _LoginInterceptedWebViewState();
}

class _LoginInterceptedWebViewState extends State<LoginInterceptedWebView> {
  static const _eventsChannel = 'pixivfunc/login_webview_intercept_events';
  static const _controlChannel = 'pixivfunc/login_webview_control';
  static const _viewType = 'pixivfunc/login_webview';
  late final MethodChannel _events;
  LoginWebViewInterceptController? _intercept;
  void Function()? _disposeIntercept;

  @override
  void initState() {
    super.initState();
    _events = MethodChannel(_eventsChannel);
    _events.setMethodCallHandler(_handleEvent);
    // Registers the pixivfunc/login_webview_intercept handler that the
    // native shouldInterceptRequest callback calls. The controller keeps
    // the policy-owned client; it must be alive for the whole PlatformView
    // lifetime and disposed after the view is destroyed.
    _intercept = LoginWebViewInterceptController(widget.policy);
    _disposeIntercept = _intercept!.register();
  }

  @override
  void dispose() {
    _events.setMethodCallHandler(null);
    _disposeIntercept?.call();
    super.dispose();
  }

  Future<Object?> _handleEvent(MethodCall call) async {
    final args =
        (call.arguments as Map<Object?, Object?>?)?.cast<String, Object?>() ??
        const <String, Object?>{};
    switch (call.method) {
      case 'pageStarted':
        final url = args['url'] as String?;
        if (url != null) widget.onPageStarted(url);
        return null;
      case 'urlChanged':
        final url = args['url'] as String?;
        if (url != null) widget.onUrlChanged(url);
        return null;
      case 'progress':
        final value = args['value'];
        if (value is num) widget.onProgress(value / 100.0);
        return null;
      case 'webResourceError':
        final description = args['description'] as String?;
        widget.onWebResourceError?.call(description ?? 'page load error');
        return null;
      case 'navigationRequest':
        final url = args['url'] as String?;
        if (url == null || widget.onNavigationDecision == null) return true;
        return widget.onNavigationDecision!(url);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError(
        'LoginInterceptedWebView is Android-only; callers must fall back '
        'to webview_flutter on other platforms.',
      );
    }
    return AndroidView(
      viewType: _viewType,
      creationParams: {'initialUrl': widget.initialUrl},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (id) {
        MethodChannel(_controlChannel).invokeMethod<void>('load', {
          'url': widget.initialUrl,
        });
      },
    );
  }
}
