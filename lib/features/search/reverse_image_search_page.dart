import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/widgets/app_top_bar.dart';
import '../../core/format/byte_size.dart';
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
import '../../core/errors/error_category.dart';
import '../../core/settings/settings_controller.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/errors/error_details.dart';
import 'package:parfait/core/network/http_client_providers.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_choice_chip.dart';

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
          AppChoiceChip(
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
                : () => _selectEngine(spec.engine),
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

  /// The header's engine menu is the one engine picker while an image is
  /// held; it turns inert mid-step, where the controller ignores a switch.
  bool _engineSwitchable(ReverseImageFlowState state) =>
      state.input != null &&
      (state.status == ReverseImageFlowStatus.ready ||
          state.status == ReverseImageFlowStatus.failure ||
          state.status == ReverseImageFlowStatus.success);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reverseImageSearchControllerProvider(_session));
    return Scaffold(
      appBar: AppTopBar(
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
                input: state.input,
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
            : _noMatch(context, state),
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
    return _WithBottomAction(
      action: FilledButton.icon(
        onPressed: _controller.pick,
        icon: const Icon(Icons.photo_library_outlined),
        label: Text(context.l10n.searchReversePick),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          children: [
            const SizedBox(height: FuncSpacing.xxl),
            const Icon(Icons.image_search_outlined, size: 72),
            const SizedBox(height: FuncSpacing.lg),
            Text(context.l10n.searchReverseIntro, textAlign: TextAlign.center),
            const SizedBox(height: FuncSpacing.lg),
            _engineChips(context, state),
          ],
        ),
      ),
    );
  }

  Widget _progress(BuildContext context, String label) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: FuncSpacing.lg),
            Text(label),
            const SizedBox(height: FuncSpacing.lg),
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

  /// The image and a way to pick another; its size and the engine are in
  /// the header, and the search sits fixed at the bottom.
  Widget _ready(BuildContext context, ReverseImageFlowState state) {
    final input = state.input!;
    final supported = ReverseImageEngineSpecs.all[state.engine]!.supportsInput(
      input,
    );
    return _WithBottomAction(
      action: FilledButton.icon(
        onPressed: supported ? _search : null,
        icon: const Icon(Icons.search),
        label: Text(context.l10n.searchReverseUse),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              clipBehavior: Clip.antiAlias,
              child: _AdaptiveImagePreview(path: input.path),
            ),
            // Size and engine are in the header above.
            const SizedBox(height: FuncSpacing.sm),
            Center(
              child: TextButton.icon(
                onPressed: _controller.pick,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text(context.l10n.searchReverseRetry),
              ),
            ),
            if (!supported)
              Text(
                context.l10n.searchReverseEngineUnsupported,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }

  Widget _failure(BuildContext context, ReverseImageFlowState state) {
    final failure = state.failure!;
    final held = state.input != null;
    final challenged =
        held && failure.code == ReverseImageProviderFailureCode.challenge;
    final next = state.nextEngine;
    return _Outcome(
      icon: Icons.error_outline,
      message: _failureText(context, failure, state.engine),
      primary: challenged
          ? FilledButton.icon(
              onPressed: _controller.searchInBrowser,
              icon: const Icon(Icons.open_in_browser),
              label: Text(context.l10n.searchReverseOpenInBrowser),
            )
          : held
          ? FilledButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.searchReverseRetrySameEngine),
            )
          : FilledButton.icon(
              onPressed: _controller.pick,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(context.l10n.searchReverseRetry),
            ),
      secondary: [
        if (next != null)
          OutlinedButton(
            onPressed: _controller.searchNextEngine,
            child: Text(context.l10n.searchReverseTryEngine(_nameOf(next))),
          ),
        if (held)
          TextButton(
            onPressed: _controller.pick,
            child: Text(context.l10n.searchReverseRetry),
          ),
      ],
    );
  }

  /// The engine found nothing for this image: the one way on is the next
  /// engine that has not had its turn, or another image once all have.
  Widget _noMatch(BuildContext context, ReverseImageFlowState state) {
    final next = state.nextEngine;
    return _Outcome(
      icon: Icons.search_off,
      message: next == null
          ? context.l10n.searchReverseAllEnginesTried
          : context.l10n.searchReverseNoResults,
      primary: next == null
          ? FilledButton.icon(
              onPressed: _controller.pick,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(context.l10n.searchReverseRetry),
            )
          : FilledButton(
              onPressed: _controller.searchNextEngine,
              child: Text(context.l10n.searchReverseTryEngine(_nameOf(next))),
            ),
    );
  }

  static String _nameOf(ReverseImageEngine engine) =>
      ReverseImageEngineSpecs.all[engine]!.displayName;

  Future<void> _openExternal(Uri uri) async {
    try {
      await _externalLauncher.open(uri);
    } on Object {
      if (!mounted) return;
      showAppSnackBar(context, context.l10n.searchReverseOpenFailed);
    }
  }
}

