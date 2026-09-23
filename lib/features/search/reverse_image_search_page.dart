import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/platform/android_intent_channel.dart';
import '../../core/platform/intent_router.dart';
import '../../core/platform/platform_caps.dart';
import '../../core/reverse_image/desktop_image_input.dart';
import '../../core/reverse_image/image_input.dart';
import '../../core/reverse_image/iqdb_provider.dart';
import '../../core/reverse_image/reverse_image_controller.dart';
import '../../core/reverse_image/reverse_image_engine.dart';
import '../../core/reverse_image/reverse_image_external.dart';
import '../../core/reverse_image/reverse_image_navigation_policy.dart';
import '../../core/reverse_image/reverse_image_platform.dart';
import '../../core/reverse_image/reverse_image_provider.dart';
import '../../core/reverse_image/sauce_nao_provider.dart';
import '../../core/reverse_image/webview_upload_provider.dart';
import '../../core/settings/settings_controller.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/app_snack_bar.dart';
import 'package:pixiv_func/core/network/http_client_providers.dart';
import '../../l10n/context.dart';

class ReverseImageSearchPage extends ConsumerStatefulWidget {
  const ReverseImageSearchPage({
    super.key,
    this.initialReference,
    this.platform,
    this.providers,
    this.initialEngine,
    this.uploadArmer,
    this.externalLauncher,
  });

  final ReverseImageInputReference? initialReference;
  final ReverseImageInputPlatform? platform;

  /// Test/embed override: engine → provider map. Defaults to the four real
  /// engines over the shared third-party HTTP client.
  final Map<ReverseImageEngine, ReverseImageProvider>? providers;
  final ReverseImageEngine? initialEngine;
  final ReverseImageUploadArmer? uploadArmer;
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

  /// Last held input, kept only as the task-header's thumbnail source for
  /// terminal states that already released the file (headless/webView
  /// success). The controller still owns the temp file's lifecycle — this
  /// reference never extends it; the cached decode survives deletion via
  /// the image cache and falls back to a placeholder on eviction.
  ReverseImageInputInfo? _lastInput;

