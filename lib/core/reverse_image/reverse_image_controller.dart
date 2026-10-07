/// Reverse-image input ownership, provider capability, and search flow state.
/// [ReverseImageSearchController] owns the temporary input lifecycle while
/// providers own their result protocol. See `frontend/state-management.md`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/foundation.dart';

import '../network/pixiv_http_client.dart';
import 'image_downscale.dart';
import 'image_input.dart';
import 'reverse_image_engine.dart';
import 'reverse_image_platform.dart';
import 'reverse_image_provider.dart';
import 'webview_upload_provider.dart';

enum ReverseImageFlowStatus {
  idle,
  picking,
  preparing,
  ready,
  searching,
  success,
  failure,
  canceled,
}

@immutable
class ReverseImageFlowFailure {
  const ReverseImageFlowFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.retryAfter,
  });

  final Object code;
  final String message;
  final bool retryable;
  final Duration? retryAfter;
}

@immutable
class ReverseImageFlowState {
  const ReverseImageFlowState({
    required this.status,
    required this.engine,
    this.input,
    this.webView,
    this.webUpload,
    this.failure,
    this.engineFailures = const {},
    this.noMatchEngines = const {},
  });

  const ReverseImageFlowState.idle([this.engine = ReverseImageEngine.sauceNao])
    : status = ReverseImageFlowStatus.idle,
      input = null,
      webView = null,
      webUpload = null,
      failure = null,
      engineFailures = const {},
      noMatchEngines = const {};

  final ReverseImageFlowStatus status;

  /// Currently selected engine. The failure/webUpload below always belongs
  /// to this engine.
  final ReverseImageEngine engine;
  final ReverseImageInputInfo? input;

  /// SauceNAO-style service-rendered result page (D1). Only set on success.
  final ReverseImageSearchWebView? webView;

  /// Cloudflare-fronted engine upload page (Ascii2D, TinEye). Only set on
  /// success; the input file stays owned until the flow ends.
  final ReverseImageSearchWebUpload? webUpload;
  final ReverseImageFlowFailure? failure;

  /// Per-engine failure memory for the current image: chips render the
  /// failed engines so switching away (and back) stays explicit. Cleared on
  /// every new input.
  final Map<ReverseImageEngine, ReverseImageFlowFailure> engineFailures;

  /// Engines that found nothing for the current image. Cleared with
  /// [engineFailures] on every new input.
  final Set<ReverseImageEngine> noMatchEngines;

  /// The engine a "try another engine" action runs next: the first one
  /// after [engine], in order, that takes the held image and has neither
  /// failed nor come back empty for it. Null without an image or when every
  /// engine has had its turn.
  ReverseImageEngine? get nextEngine {
    final input = this.input;
    if (input == null) return null;
    const engines = ReverseImageEngine.values;
    final start = engines.indexOf(engine);
    for (var step = 1; step < engines.length; step++) {
      final candidate = engines[(start + step) % engines.length];
      if (engineFailures.containsKey(candidate) ||
          noMatchEngines.contains(candidate)) {
        continue;
      }
      if (ReverseImageEngineSpecs.all[candidate]!.supportsInput(input)) {
        return candidate;
      }
    }
    return null;
  }
}

/// Coordinates picker/SEND preparation and provider execution. The controller
/// owns one temporary file and releases it on every terminal path.
/// Per-session dependencies of the reverse-image flow (C7a).
class ReverseImageSearchSession {
  ReverseImageSearchSession({
    required this.platform,
    required Map<ReverseImageEngine, ReverseImageProvider> providers,
    this.initialEngine = ReverseImageEngine.sauceNao,
    this.uploadArmer = const NoopReverseImageUploadArmer(),
  }) : providers = Map.unmodifiable(providers);

  /// Single-engine convenience for tests and embeds that only carry one
  /// provider.
  ReverseImageSearchSession.single({
    required this.platform,
    required ReverseImageProvider provider,
    this.initialEngine = ReverseImageEngine.sauceNao,
    this.uploadArmer = const NoopReverseImageUploadArmer(),
  }) : providers = Map.unmodifiable({initialEngine: provider});

  final ReverseImageInputPlatform platform;
  final Map<ReverseImageEngine, ReverseImageProvider> providers;
  final ReverseImageEngine initialEngine;

  /// Arms an owned input file to the next WebView file chooser. The noop
  /// fallback is the desktop degrade where the page's native picker opens
  /// and the user re-picks the file.
  final ReverseImageUploadArmer uploadArmer;

  /// Missing engines are an explicit unavailable provider — never a silent
  /// fallback to another engine.
  ReverseImageProvider providerFor(ReverseImageEngine engine) =>
      providers[engine] ??
      UnavailableReverseImageProvider(
        name: '${engine.name}-provider',
        reason: 'reverse image engine is not configured',
      );
}

