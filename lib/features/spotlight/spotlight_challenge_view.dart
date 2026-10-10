import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/spotlight/article_parser.dart';
import '../../core/spotlight/spotlight_article_controller.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_repository.dart';
import '../../l10n/context.dart';

enum _ChallengePhase { verifying, interactive, failed }

/// Loads a pixivision article through the browser engine when Cloudflare
/// answers plain HTTP with a managed challenge.
///
/// The page first loads in a headless WebView (the way Mihon's Cloudflare
/// interceptor clears challenges off-screen) while the native loading state
/// stays visible. If the challenge has not cleared after
/// [automaticTimeout], it needs a tap: the same WebView is handed to an
/// on-screen widget so the user can finish it. Either way the rendered
/// article's HTML goes through the regular parser and [contentBuilder].
class SpotlightChallengeView extends ConsumerStatefulWidget {
  const SpotlightChallengeView({
    super.key,
    required this.uri,
    required this.contentBuilder,
  });

  /// Already validated by [PixivSpotlightRepository.articleUri].
  final Uri uri;
  final Widget Function(SpotlightArticleBody body) contentBuilder;

  static const automaticTimeout = Duration(seconds: 15);

  /// How often the document is probed while the challenge runs; page-finish
  /// events alone miss challenges that swap the document by script.
  static const probeInterval = Duration(seconds: 1);

  @override
  ConsumerState<SpotlightChallengeView> createState() =>
      _SpotlightChallengeViewState();
}

class _SpotlightChallengeViewState
    extends ConsumerState<SpotlightChallengeView> {
  /// True once the article element is in the document and Cloudflare's
  /// challenge options object is gone. Cheap, so it can run every second;
  /// the full HTML is read only once this passes.
  static const _articleReadyProbe =
      "document.querySelector('article') !== null && "
      "typeof window._cf_chl_opt === 'undefined'";

  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  Timer? _timeout;
  Timer? _probe;
  var _phase = _ChallengePhase.verifying;
  SpotlightArticleBody? _body;
  var _attempt = 0;
  var _probing = false;

  /// Set once the headless WebView moved into the on-screen widget, which
  /// then owns (and disposes) it.
  var _handedOver = false;

  late final _settings = InAppWebViewSettings(
    javaScriptEnabled: true,
    userAgent: PixivSpotlightRepository.articleUserAgent,
    // The desktop document, zoomed out to fit the phone while the user
    // completes a challenge.
    useWideViewPort: true,
    loadWithOverviewMode: true,
    supportZoom: true,
    builtInZoomControls: true,
    displayZoomControls: false,
  );

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _stopTimers();
    _releaseHeadless();
    super.dispose();
  }

  void _begin() {
    final languageTag = ref.read(settingsProvider).value?.languageTag;
    _phase = _ChallengePhase.verifying;
    _handedOver = false;
    _controller = null;
    _headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri.uri(widget.uri),
        headers: {'Accept-Language': languageTag ?? 'zh-CN'},
      ),
      initialSettings: _settings,
      onWebViewCreated: (controller) => _controller = controller,
      onLoadStop: (controller, _) => unawaited(_inspect()),
      onReceivedError: _onReceivedError,
    );
    unawaited(_headless!.run());
    _timeout = Timer(SpotlightChallengeView.automaticTimeout, _promote);
    _probe = Timer.periodic(
      SpotlightChallengeView.probeInterval,
      (_) => unawaited(_inspect()),
    );
  }

  void _onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    if (request.isForMainFrame == false) return;
    _fail();
  }

  Future<void> _inspect() async {
    final controller = _controller;
    if (controller == null || _probing || _body != null) return;
    if (_phase == _ChallengePhase.failed) return;
    _probing = true;
    try {
      final ready = await controller.evaluateJavascript(
        source: _articleReadyProbe,
      );
      if (ready != true) return;
      final html = await controller.evaluateJavascript(
        source: 'document.documentElement.outerHTML',
      );
      if (html is! String || !mounted) return;
      final body = parseSpotlightArticle(html);
      _stopTimers();
      ref.read(spotlightWebSessionProvider.notifier).markVerified();
      setState(() => _body = body);
      _releaseHeadless();
    } on Object {
      // Mid-navigation the controller can reject a script while the
      // challenge swaps documents; the next probe or the timeout decides.
    } finally {
      _probing = false;
    }
  }

  /// The challenge did not clear on its own: show the same WebView.
  void _promote() {
    if (!mounted || _body != null || _phase != _ChallengePhase.verifying) {
      return;
    }
    setState(() => _phase = _ChallengePhase.interactive);
  }

  void _fail() {
    if (!mounted || _body != null) return;
    _stopTimers();
    setState(() => _phase = _ChallengePhase.failed);
    _releaseHeadless();
  }

  void _retry() {
    _releaseHeadless();
    setState(() {
      _attempt++;
      _begin();
    });
  }

  void _stopTimers() {
    _timeout?.cancel();
    _probe?.cancel();
  }

  /// Disposes the headless WebView unless the on-screen widget took it over;
  /// that widget disposes it when it leaves the tree.
  void _releaseHeadless() {
    final headless = _headless;
    _headless = null;
    if (headless != null && !_handedOver) unawaited(headless.dispose());
  }

  void _openInBrowser() =>
      unawaited(launchUrl(widget.uri, mode: LaunchMode.externalApplication));

  @override
  Widget build(BuildContext context) {
    if (_body case final body?) return widget.contentBuilder(body);
    return switch (_phase) {
      _ChallengePhase.verifying => _verifying(context),
      _ChallengePhase.interactive => _interactive(context),
      _ChallengePhase.failed => _failed(context),
    };
  }

  Widget _verifying(BuildContext context) => Stack(
    children: [
      const FeedLoading(),
      Positioned(
        left: FuncSpacing.lg,
        right: FuncSpacing.lg,
        bottom: FuncSpacing.xl,
        child: Text(
          context.l10n.spotlightChallengeVerifying,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );

  Widget _interactive(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              FuncSpacing.lg,
              FuncSpacing.sm,
              FuncSpacing.sm,
              FuncSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(child: Text(l10n.spotlightChallengeManual)),
                TextButton(
                  onPressed: _openInBrowser,
                  child: Text(l10n.openInBrowser),
                ),
                TextButton(onPressed: _fail, child: Text(l10n.cancel)),
              ],
            ),
          ),
        ),
        Expanded(
          child: InAppWebView(
            key: ValueKey(_attempt),
            headlessWebView: _headless,
            initialSettings: _settings,
            onWebViewCreated: (controller) {
              _handedOver = true;
              _controller = controller;
            },
            onLoadStop: (controller, _) => unawaited(_inspect()),
            onReceivedError: _onReceivedError,
          ),
        ),
      ],
    );
  }

  Widget _failed(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.public_off,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: FuncSpacing.md),
            Text(l10n.spotlightChallengeFailed, textAlign: TextAlign.center),
            const SizedBox(height: FuncSpacing.md),
            StateActionButton(label: l10n.retry, onPressed: _retry),
            TextButton.icon(
              icon: const Icon(Icons.open_in_new),
              label: Text(l10n.openInBrowser),
              onPressed: _openInBrowser,
            ),
          ],
        ),
      ),
    );
  }
}