  @override
  void initState() {
    super.initState();
    final isAndroid = PlatformCaps.system().isAndroid;
    _session = ReverseImageSearchSession(
      platform:
          widget.platform ??
          (isAndroid
              ? MethodChannelReverseImageInputPlatform()
              : const DesktopReverseImageInputPlatform()),
      providers:
          widget.providers ??
          _defaultProviders(ref.read(thirdPartyHttpClientProvider)),
      initialEngine:
          widget.initialEngine ?? ref.read(reverseImageEngineProvider),
      uploadArmer:
          widget.uploadArmer ??
          (isAndroid
              ? MethodChannelReverseImageUploadArmer()
              : const NoopReverseImageUploadArmer()),
    );
    _externalLauncher =
        widget.externalLauncher ??
        OutboundReverseImageExternalLauncher(
          ref.read(outboundUrlOpenerProvider),
        );
    _flowSubscription = ref.listenManual(
      reverseImageSearchControllerProvider(_session),
      (_, next) {
        if (next.input != null) {
          _lastInput = next.input;
        } else if (next.status == ReverseImageFlowStatus.idle ||
            next.status == ReverseImageFlowStatus.canceled) {
          // Flow reset — a stale thumbnail must not survive into the next
          // pick's context strip.
          _lastInput = null;
        }
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

  /// Engine choice is durable: the flow switches immediately when an image
  /// is held, and the selection is persisted either way.
  void _selectEngine(ReverseImageEngine engine) {
    unawaited(_controller.selectEngine(engine));
    unawaited(
      ref.read(settingsProvider.notifier).selectReverseImageEngine(engine),
    );
  }

  /// Engine selector chips. A chip is disabled when the current input breaks
  /// that engine's own constraints (IQDB: no WebP, 8 MiB / 7500 px caps);
  /// engines that already failed this image carry an error avatar.
  Widget _engineChips(BuildContext context, ReverseImageFlowState state) {
    final input = state.input;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        for (final spec in ReverseImageEngineSpecs.all.values)
          ChoiceChip(
            label: Text(spec.displayName),
            selected: state.engine == spec.engine,
            avatar: state.engineFailures.containsKey(spec.engine)
                ? const Icon(Icons.error_outline, size: 18)
                : null,
            tooltip: input != null && !spec.supportsInput(input)
                ? context.l10n.searchReverseEngineUnsupported
                : null,
            onSelected: input != null && !spec.supportsInput(input)
                ? null
                : (_) => _selectEngine(spec.engine),
          ),
      ],
    );
  }

  /// The task header is the "what am I looking at" strip: thumbnail +
  /// engine + phase. It exists in every phase that carries an image
  /// context — ready/searching/failure and all three success surfaces —
  /// and disappears on idle/picking/preparing/canceled where no image
  /// context exists yet (or anymore).
  bool _showsTaskHeader(ReverseImageFlowState state) => switch (state.status) {
    ReverseImageFlowStatus.ready ||
    ReverseImageFlowStatus.searching ||
    ReverseImageFlowStatus.failure ||
    ReverseImageFlowStatus.success => true,
    ReverseImageFlowStatus.idle ||
    ReverseImageFlowStatus.picking ||
    ReverseImageFlowStatus.preparing ||
    ReverseImageFlowStatus.canceled => false,
  };

  /// Engine switching is only meaningful while an image is still held —
  /// ready/failure/webUpload success. A released input (headless or
  /// WebView success) would only relabel the selection, so the chip turns
  /// inert exactly when the controller's switch is a no-op for this image.
  bool _engineSwitchable(ReverseImageFlowState state) =>
      state.input != null &&
      (state.status == ReverseImageFlowStatus.ready ||
          state.status == ReverseImageFlowStatus.failure ||
          state.status == ReverseImageFlowStatus.success);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reverseImageSearchControllerProvider(_session));
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.searchReverseImage),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: _cancelAndPop,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_showsTaskHeader(state))
              _TaskHeader(
                key: const ValueKey('reverseTaskHeader'),
                state: state,
                input: state.input ?? _lastInput,
                engineSwitchable: _engineSwitchable(state),
                onSelectEngine: _selectEngine,
              ),
            Expanded(child: _body(context, state)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ReverseImageFlowState state) {
    return switch (state.status) {
      ReverseImageFlowStatus.idle ||
      ReverseImageFlowStatus.canceled => _idle(context, state),
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
        state.webUpload != null
            ? _uploadWebView(context, state)
            : state.webView != null
            ? _resultWebView(context, state)
            : _results(context, state),
    };
  }

  Widget _resultWebView(BuildContext context, ReverseImageFlowState state) {
    final webView = state.webView!;
    final spec = ReverseImageEngineSpecs.all[state.engine]!;
    return ref.read(platformCapsProvider).isDesktop
        ? _ControlledSauceNaoInAppWebView(
            webView: webView,
            spec: spec,
            onOpenExternal: _openExternal,
          )
        : _ControlledSauceNaoWebView(
            webView: webView,
            spec: spec,
            onOpenExternal: _openExternal,
          );
  }

  /// Cloudflare-fronted engine: the upload page loads in InAppWebView on
  /// every platform — only its ChromeClient consumes the armed file chooser
  /// slot (webview_flutter's own client cannot see it).
  Widget _uploadWebView(BuildContext context, ReverseImageFlowState state) {
    final upload = state.webUpload!;
    return _UploadInAppWebView(
      upload: upload,
      policy: ReverseImageEngineSpecs.all[upload.engine]!.navigationPolicy,
      onOpenExternal: _openExternal,
    );
  }

  Widget _idle(BuildContext context, ReverseImageFlowState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 32),
          const Icon(Icons.image_search_outlined, size: 72),
          const SizedBox(height: 18),
          Text(context.l10n.searchReverseIntro, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          _engineChips(context, state),
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
            // Cancelling the in-flight step keeps the page open — leaving
            // is what the AppBar back button is for.
            OutlinedButton(
              onPressed: _controller.stopSearch,
              child: Text(context.l10n.searchReverseCancel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ready(BuildContext context, ReverseImageFlowState state) {
    final input = state.input!;
    final spec = ReverseImageEngineSpecs.all[state.engine]!;
    final supported = spec.supportsInput(input);
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
            child: _AdaptiveImagePreview(path: input.path),
          ),
          const SizedBox(height: 12),
          Text(
            '${input.width} × ${input.height} · ${_formatBytes(input.sizeBytes)}',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          // Reselect/cancel sit right under the preview — below the engine
          // chips and search button they fell off the first screen.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: _controller.pick,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text(context.l10n.searchReverseRetry),
              ),
              TextButton(
                onPressed: _controller.cancel,
                child: Text(context.l10n.searchReverseCancel),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _engineChips(context, state),
          if (!supported) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.searchReverseEngineUnsupported,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: supported ? _search : null,
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
    final engineName =
        ReverseImageEngineSpecs.all[state.engine]?.displayName ??
        state.engine.name;
    final message = failure.code == ReverseImageProviderFailureCode.challenge
        ? context.l10n.searchReverseChallenge(engineName)
        : failure.code == ReverseImageProviderFailureCode.providerUnavailable
        ? context.l10n.searchReverseUnavailableDetail
        : failure.code == ReverseImageProviderFailureCode.dailyLimit
        ? context.l10n.searchReverseDailyLimit
        : failure.code == ReverseImageProviderFailureCode.rateLimited &&
              seconds != null
        ? context.l10n.searchReverseRateLimitedWait(seconds)
        : failure.code == ReverseImageProviderFailureCode.rateLimited
        ? context.l10n.searchReverseRateLimited
        : failure.code == ReverseImageProviderFailureCode.unsupportedInput
        ? context.l10n.searchReverseEngineUnsupported
        : failure.message;
    final canRetry = state.input != null;
    return Center(
      child: SingleChildScrollView(
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
            if (canRetry) ...[
              const SizedBox(height: 16),
              _engineChips(context, state),
            ],
            const SizedBox(height: 20),
            if (canRetry)
              FilledButton.icon(
                onPressed: _search,
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.searchReverseRetrySameEngine),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
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

/// Persistent reverse-image task context: which image, which engine, which
/// phase. Rendered under the AppBar for every phase that carries an image,
/// including the WebView surfaces where the body otherwise looks like the
/// engine's own page. The header owns no flow state — the engine chip just
/// forwards to `selectEngine` and is inert outside the switchable phases.
class _TaskHeader extends StatelessWidget {
  const _TaskHeader({
    super.key,
    required this.state,
    required this.input,
    required this.engineSwitchable,
    required this.onSelectEngine,
  });

  final ReverseImageFlowState state;

  /// Thumbnail/info source — `state.input` while held, the last held input
  /// after a terminal release.
  final ReverseImageInputInfo? input;
  final bool engineSwitchable;
  final ValueChanged<ReverseImageEngine> onSelectEngine;

  String _phaseLabel(BuildContext context) {
    final l10n = context.l10n;
    return switch (state.status) {
      ReverseImageFlowStatus.ready => l10n.searchReverseReady,
      ReverseImageFlowStatus.searching => l10n.searchReverseSearching,
      ReverseImageFlowStatus.failure => l10n.searchReverseFailed,
      ReverseImageFlowStatus.success =>
        state.results.isNotEmpty
            ? l10n.searchReverseResultCount(state.results.length)
            : state.webView != null || state.webUpload != null
            ? l10n.searchReverseDone
            : l10n.searchReverseNoResults,
      ReverseImageFlowStatus.idle ||
      ReverseImageFlowStatus.picking ||
      ReverseImageFlowStatus.preparing ||
      ReverseImageFlowStatus.canceled => '',
    };
  }

  Widget _phaseIndicator(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    final Widget? icon = switch (state.status) {
      ReverseImageFlowStatus.searching => const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      ReverseImageFlowStatus.failure => Icon(
        Icons.error_outline,
        size: 16,
        color: Theme.of(context).colorScheme.error,
      ),
      ReverseImageFlowStatus.success => Icon(
        Icons.check_circle_outline,
        size: 16,
        color: Theme.of(context).colorScheme.primary,
      ),
      _ => null,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[icon, const SizedBox(width: 6)],
        Flexible(child: Text(_phaseLabel(context), style: style)),
      ],
    );
  }

  Widget _engineSelector(BuildContext context) {
    final spec = ReverseImageEngineSpecs.all[state.engine]!;
    final failed = state.engineFailures.containsKey(state.engine);
    final input = state.input;
    Widget chip({Widget? trailing}) => Chip(
      avatar: failed ? const Icon(Icons.error_outline, size: 16) : null,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(spec.displayName),
          if (trailing != null) ...[const SizedBox(width: 2), trailing],
        ],
      ),
    );
    if (!engineSwitchable) return chip();
    return PopupMenuButton<ReverseImageEngine>(
      tooltip: context.l10n.searchReverseEngineSwitch,
      onSelected: onSelectEngine,
      itemBuilder: (context) => [
        for (final engineSpec in ReverseImageEngineSpecs.all.values)
          PopupMenuItem(
            value: engineSpec.engine,
            enabled: input == null || engineSpec.supportsInput(input),
            child: Row(
              children: [
                if (state.engineFailures.containsKey(engineSpec.engine)) ...[
                  const Icon(Icons.error_outline, size: 18),
                  const SizedBox(width: 8),
                ],
                Expanded(child: Text(engineSpec.displayName)),
                if (engineSpec.engine == state.engine)
                  const Icon(Icons.check, size: 18),
              ],
            ),
          ),
      ],
      child: chip(trailing: const Icon(Icons.arrow_drop_down, size: 18)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final input = this.input;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 44,
                height: 44,
                child: input == null
                    ? Icon(Icons.image_outlined, color: scheme.onSurfaceVariant)
                    : Image.file(
                        File(input.path),
                        fit: BoxFit.cover,
                        // The 128px decode lands in the image cache while
                        // the file exists, so the thumbnail keeps working
                        // after a terminal success releases it.
                        cacheWidth: 128,
                        errorBuilder: (context, error, stackTrace) => Icon(
                          Icons.broken_image_outlined,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _phaseIndicator(context),
                  if (input != null)
                    Text(
                      '${input.width} × ${input.height} · '
                      '${_formatBytes(input.sizeBytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _engineSelector(context),
          ],
        ),
      ),
    );
  }
}

/// Preview that shapes its box to the image's DECODED aspect ratio.
///
/// `ReverseImageInputInfo.width/height` come from the raw file header —
/// JPEG SOF records the stored pixels and ignores EXIF orientation, so a
/// portrait photo kept as rotated landscape pixels produced a landscape
/// AspectRatio box with letterboxed bars. Listening to the image stream
/// yields the post-EXIF dimensions the engine and the user actually see.
class _AdaptiveImagePreview extends StatelessWidget {
  const _AdaptiveImagePreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    // Loose constraints: Image sizes itself to the decoded (EXIF-aware)
    // intrinsic dimensions, clamped only by the height bound — the frame
    // hugs the image with no letterboxing. The earlier probe-listener
    // approach raced the image cache (a synchronous hit left the fallback
    // 4:3 box forever) and decoded the file twice.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          cacheWidth: 1024,
          errorBuilder: (context, error, stackTrace) =>
              const Center(child: Icon(Icons.broken_image_outlined, size: 56)),
        ),
      ),
    );
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
    required this.spec,
    required this.onOpenExternal,
  });

  final ReverseImageSearchWebView webView;
  final ReverseImageEngineSpec spec;
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
        baseUrl:
            widget.spec.resultBaseUrl ??
            SauceNaoWebViewProvider.defaultEndpoint,
      );
    } else {
      _controller.loadRequest(result.resultUrl!);
    }
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    // Shared adapter around ReverseImageNavigationPolicy — see
    // [_applyNavigationAction]. Returns prevent when the link was consumed.
    return _applyNavigationAction(
          context,
          widget.spec.navigationPolicy.decide(Uri.tryParse(request.url)),
          request.url,
          widget.onOpenExternal,
        )
        ? NavigationDecision.prevent
        : NavigationDecision.navigate;
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

