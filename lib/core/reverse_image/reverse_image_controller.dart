/// Reverse-image input ownership, provider capability, and search flow state.
/// [ReverseImageSearchController] owns the temporary input lifecycle while
/// providers own their result protocol. See `frontend/state-management.md`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/foundation.dart';

import '../network/pixiv_http_client.dart';
import 'image_input.dart';
import 'reverse_image_engine.dart';
import 'reverse_image_platform.dart';
import 'reverse_image_provider.dart';

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
    this.results = const [],
    this.webView,
    this.webUpload,
    this.failure,
    this.engineFailures = const {},
  });

  const ReverseImageFlowState.idle([this.engine = ReverseImageEngine.sauceNao])
    : status = ReverseImageFlowStatus.idle,
      input = null,
      results = const [],
      webView = null,
      webUpload = null,
      failure = null,
      engineFailures = const {};

  final ReverseImageFlowStatus status;

  /// Currently selected engine. The failure/webUpload below always belongs
  /// to this engine.
  final ReverseImageEngine engine;
  final ReverseImageInputInfo? input;
  final List<ReverseImageHit> results;

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
      final input = await OwnedReverseImageInput.open(
        path: path,
        source: reference.source,
        mimeType: reference.mimeType,
        delete: platform.deleteOwnedFile,
      );
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

  /// Switches the selected engine. With no held image only the selection
  /// moves (the UI persists it); with a held image a ready/failure/webUpload
  /// state returns to ready so the new engine can be searched. A headless
  /// success already released the file and is not switchable.
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
      ),
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
    final generation = _generation;
    final input = _input!;
    final engine = state.engine;
    final engineFailures = Map.of(state.engineFailures);
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.searching,
        engine: engine,
        input: input.info,
        engineFailures: engineFailures,
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

    Object? cleanupError;
    // A stale generation must not release an input the newer flow still
    // owns — stopSearch()/prepare() already decided that input's fate.
    if (_closed || generation != _generation) return;
    // The file stays owned on web-upload (the browser submits it later) and
    // on failure (another engine may still accept it — constraints differ).
    // Headless/webview successes are terminal and release it now.
    final keepInput =
        outcome is ReverseImageSearchWebUpload ||
        outcome is ReverseImageSearchFailure ||
        error != null;
    if (!keepInput) {
      try {
        await _releaseInput();
      } on Object catch (caught) {
        cleanupError = caught;
      }
    }
    if (_cancelToken == cancelToken) _cancelToken = null;
    if (_closed || generation != _generation) return;
    final cleanup = cleanupError;
    if (cleanup != null) {
      _setFailure(_flowFailure(cleanup));
      return;
    }
    final caught = error;
    if (caught != null) {
      _failSearch(engine, _flowFailure(caught), engineFailures);
      return;
    }
    switch (outcome) {
      case ReverseImageSearchSuccess(:final hits):
        _setState(
          ReverseImageFlowState(
            status: ReverseImageFlowStatus.success,
            engine: engine,
            results: hits,
            engineFailures: engineFailures,
          ),
        );
      case ReverseImageSearchWebView(:final html, :final resultUrl):
        _setState(
          ReverseImageFlowState(
            status: ReverseImageFlowStatus.success,
            engine: engine,
            webView: ReverseImageSearchWebView(
              html: html,
              resultUrl: resultUrl,
              observedAt: _nowIso(),
            ),
            engineFailures: engineFailures,
          ),
        );
      case ReverseImageSearchWebUpload(:final uploadPageUrl):
        _setState(
          ReverseImageFlowState(
            status: ReverseImageFlowStatus.success,
            engine: engine,
            input: input.info,
            engineFailures: engineFailures,
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
      ),
    );
  }

  void _setState(ReverseImageFlowState value) {
    if (_closed) return;
    state = value;
  }

  static String _nowIso() => DateTime.now().toIso8601String();
}
