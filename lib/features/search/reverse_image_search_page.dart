import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/platform/intent_router.dart';
import '../../core/platform/platform_caps.dart';
import '../../core/reverse_image/desktop_image_input.dart';
import '../../core/reverse_image/image_input.dart';
import '../../core/reverse_image/reverse_image_controller.dart';
import '../../core/reverse_image/reverse_image_external.dart';
import '../../core/reverse_image/reverse_image_platform.dart';
import '../../core/reverse_image/reverse_image_provider.dart';
import '../../core/reverse_image/sauce_nao_navigation_policy.dart';
import '../../core/reverse_image/sauce_nao_provider.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/app_snack_bar.dart';
import 'package:pixiv_func/core/network/http_client_providers.dart';
import '../../l10n/context.dart';

class ReverseImageSearchPage extends ConsumerStatefulWidget {
  const ReverseImageSearchPage({
    super.key,
    this.initialReference,
    this.platform,
    this.provider,
    this.externalLauncher,
  });

  final ReverseImageInputReference? initialReference;
  final ReverseImageInputPlatform? platform;
  final ReverseImageProvider? provider;
  final ReverseImageExternalLauncher? externalLauncher;

  @override
  ConsumerState<ReverseImageSearchPage> createState() =>
      _ReverseImageSearchPageState();
}