/// Shared adapter around [ReverseImageNavigationPolicy]: returns true when
/// the link was consumed (routed in-app, handed to the external launcher, or
/// rejected) and the webview must not navigate.
bool _applyNavigationAction(
  BuildContext context,
  ReverseImageNavigationAction action,
  String rawUrl,
  Future<void> Function(Uri uri) onOpenExternal,
) {
  switch (action) {
    case ReverseImageNavigationAction.navigate:
      return false;
    case ReverseImageNavigationAction.openIllust:
      final id = switch (IntentRouter.route(Uri.parse(rawUrl))) {
        IllustRoute(:final illustId) => illustId,
        _ => null,
      };
      if (id != null) {
        openIllust(context, id);
      } else {
        unawaited(onOpenExternal(Uri.parse(rawUrl)));
      }
      return true;
    case ReverseImageNavigationAction.openUser:
      final id = switch (IntentRouter.route(Uri.parse(rawUrl))) {
        UserRoute(:final userId) => userId,
        _ => null,
      };
      if (id != null) {
        openUser(context, id);
      } else {
        unawaited(onOpenExternal(Uri.parse(rawUrl)));
      }
      return true;
    case ReverseImageNavigationAction.openExternal:
      final uri = Uri.tryParse(rawUrl);
      if (uri != null) unawaited(onOpenExternal(uri));
      return true;
    case ReverseImageNavigationAction.reject:
      return true;
  }
}