/// What went wrong, in the user's language, for every failure the flow can
/// end in — input, platform and engine alike.
String _failureText(
  BuildContext context,
  ReverseImageFlowFailure failure,
  ReverseImageEngine engine,
) {
  final l10n = context.l10n;
  final name = ReverseImageEngineSpecs.all[engine]!.displayName;
  return switch (failure.code) {
    final ReverseImageProviderFailureCode code => switch (code) {
      ReverseImageProviderFailureCode.challenge => l10n.searchReverseChallenge(
        name,
      ),
      ReverseImageProviderFailureCode.providerUnavailable =>
        l10n.searchReverseEngineUnavailable(name),
      ReverseImageProviderFailureCode.dailyLimit =>
        l10n.searchReverseDailyLimit,
      ReverseImageProviderFailureCode.rateLimited =>
        switch (failure.retryAfter?.inSeconds) {
          final seconds? => l10n.searchReverseRateLimitedWait(seconds),
          null => l10n.searchReverseRateLimited,
        },
      ReverseImageProviderFailureCode.unsupportedInput =>
        l10n.searchReverseEngineUnsupported,
      ReverseImageProviderFailureCode.network => l10n.searchReverseNetwork,
      ReverseImageProviderFailureCode.malformedResponse =>
        l10n.searchReverseBadResponse(name),
      ReverseImageProviderFailureCode.cancelled => l10n.searchReverseStopped,
    },
    final ReverseImageInputFailureCode code => switch (code) {
      ReverseImageInputFailureCode.invalidMimeType ||
      ReverseImageInputFailureCode.unsupportedFormat ||
      ReverseImageInputFailureCode.malformedFormat ||
      ReverseImageInputFailureCode.mimeMismatch =>
        l10n.searchReverseImageFormat,
      ReverseImageInputFailureCode.oversized ||
      ReverseImageInputFailureCode.dimensionsTooLarge ||
      ReverseImageInputFailureCode.pixelBudgetExceeded =>
        l10n.searchReverseImageTooLarge,
      ReverseImageInputFailureCode.missingReadPermission =>
        l10n.searchReverseImagePermission,
      ReverseImageInputFailureCode.cleanupFailed =>
        l10n.searchReverseCleanupFailed,
      ReverseImageInputFailureCode.invalidReference ||
      ReverseImageInputFailureCode.empty ||
      ReverseImageInputFailureCode.unreadable ||
      ReverseImageInputFailureCode.closed => l10n.searchReverseImageUnreadable,
    },
    final ReverseImagePlatformFailureCode code => switch (code) {
      ReverseImagePlatformFailureCode.unavailable =>
        l10n.searchReversePickerUnavailable,
      ReverseImagePlatformFailureCode.permissionDenied =>
        l10n.searchReverseImagePermission,
      ReverseImagePlatformFailureCode.cleanupFailed =>
        l10n.searchReverseCleanupFailed,
      ReverseImagePlatformFailureCode.pickerFailed ||
      ReverseImagePlatformFailureCode.malformedResponse ||
      ReverseImagePlatformFailureCode.copyFailed =>
        l10n.searchReverseImageUnreadable,
    },
    _ => l10n.searchReverseFailed,
  };
}

/// A step's body above its one action, fixed at the bottom with the
/// privacy note in a line above it.
class _WithBottomAction extends StatelessWidget {
  const _WithBottomAction({required this.action, required this.child});

  final Widget action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      children: [
        Expanded(child: child),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.xl,
            FuncSpacing.sm,
            FuncSpacing.xl,
            FuncSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.privacy_tip_outlined, size: 16, color: muted),
                  const SizedBox(width: FuncSpacing.xs),
                  Expanded(
                    child: Text(
                      context.l10n.searchReversePrivacyNote,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: FuncSpacing.sm),
              action,
            ],
          ),
        ),
      ],
    );
  }
}

/// How a search ended when there is no page to show: what happened, the
/// one thing to do next, and quieter alternatives under it.
class _Outcome extends StatelessWidget {
  const _Outcome({
    required this.icon,
    required this.message,
    required this.primary,
    this.secondary = const [],
  });

  final IconData icon;
  final String message;
  final Widget primary;
  final List<Widget> secondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56),
            const SizedBox(height: FuncSpacing.lg),
            Semantics(
              liveRegion: true,
              child: Text(message, textAlign: TextAlign.center),
            ),
            const SizedBox(height: FuncSpacing.lg),
            primary,
            for (final action in secondary) ...[
              const SizedBox(height: FuncSpacing.sm),
              action,
            ],
          ],
        ),
      ),
    );
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
                    '${error.errorType} '
                    '[${error.errorCode}]: ${error.description}';
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
    final error = _error;
    if (error != null) {
      return _webViewErrorBody(context, error);
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
    final error = _error;
    if (error != null) {
      return _webViewErrorBody(context, error);
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
    final error = _error;
    if (error != null) {
      return _webViewErrorBody(context, error);
    }
    return Column(
      children: [
        if (_showUploadHint)
          MaterialBanner(
            leading: const Icon(Icons.upload_file_outlined),
            content: Text(
              widget.upload.armedUri == null
                  ? context.l10n.searchReverseUploadPickHint
                  : context.l10n.searchReverseUploadTapHint,
            ),
            actions: [
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => setState(() => _showUploadHint = false),
                icon: const Icon(Icons.close),
              ),
            ],
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

/// The three embedded WebViews share one failure surface: a localized
/// headline, the network category (a main-frame error is always a
/// connectivity failure), and the engine-reported detail behind the
/// disclosure.
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
              ErrorDetails(error: error),
            ],
          ),
        ),
      ],
    ),
  );
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