class _ReverseImageSearchPageState
    extends ConsumerState<ReverseImageSearchPage> {
  late final ReverseImageSearchSession _session;
  late final ReverseImageExternalLauncher _externalLauncher;
  ProviderSubscription<ReverseImageFlowState>? _flowSubscription;

  @override
  void initState() {
    super.initState();
    _session = ReverseImageSearchSession(
      platform:
          widget.platform ??
          (PlatformCaps.system().isAndroid
              ? MethodChannelReverseImageInputPlatform()
              : const DesktopReverseImageInputPlatform()),
      provider:
          widget.provider ??
          SauceNaoWebViewProvider(
            client: ref.read(thirdPartyHttpClientProvider),
          ),
    );
    _externalLauncher =
        widget.externalLauncher ?? MethodChannelReverseImageExternalLauncher();
    _flowSubscription = ref.listenManual(
      reverseImageSearchControllerProvider(_session),
      (_, _) {
        if (mounted) setState(() {});
      },
    );
    final reference = widget.initialReference;
    if (reference != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            ref
                .read(reverseImageSearchControllerProvider(_session).notifier)
                .prepare(reference),
          );
        }
      });
    }
  }

  ReverseImageSearchController get _controller =>
      ref.read(reverseImageSearchControllerProvider(_session).notifier);

  @override
  void dispose() {
    _flowSubscription?.close();
    super.dispose();
  }

  Future<void> _cancelAndPop() async {
    await _controller.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _search() => _controller.search();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reverseImageSearchControllerProvider(_session));
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.searchReverseImage),
        leading: IconButton(
          tooltip: context.l10n.searchReverseCancel,
          onPressed: _cancelAndPop,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(child: _body(context, state)),
    );
  }

  Widget _body(BuildContext context, ReverseImageFlowState state) {
    return switch (state.status) {
      ReverseImageFlowStatus.idle ||
      ReverseImageFlowStatus.canceled => _idle(context),
      ReverseImageFlowStatus.picking => _progress(
        context,
        context.l10n.searchReversePreparing,
      ),
      ReverseImageFlowStatus.preparing => _progress(
        context,
        context.l10n.searchReversePreparing,
      ),
      ReverseImageFlowStatus.searching => _progress(
        context,
        context.l10n.searchReverseSearching,
      ),
      ReverseImageFlowStatus.ready => _ready(context, state),
      ReverseImageFlowStatus.failure => _failure(context, state),
      ReverseImageFlowStatus.success =>
        state.webView != null
            ? _sauceNaoWebView(context, state.webView!)
            : _results(context, state),
    };
  }

  Widget _sauceNaoWebView(
    BuildContext context,
    ReverseImageSearchWebView webView,
  ) {
    return _ControlledSauceNaoWebView(
      webView: webView,
      onOpenExternal: _openExternal,
    );
  }

  Widget _idle(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 32),
          const Icon(Icons.image_search_outlined, size: 72),
          const SizedBox(height: 18),
          Text(context.l10n.searchReverseIntro, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          _privacyCard(context),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _controller.pick,
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(context.l10n.searchReversePick),
          ),
        ],
      ),
    );
  }

  Widget _privacyCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.privacy_tip_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.searchReversePrivacy,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(context.l10n.searchReversePrivacyDetail),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progress(BuildContext context, String label) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            Text(label),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: _cancelAndPop,
              child: Text(context.l10n.searchReverseCancel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ready(BuildContext context, ReverseImageFlowState state) {
    final input = state.input!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _privacyCard(context),
          const SizedBox(height: 16),
          Text(
            context.l10n.searchReverseReady,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: input.width / input.height,
              child: Image.file(
                File(input.path),
                fit: BoxFit.contain,
                cacheWidth: 1024,
                cacheHeight: 1024,
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Icon(Icons.broken_image_outlined, size: 56),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${input.width} × ${input.height} · ${_formatBytes(input.sizeBytes)}',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _search,
            icon: const Icon(Icons.search),
            label: Text(context.l10n.searchReverseUse),
          ),
        ],
      ),
    );
  }

  Widget _failure(BuildContext context, ReverseImageFlowState state) {
    final failure = state.failure!;
    final seconds = failure.retryAfter?.inSeconds;
    final message = failure.code == ReverseImageProviderFailureCode.challenge
        ? context.l10n.searchReverseChallenge
        : failure.code == ReverseImageProviderFailureCode.providerUnavailable
        ? context.l10n.searchReverseUnavailableDetail
        : failure.code == ReverseImageProviderFailureCode.dailyLimit
        ? context.l10n.searchReverseDailyLimit
        : failure.code == ReverseImageProviderFailureCode.rateLimited &&
              seconds != null
        ? context.l10n.searchReverseRateLimitedWait(seconds)
        : failure.code == ReverseImageProviderFailureCode.rateLimited
        ? context.l10n.searchReverseRateLimited
        : failure.message;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _controller.pick,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(context.l10n.searchReverseRetry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context, ReverseImageFlowState state) {
    if (state.results.isEmpty) {
      return Center(child: Text(context.l10n.searchReverseNoResults));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: state.results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final hit = state.results[index];
        final title =
            hit.title ??
            (hit.pixivId == null
                ? hit.externalUrl!.host
                : 'Pixiv #${hit.pixivId}');
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Text(hit.similarity.toStringAsFixed(0)),
            ),
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${hit.similarity.toStringAsFixed(1)}%'),
            trailing: hit.pixivId != null
                ? const Icon(Icons.chevron_right)
                : OutlinedButton(
                    onPressed: () => _openExternal(hit.externalUrl!),
                    child: Text(context.l10n.searchReverseOpenExternal),
                  ),
            onTap: hit.pixivId == null
                ? () => _openExternal(hit.externalUrl!)
                : () => openIllust(context, hit.pixivId!),
          ),
        );
      },
    );
  }

  Future<void> _openExternal(Uri uri) async {
    try {
      await _externalLauncher.open(uri);
    } on Object {
      if (!mounted) return;
      showAppSnackBar(context, context.l10n.searchReverseOpenFailed);
    }
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

/// Controlled SauceNAO result WebView (D1): navigates freely inside
/// saucenao.com, routes Pixiv links into the app (detail / user pages),
/// sends every other HTTPS link to the external launcher and rejects
/// non-HTTPS navigation. Errors stay visible; the WebView never renders
/// into an empty-looking success.
class _ControlledSauceNaoWebView extends StatefulWidget {
  const _ControlledSauceNaoWebView({
    required this.webView,
    required this.onOpenExternal,
  });

  final ReverseImageSearchWebView webView;
  final Future<void> Function(Uri uri) onOpenExternal;

  @override
  State<_ControlledSauceNaoWebView> createState() =>
      _ControlledSauceNaoWebViewState();
}

class _ControlledSauceNaoWebViewState
    extends State<_ControlledSauceNaoWebView> {
  late final WebViewController _controller;
  String? _error;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress / 100.0);
          },
          onNavigationRequest: _onNavigationRequest,
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() {
                _error =
                    '${context.l10n.searchReversePageLoadFailed} '
                    '(${error.errorType})';
              });
            }
          },
        ),
      );
    final result = widget.webView;
    if (result.html != null) {
      _controller.loadHtmlString(
        result.html!,
        baseUrl: SauceNaoWebViewProvider.defaultEndpoint,
      );
    } else {
      _controller.loadRequest(result.resultUrl!);
    }
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final action = SauceNaoNavigationPolicy.decide(Uri.tryParse(request.url));
    switch (action) {
      case SauceNaoNavigationAction.navigate:
        return NavigationDecision.navigate;
      case SauceNaoNavigationAction.openIllust:
        final id = _illustId(request.url);
        if (id != null) {
          openIllust(context, id);
        } else {
          unawaited(widget.onOpenExternal(Uri.parse(request.url)));
        }
        return NavigationDecision.prevent;
      case SauceNaoNavigationAction.openUser:
        final id = _userId(request.url);
        if (id != null) {
          openUser(context, id);
        } else {
          unawaited(widget.onOpenExternal(Uri.parse(request.url)));
        }
        return NavigationDecision.prevent;
      case SauceNaoNavigationAction.openExternal:
        final uri = Uri.tryParse(request.url);
        if (uri != null) unawaited(widget.onOpenExternal(uri));
        return NavigationDecision.prevent;
      case SauceNaoNavigationAction.reject:
        return NavigationDecision.prevent;
    }
  }

  static int? _illustId(String url) {
    final route = IntentRouter.route(Uri.parse(url));
    return switch (route) {
      IllustRoute(:final illustId) => illustId,
      _ => null,
    };
  }

  static int? _userId(String url) {
    final route = IntentRouter.route(Uri.parse(url));
    return switch (route) {
      UserRoute(:final userId) => userId,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        WebViewWidget(controller: _controller),
        if (_progress != null && _progress! < 1.0)
          LinearProgressIndicator(value: _progress, minHeight: 2),
      ],
    );
  }
}