/// InAppWebView (WebView2) variant of the result surface for desktop — same
/// navigation policy, progress and error contract as
/// [_ControlledSauceNaoWebView].
class _ControlledSauceNaoInAppWebView extends StatefulWidget {
  const _ControlledSauceNaoInAppWebView({
    required this.webView,
    required this.spec,
    required this.onOpenExternal,
  });

  final ReverseImageSearchWebView webView;
  final ReverseImageEngineSpec spec;
  final Future<void> Function(Uri uri) onOpenExternal;

  @override
  State<_ControlledSauceNaoInAppWebView> createState() =>
      _ControlledSauceNaoInAppWebViewState();
}

class _ControlledSauceNaoInAppWebViewState
    extends State<_ControlledSauceNaoInAppWebView> {
  String? _error;
  double? _progress;

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
    final result = widget.webView;
    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: result.resultUrl != null
              ? URLRequest(url: WebUri.uri(result.resultUrl!))
              : null,
          initialData: result.html != null
              ? InAppWebViewInitialData(
                  data: result.html!,
                  baseUrl: WebUri(
                    widget.spec.resultBaseUrl ??
                        SauceNaoWebViewProvider.defaultEndpoint,
                  ),
                )
              : null,
          // See LoginWebViewDesktopPage: the Windows plugin implements
          // useShouldOverrideUrlLoading via CDP Fetch.requestPaused, which
          // can strand mid-redirect document loads as CONNECTION_ABORTED.
          // NavigationStarting (onLoadStart) interception is enough here —
          // consumed links just get stopLoading().
          initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
          onLoadStart: (controller, url) {
            if (url == null) return;
            final raw = url.toString();
            if (_applyNavigationAction(
              context,
              widget.spec.navigationPolicy.decide(Uri.tryParse(raw)),
              raw,
              widget.onOpenExternal,
            )) {
              controller.stopLoading();
            }
          },
          onProgressChanged: (controller, progress) {
            if (mounted) setState(() => _progress = progress / 100.0);
          },
          onReceivedError: (controller, request, error) {
            if (request.isForMainFrame == false || !mounted) return;
            setState(() {
              _error =
                  '${context.l10n.searchReversePageLoadFailed} '
                  '(${error.type})';
            });
          },
        ),
        if (_progress != null && _progress! < 1.0)
          LinearProgressIndicator(value: _progress, minHeight: 2),
      ],
    );
  }
}