/// Riverpod handle for the reverse-image flow.
final reverseImageSearchControllerProvider = NotifierProvider.autoDispose
    .family<
      ReverseImageSearchController,
      ReverseImageFlowState,
      ReverseImageSearchSession
    >(ReverseImageSearchController.new);

class ReverseImageSearchController extends Notifier<ReverseImageFlowState> {
  ReverseImageSearchController(this.session);

  final ReverseImageSearchSession session;

  ReverseImageInputPlatform get platform => session.platform;
  ReverseImageProvider get provider => session.providerFor(state.engine);

  OwnedReverseImageInput? _input;
  CancelToken? _cancelToken;
  int _generation = 0;
  bool _closed = false;

  ReverseImageProviderCapability get capability => provider.capability;

  @override
  ReverseImageFlowState build() {
    ref.onDispose(() {
      unawaited(close());
    });
    return ReverseImageFlowState.idle(session.initialEngine);
  }

  Future<void> pick() async {
    if (_closed) return;
    // Bump the generation so a stop while the picker is open makes the
    // late reference die here instead of flowing into prepare().
    final generation = ++_generation;
    _cancelToken?.cancel();
    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.picking,
        engine: state.engine,
      ),
    );
    try {
      final reference = await platform.pickImage();
      if (_closed || generation != _generation) return;
      if (reference == null) {
        _setState(const ReverseImageFlowState.idle());
        return;
      }
      await prepare(reference);
    } on Object catch (error) {
      if (!_closed && generation == _generation) {
        _setFailure(_flowFailure(error));
      }
    }
  }

  Future<void> prepare(ReverseImageInputReference reference) async {
    if (_closed) return;
    final generation = ++_generation;
    _cancelToken?.cancel();
    try {
      await _releaseInput();
      _validateReference(reference);
    } on Object catch (error) {
      if (!_closed && generation == _generation) {
        _setFailure(_flowFailure(error));
      }
      return;
    }

    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.preparing,
        engine: state.engine,
      ),
    );
    String? path;
    try {
      path = await platform.copyToOwnedFile(reference);
      if (_closed || generation != _generation) {
        await platform.deleteOwnedFile(path);
        return;
      }
      var input = await OwnedReverseImageInput.open(
        path: path,
        source: reference.source,
        mimeType: reference.mimeType,
        delete: platform.deleteOwnedFile,
      );
      if (ReverseImageDownscale.needed(input.info)) {
        input = await _downscaled(input);
      }
      if (_closed || generation != _generation) {
        await input.dispose();
        return;
      }
      _input = input;
      _setState(
        ReverseImageFlowState(
          status: ReverseImageFlowStatus.ready,
          engine: state.engine,
          input: input.info,
        ),
      );
    } on Object catch (error) {
      // OwnedReverseImageInput cleans a copied path after validation failures.
      // If copying failed before ownership was established, there is nothing
      // safe to delete because no path was returned to us.
      if (path != null &&
          _input == null &&
          error is! ReverseImageInputException) {
        // The platform owns the path only after this method returns it. A
        // provider/transport failure cannot reach this branch, but cleanup is
        // still explicit for a stale operation.
        try {
          await platform.deleteOwnedFile(path);
        } on Object {
          _setFailure(
            const ReverseImageFlowFailure(
              code: ReverseImageInputFailureCode.cleanupFailed,
              message: 'temporary image cleanup failed',
            ),
          );
          return;
        }
      }
      if (!_closed && generation == _generation) {
        _setFailure(_flowFailure(error));
      }
    }
  }

  /// Replaces [input] with a copy scaled to [ReverseImageDownscale]'s long
  /// edge, next to it in the owned directory. The original is released
  /// either way; a copy that cannot be made fails the preparation.
  Future<OwnedReverseImageInput> _downscaled(
    OwnedReverseImageInput input,
  ) async {
    final target = '${input.info.path}.scaled.jpg';
    try {
      await ReverseImageDownscale.toJpeg(
        source: input.info.path,
        target: target,
      );
    } on Object {
      await input.dispose();
      try {
        await platform.deleteOwnedFile(target);
      } on Object {
        // Nothing may have been written; the original is already gone.
      }
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.unreadable,
        'image could not be scaled',
      );
    }
    await input.dispose();
    return OwnedReverseImageInput.open(
      path: target,
      source: input.info.source,
      mimeType: 'image/jpeg',
      delete: platform.deleteOwnedFile,
    );
  }

  /// Switches the selected engine. With no held image only the selection
  /// moves (the UI persists it); with a held image a ready, failure or
  /// success state returns to ready so the new engine can be searched.
  Future<void> selectEngine(ReverseImageEngine engine) async {
    if (_closed || engine == state.engine) return;
    final input = _input;
    if (input == null) {
      _setState(ReverseImageFlowState(status: state.status, engine: engine));
      return;
    }
    switch (state.status) {
      case ReverseImageFlowStatus.ready:
      case ReverseImageFlowStatus.failure:
      case ReverseImageFlowStatus.success:
        break;
      case ReverseImageFlowStatus.idle:
      case ReverseImageFlowStatus.picking:
      case ReverseImageFlowStatus.preparing:
      case ReverseImageFlowStatus.searching:
      case ReverseImageFlowStatus.canceled:
        return;
    }
    // Leaving a webUpload result drops the armed slot. A missed disarm is
    // self-healing (the next arm overwrites the one-shot slot), so the
    // platform error does not block the switch.
    await _disarm();
    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.ready,
        engine: engine,
        input: input.info,
        engineFailures: state.engineFailures,
        noMatchEngines: state.noMatchEngines,
      ),
    );
  }

  /// Switches to [ReverseImageFlowState.nextEngine] and searches with it.
  Future<void> searchNextEngine() async {
    final next = state.nextEngine;
    if (_closed || next == null) return;
    await selectEngine(next);
    await search();
  }

  /// The challenge way out: opens the current engine's own upload form in
  /// the controlled WebView with the held image armed to its file chooser,
  /// so the user passes the check in a real browser context.
  Future<void> searchInBrowser() async {
    if (_closed || _input == null) return;
    if (state.status != ReverseImageFlowStatus.failure) return;
    await _run(
      WebViewUploadProvider(spec: ReverseImageEngineSpecs.all[state.engine]!),
    );
  }

  Future<void> search() async {
    if (_closed || _input == null) return;
    // Failure keeps the owned input, so searching again from the failure
    // state is an explicit same-engine retry.
    if (state.status != ReverseImageFlowStatus.ready &&
        state.status != ReverseImageFlowStatus.failure) {
      return;
    }
    await _run(provider);
  }

  /// Runs [provider] on the held image. The image stays held whatever the
  /// outcome — until a new pick, cancel or leaving the page — so another
  /// engine can always be tried on it.
  Future<void> _run(ReverseImageProvider provider) async {
    final generation = _generation;
    final input = _input!;
    final engine = state.engine;
    final engineFailures = Map.of(state.engineFailures);
    final noMatchEngines = state.noMatchEngines;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.searching,
        engine: engine,
        input: input.info,
        engineFailures: engineFailures,
        noMatchEngines: noMatchEngines,
      ),
    );

    ReverseImageSearchOutcome? outcome;
    Object? error;
    try {
      outcome = await provider.search(input, cancelToken: cancelToken);
    } on Object catch (caught) {
      error = caught;
    }

    // A web-upload outcome needs the owned file in the browser's file
    // chooser; arming happens here so a platform failure becomes a visible
    // engine failure instead of a webview that uploads nothing.
    String? armedUri;
    if (outcome is ReverseImageSearchWebUpload && error == null) {
      try {
        armedUri = await session.uploadArmer.armUpload(input.info.path);
      } on Object catch (caught) {
        error = caught;
        outcome = null;
      }
    }

    // A stale generation must not touch a flow stopSearch()/prepare()
    // already moved on from.
    if (_closed || generation != _generation) return;
    if (_cancelToken == cancelToken) _cancelToken = null;
    final caught = error;
    if (caught != null) {
      _failSearch(engine, _flowFailure(caught), engineFailures);
      return;
    }
    ReverseImageFlowState success({
      ReverseImageSearchWebView? webView,
      ReverseImageSearchWebUpload? webUpload,
      Set<ReverseImageEngine>? noMatch,
    }) => ReverseImageFlowState(
      status: ReverseImageFlowStatus.success,
      engine: engine,
      input: input.info,
      webView: webView,
      webUpload: webUpload,
      engineFailures: engineFailures,
      noMatchEngines: noMatch ?? noMatchEngines,
    );
    switch (outcome) {
      case ReverseImageSearchSuccess():
        // A provider-detected "no match" page: terminal success with no
        // payload — the page shows the empty state.
        _setState(
          success(noMatch: Set.unmodifiable({...noMatchEngines, engine})),
        );
      case ReverseImageSearchWebView(:final html, :final resultUrl):
        _setState(
          success(
            webView: ReverseImageSearchWebView(
              html: html,
              resultUrl: resultUrl,
              observedAt: _nowIso(),
            ),
          ),
        );
      case ReverseImageSearchWebUpload(:final uploadPageUrl):
        _setState(
          success(
            webUpload: ReverseImageSearchWebUpload(
              engine: engine,
              uploadPageUrl: uploadPageUrl,
              imagePath: input.info.path,
              imageMimeType: input.info.mimeType,
              observedAt: _nowIso(),
              armedUri: armedUri,
            ),
          ),
        );
      case ReverseImageSearchFailure(
        :final code,
        :final message,
        :final retryable,
        :final retryAfter,
      ):
        _failSearch(
          engine,
          ReverseImageFlowFailure(
            code: code,
            message: message,
            retryable: retryable,
            retryAfter: retryAfter,
          ),
          engineFailures,
        );
      case null:
        _failSearch(
          engine,
          const ReverseImageFlowFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'reverse image provider returned no result',
          ),
          engineFailures,
        );
    }
  }

  /// Stops the in-flight step without leaving the page: a held image drops
  /// back to ready so the user can retry or switch engines, and an empty
  /// flow returns to idle. Unlike [cancel] the owned input is kept.
  Future<void> stopSearch() async {
    if (_closed) return;
    ++_generation;
    _cancelToken?.cancel();
    _cancelToken = null;
    final input = _input;
    _setState(
      ReverseImageFlowState(
        status: input == null
            ? ReverseImageFlowStatus.idle
            : ReverseImageFlowStatus.ready,
        engine: state.engine,
        input: input?.info,
        engineFailures: state.engineFailures,
        noMatchEngines: state.noMatchEngines,
      ),
    );
  }

  Future<void> cancel() async {
    if (_closed) return;
    ++_generation;
    _cancelToken?.cancel();
    Object? cleanupError;
    try {
      await _releaseInput();
    } on Object catch (error) {
      cleanupError = error;
    }
    if (_closed) return;
    final cleanup = cleanupError;
    if (cleanup != null) {
      _setFailure(_flowFailure(cleanup));
    } else {
      _setState(
        ReverseImageFlowState(
          status: ReverseImageFlowStatus.canceled,
          engine: state.engine,
        ),
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _cancelToken?.cancel();
    await _releaseInput();
  }

  void _validateReference(ReverseImageInputReference reference) {
    final uri = Uri.tryParse(reference.contentUri);
    if (uri == null ||
        uri.scheme != 'content' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.fragment.isNotEmpty) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.invalidReference,
        'selected image reference is invalid',
      );
    }
    if (!reference.hasReadUriPermission) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.missingReadPermission,
        'selected image permission is no longer available',
      );
    }
    final mime = reference.mimeType.trim().toLowerCase();
    if (!ReverseImageInputValidator.isSupportedMime(mime)) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.invalidMimeType,
        'image MIME type is not supported',
      );
    }
    if (reference.sizeBytes <= 0) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.empty,
        'selected image is empty',
      );
    }
    if (reference.sizeBytes > ReverseImageInputLimits.maxEncodedBytes) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.oversized,
        'selected image exceeds the size limit',
      );
    }
  }

  Future<void> _releaseInput() async {
    final input = _input;
    _input = null;
    // Drop a possibly-armed chooser URI before the file behind it goes away.
    await _disarm();
    if (input != null) await input.dispose();
  }

  /// Best-effort chooser-slot hygiene: the platform slot is one-shot and the
  /// next arm overwrites it, so a disarm failure never blocks cleanup.
  Future<void> _disarm() async {
    try {
      await session.uploadArmer.disarmUpload();
    } on Object {
      // Self-healing: the armed slot is consumed on first use and replaced
      // by the next arm; leaving it stale is bounded to the page lifetime.
    }
  }

  ReverseImageFlowFailure _flowFailure(Object error) {
    if (error is ReverseImageFlowFailure) return error;
    if (error is ReverseImageInputException) {
      return ReverseImageFlowFailure(code: error.code, message: error.message);
    }
    if (error is ReverseImagePlatformException) {
      return ReverseImageFlowFailure(code: error.code, message: error.message);
    }
    if (error is ReverseImageProviderException) {
      return ReverseImageFlowFailure(code: error.code, message: error.message);
    }
    return const ReverseImageFlowFailure(
      code: ReverseImageProviderFailureCode.network,
      message: 'reverse image search failed',
      retryable: true,
    );
  }

  /// Search-time failure: keeps the owned input, records the failure against
  /// [engine] so the chips can mark it, and stays retryable/switchable.
  void _failSearch(
    ReverseImageEngine engine,
    ReverseImageFlowFailure failure,
    Map<ReverseImageEngine, ReverseImageFlowFailure> engineFailures,
  ) {
    engineFailures[engine] = failure;
    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.failure,
        engine: engine,
        input: _input?.info,
        failure: failure,
        engineFailures: Map.unmodifiable(engineFailures),
        noMatchEngines: state.noMatchEngines,
      ),
    );
  }

  void _setFailure(ReverseImageFlowFailure failure) {
    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.failure,
        engine: state.engine,
        input: _input?.info,
        failure: failure,
        engineFailures: state.engineFailures,
        noMatchEngines: state.noMatchEngines,
      ),
    );
  }

  void _setState(ReverseImageFlowState value) {
    if (_closed) return;
    state = value;
  }

  static String _nowIso() => DateTime.now().toIso8601String();
}
