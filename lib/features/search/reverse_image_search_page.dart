import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/web_navigation_guard.dart';
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
import '../../app/widgets/settings/persist_settings.dart';
import '../../core/network/http_client_providers.dart';
import '../../l10n/context.dart';
import '../../app/motion/reveal.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_choice_chip.dart';
import '../../app/layout/content_widths.dart';

part 'reverse_image_search_widgets.dart';

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
    final isAndroid = ref.read(platformCapsProvider).isAndroid;
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
  /// is held, and the selection is persisted either way. A failed write is
  /// reported; this visit keeps the choice.
  void _selectEngine(ReverseImageEngine engine) {
    unawaited(_controller.selectEngine(engine));
    unawaited(
      persistSettings(
        context,
        () => ref
            .read(settingsProvider.notifier)
            .selectReverseImageEngine(engine),
      ),
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
    final web =
        state.status == ReverseImageFlowStatus.success &&
        (state.webUpload != null || state.webView != null);
    final body = _state(context, state);
    // The engine pages own the width; the flow's own states read as a form.
    return web
        ? body
        : ContentWidthCap(maxWidth: ContentWidths.form, child: body);
  }

  Widget _state(BuildContext context, ReverseImageFlowState state) {
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
    return _ControlledSauceNaoWebView(
      caps: ref.read(platformCapsProvider),
      webView: webView,
      spec: spec,
      onOpenExternal: _openExternal,
    );
  }

  /// Cloudflare-fronted engine: the upload page loads in InAppWebView on
  /// every platform — its ChromeClient consumes the armed file chooser
  /// slot.
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
          child: action,
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