/// Engine upload page for Cloudflare-fronted engines (Ascii2D, TinEye). The
/// image was already armed to the next file chooser by the controller — the
/// site still needs the user's own tap on its upload control to open it.
/// On desktop ([ReverseImageSearchWebUpload.armedUri] == null) the chooser
/// cannot be intercepted, so the banner tells the user to pick the file in
/// the page's own picker.
class _UploadInAppWebView extends StatefulWidget {
  const _UploadInAppWebView({
    required this.upload,
    required this.policy,
    required this.onOpenExternal,
  });

  final ReverseImageSearchWebUpload upload;
  final ReverseImageNavigationPolicy policy;
  final Future<void> Function(Uri uri) onOpenExternal;

  @override
  State<_UploadInAppWebView> createState() => _UploadInAppWebViewState();
}

class _UploadInAppWebViewState extends State<_UploadInAppWebView> {
  String? _error;
  double? _progress;

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
    return Column(
      children: [
        MaterialBanner(
          leading: const Icon(Icons.upload_file_outlined),
          content: Text(
            widget.upload.armedUri == null
                ? context.l10n.searchReverseUploadPickHint
                : context.l10n.searchReverseUploadTapHint,
          ),
          actions: const [SizedBox.shrink()],
        ),
        Expanded(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri.uri(widget.upload.uploadPageUrl),
                ),
                initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
                onLoadStart: (controller, url) {
                  if (url == null) return;
                  final raw = url.toString();
                  if (_applyNavigationAction(
                    context,
                    widget.policy.decide(Uri.tryParse(raw)),
                    raw,
                    widget.onOpenExternal,
                  )) {
                    controller.stopLoading();
                  }
                },
                onProgressChanged: (controller, progress) {
                  if (mounted) setState(() => _progress = progress / 100.0);
                },
                onReceivedError: (controller, request, error) {
                  if (request.isForMainFrame == false || !mounted) return;
                  setState(() {
                    _error =
                        '${context.l10n.searchReversePageLoadFailed} '
                        '(${error.type})';
                  });
                },
              ),
              if (_progress != null && _progress! < 1.0)
                LinearProgressIndicator(value: _progress, minHeight: 2),
            ],
          ),
        ),
      ],
    );
  }
}

Map<ReverseImageEngine, ReverseImageProvider> _defaultProviders(
  http.Client client,
) {
  return {
    ReverseImageEngine.sauceNao: SauceNaoWebViewProvider(client: client),
    ReverseImageEngine.iqdb: IqdbWebViewProvider(client: client),
    ReverseImageEngine.ascii2d: WebViewUploadProvider(
      spec: ReverseImageEngineSpecs.ascii2d,
    ),
    ReverseImageEngine.tinEye: WebViewUploadProvider(
      spec: ReverseImageEngineSpecs.tinEye,
    ),
  };
}
