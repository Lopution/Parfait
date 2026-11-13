part of 'reverse_image_search_page.dart';

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
        state.webView != null || state.webUpload != null
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
        if (icon != null) ...[icon, const SizedBox(width: FuncSpacing.xs)],
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
          if (trailing != null) ...[
            const SizedBox(width: FuncSpacing.xxs),
            trailing,
          ],
        ],
      ),
    );
    if (!engineSwitchable) return chip();
    return AppMenuButton<ReverseImageEngine>(
      onSelected: (_, engine) => onSelectEngine(engine),
      entries: [
        for (final engineSpec in ReverseImageEngineSpecs.all.values)
          AppMenuEntry(
            value: engineSpec.engine,
            label: engineSpec.displayName,
            icon: state.engineFailures.containsKey(engineSpec.engine)
                ? Icons.error_outline
                : null,
            enabled: input == null || engineSpec.supportsInput(input),
            checked: engineSpec.engine == state.engine,
          ),
      ],
      anchorBuilder: (context, toggle) => Tooltip(
        message: context.l10n.searchReverseEngineSwitch,
        child: InkWell(
          onTap: toggle,
          customBorder: const StadiumBorder(),
          child: chip(trailing: const Icon(Icons.arrow_drop_down, size: 18)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final input = this.input;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.lg,
          vertical: FuncSpacing.sm,
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: FuncShape.control,
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
            const SizedBox(width: FuncSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _phaseIndicator(context),
                  if (input != null)
                    Text(
                      '${input.width} × ${input.height} · '
                      '${formatByteSize(input.sizeBytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: FuncSpacing.sm),
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
        unawaited(openIllust(context, id));
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
        unawaited(openUser(context, id));
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

/// Controlled SauceNAO result WebView (D1): navigates freely inside
/// saucenao.com, routes Pixiv links into the app (detail / user pages),
/// sends every other HTTPS link to the external launcher and rejects
/// non-HTTPS navigation. Errors stay visible; the WebView never renders
/// into an empty-looking success.
class _ControlledSauceNaoWebView extends StatefulWidget {
  const _ControlledSauceNaoWebView({
    required this.caps,
    required this.webView,
    required this.spec,
    required this.onOpenExternal,
  });

  final PlatformCaps caps;
  final ReverseImageSearchWebView webView;
  final ReverseImageEngineSpec spec;
  final Future<void> Function(Uri uri) onOpenExternal;

  @override
  State<_ControlledSauceNaoWebView> createState() =>
      _ControlledSauceNaoWebViewState();
}

class _ControlledSauceNaoWebViewState
    extends State<_ControlledSauceNaoWebView> {
  late final _guard = WebNavigationGuard(
    widget.caps,
    (raw) => _applyNavigationAction(
      context,
      widget.spec.navigationPolicy.decide(Uri.tryParse(raw)),
      raw,
      widget.onOpenExternal,
    ),
  );
  String? _error;
  double? _progress;

  @override
  Widget build(BuildContext context) {
    final result = widget.webView;
    if (!widget.caps.supportsInAppWebView) {
      final externalUri =
          result.resultUrl ??
          Uri.parse(
            widget.spec.resultBaseUrl ??
                SauceNaoWebViewProvider.defaultEndpoint,
          );
      return _ExternalWebFallback(
        message: context.l10n.searchReverseDone,
        buttonLabel: context.l10n.openInBrowser,
        onOpen: () => widget.onOpenExternal(externalUri),
      );
    }
    final error = _error;
    if (error != null) {
      return _webViewErrorBody(context, error);
    }
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
          initialSettings: _guard.settings,
          shouldOverrideUrlLoading: _guard.shouldOverrideUrlLoading,
          onLoadStart: _guard.onLoadStart,
          onProgressChanged: (controller, progress) {
            if (mounted) setState(() => _progress = progress / 100.0);
          },
          onReceivedError: (controller, request, error) {
            if (request.isForMainFrame == false || !mounted) return;
            setState(() {
              _error = '${error.type}: ${error.description}';
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
    required this.caps,
    required this.upload,
    required this.policy,
    required this.onOpenExternal,
  });

  final PlatformCaps caps;
  final ReverseImageSearchWebUpload upload;
  final ReverseImageNavigationPolicy policy;
  final Future<void> Function(Uri uri) onOpenExternal;

  @override
  State<_UploadInAppWebView> createState() => _UploadInAppWebViewState();
}

class _UploadInAppWebViewState extends State<_UploadInAppWebView> {
  String? _error;
  double? _progress;
  bool _showUploadHint = true;

  @override
  void didUpdateWidget(covariant _UploadInAppWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.upload.uploadPageUrl != widget.upload.uploadPageUrl ||
        oldWidget.upload.imagePath != widget.upload.imagePath) {
      _showUploadHint = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.caps.supportsInAppWebView) {
      return _ExternalWebFallback(
        message: context.l10n.searchReverseUploadPickHint,
        buttonLabel: context.l10n.searchReverseOpenInBrowser,
        onOpen: () => widget.onOpenExternal(widget.upload.uploadPageUrl),
      );
    }
    final error = _error;
    if (error != null) {
      return _webViewErrorBody(context, error);
    }
    return Column(
      children: [
        Reveal(
          child: !_showUploadHint
              ? null
              : MaterialBanner(
                  leading: const Icon(Icons.upload_file_outlined),
                  content: Text(
                    widget.upload.armedUri == null
                        ? context.l10n.searchReverseUploadPickHint
                        : context.l10n.searchReverseUploadTapHint,
                  ),
                  actions: [
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => setState(() => _showUploadHint = false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
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
                    unawaited(controller.stopLoading());
                  }
                },
                onProgressChanged: (controller, progress) {
                  if (mounted) setState(() => _progress = progress / 100.0);
                },
                onReceivedError: (controller, request, error) {
                  if (request.isForMainFrame == false || !mounted) return;
                  setState(() {
                    _error = '${error.type}: ${error.description}';
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

/// Fallback body shown when the platform has no embedded WebView (Linux),
/// directing the user to complete or view the engine step in the system browser.
class _ExternalWebFallback extends StatelessWidget {
  const _ExternalWebFallback({
    required this.message,
    required this.buttonLabel,
    required this.onOpen,
  });

  final String message;
  final String buttonLabel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.open_in_browser_outlined, size: 56),
            const SizedBox(height: FuncSpacing.md),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: FuncSpacing.lg),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_browser_outlined),
              label: Text(buttonLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// The three embedded WebViews share one failure surface: a localized
/// headline, the network category (a main-frame error is always a
/// connectivity failure); the engine-reported detail goes to the crash
/// log.
Widget _webViewErrorBody(BuildContext context, String error) {
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 56),
        const SizedBox(height: FuncSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.searchReversePageLoadFailed,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: FuncSpacing.sm),
              Text(
                errorCategoryText(context, ErrorCategory.network),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              FailureReport(
                action: context.l10n.searchReversePageLoadFailed,
                error: error,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
