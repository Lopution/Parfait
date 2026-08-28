import 'dart:async';

import 'package:flutter/foundation.dart';

import '../network/pixiv_http_client.dart';
import 'image_input.dart';
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
  });

  final Object code;
  final String message;
  final bool retryable;
}

@immutable
class ReverseImageFlowState {
  const ReverseImageFlowState({
    required this.status,
    this.input,
    this.results = const [],
    this.failure,
  });

  const ReverseImageFlowState.idle()
    : status = ReverseImageFlowStatus.idle,
      input = null,
      results = const [],
      failure = null;

  final ReverseImageFlowStatus status;
  final ReverseImageInputInfo? input;
  final List<ReverseImageHit> results;
  final ReverseImageFlowFailure? failure;
}

/// Coordinates picker/SEND preparation and provider execution. The controller
/// owns one temporary file and releases it on every terminal path.
class ReverseImageSearchController extends ChangeNotifier {
  ReverseImageSearchController({
    required this.platform,
    required this.provider,
  });

  final ReverseImageInputPlatform platform;
  final ReverseImageProvider provider;

  ReverseImageFlowState _state = const ReverseImageFlowState.idle();
  OwnedReverseImageInput? _input;
  CancelToken? _cancelToken;
  int _generation = 0;
  bool _closed = false;

  ReverseImageFlowState get state => _state;
  ReverseImageProviderCapability get capability => provider.capability;

  Future<void> pick() async {
    if (_closed) return;
    _setState(
      const ReverseImageFlowState(status: ReverseImageFlowStatus.picking),
    );
    try {
      final reference = await platform.pickImage();
      if (_closed || reference == null) {
        if (!_closed) _setState(const ReverseImageFlowState.idle());
        return;
      }
      await prepare(reference);
    } on Object catch (error) {
      _setFailure(_flowFailure(error));
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
      const ReverseImageFlowState(status: ReverseImageFlowStatus.preparing),
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

  Future<void> search() async {
    if (_closed ||
        _input == null ||
        _state.status != ReverseImageFlowStatus.ready) {
      return;
    }
    final generation = _generation;
    final input = _input!;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.searching,
        input: input.info,
      ),
    );

    ReverseImageSearchOutcome? outcome;
    Object? error;
    try {
      outcome = await provider.search(input, cancelToken: cancelToken);
    } on Object catch (caught) {
      error = caught;
    }

    Object? cleanupError;
    try {
      await _releaseInput();
    } on Object catch (caught) {
      cleanupError = caught;
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
      _setFailure(_flowFailure(caught));
      return;
    }
    switch (outcome) {
      case ReverseImageSearchSuccess(:final hits):
        _setState(
          ReverseImageFlowState(
            status: ReverseImageFlowStatus.success,
            results: hits,
          ),
        );
      case ReverseImageSearchFailure(
        :final code,
        :final message,
        :final retryable,
      ):
        _setState(
          ReverseImageFlowState(
            status: ReverseImageFlowStatus.failure,
            failure: ReverseImageFlowFailure(
              code: code,
              message: message,
              retryable: retryable,
            ),
          ),
        );
      case null:
        _setFailure(
          const ReverseImageFlowFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'reverse image provider returned no result',
          ),
        );
    }
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
        const ReverseImageFlowState(status: ReverseImageFlowStatus.canceled),
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

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
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
    if (input != null) await input.dispose();
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

  void _setFailure(ReverseImageFlowFailure failure) {
    if (_closed) return;
    _setState(
      ReverseImageFlowState(
        status: ReverseImageFlowStatus.failure,
        failure: failure,
      ),
    );
  }

  void _setState(ReverseImageFlowState value) {
    if (_closed) return;
    _state = value;
    notifyListeners();
  }
}
