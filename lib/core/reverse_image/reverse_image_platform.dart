import 'package:flutter/services.dart';

import 'image_input.dart';

abstract interface class ReverseImageInputPlatform {
  /// Opens the system document picker. `null` means the user cancelled.
  Future<ReverseImageInputReference?> pickImage();

  /// Copies a granted content URI into an app-owned temporary file. The
  /// returned path is opaque to the UI and must be deleted through this same
  /// adapter.
  Future<String> copyToOwnedFile(ReverseImageInputReference reference);

  /// Deletes only a path previously returned by [copyToOwnedFile].
  Future<void> deleteOwnedFile(String path);
}

enum ReverseImagePlatformFailureCode {
  unavailable,
  pickerFailed,
  malformedResponse,
  permissionDenied,
  copyFailed,
  cleanupFailed,
}

class ReverseImagePlatformException implements Exception {
  const ReverseImagePlatformException(this.code, this.message);

  final ReverseImagePlatformFailureCode code;
  final String message;

  @override
  String toString() => 'ReverseImagePlatformException($code, $message)';
}

abstract final class ReverseImageInputMethods {
  static const channel = 'pixivfunc/reverse_image_input';
  static const pickImage = 'pickImage';
  static const copyToTemp = 'copyToTemp';
  static const deleteTemp = 'deleteTemp';
}

class MethodChannelReverseImageInputPlatform
    implements ReverseImageInputPlatform {
  MethodChannelReverseImageInputPlatform([
    this._channel = const MethodChannel(ReverseImageInputMethods.channel),
  ]);

  final MethodChannel _channel;

  @override
  Future<ReverseImageInputReference?> pickImage() async {
    try {
      final message = await _channel.invokeMethod<Object?>(
        ReverseImageInputMethods.pickImage,
      );
      if (message == null) return null;
      return _decodeReference(message, source: ReverseImageInputSource.picker);
    } on PlatformException catch (error) {
      throw ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.pickerFailed,
        _safePlatformMessage(error.message, fallback: 'image picker failed'),
      );
    } on MissingPluginException {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.unavailable,
        'image picker is unavailable on this platform',
      );
    }
  }

  @override
  Future<String> copyToOwnedFile(ReverseImageInputReference reference) async {
    try {
      final message = await _channel.invokeMethod<Object?>(
        ReverseImageInputMethods.copyToTemp,
        {'uri': reference.contentUri},
      );
      final map = _map(message);
      final path = map['path'];
      if (path is! String || path.trim().isEmpty) {
        throw const ReverseImagePlatformException(
          ReverseImagePlatformFailureCode.malformedResponse,
          'image copy response is malformed',
        );
      }
      return path;
    } on ReverseImagePlatformException {
      rethrow;
    } on PlatformException catch (error) {
      throw ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.copyFailed,
        _safePlatformMessage(error.message, fallback: 'image copy failed'),
      );
    } on MissingPluginException {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.unavailable,
        'image input is unavailable on this platform',
      );
    }
  }

  @override
  Future<void> deleteOwnedFile(String path) async {
    try {
      final deleted = await _channel.invokeMethod<Object?>(
        ReverseImageInputMethods.deleteTemp,
        {'path': path},
      );
      if (deleted is! bool || !deleted) {
        throw const ReverseImagePlatformException(
          ReverseImagePlatformFailureCode.cleanupFailed,
          'temporary image cleanup was not confirmed',
        );
      }
    } on ReverseImagePlatformException {
      rethrow;
    } on PlatformException catch (error) {
      throw ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.cleanupFailed,
        _safePlatformMessage(
          error.message,
          fallback: 'temporary image cleanup failed',
        ),
      );
    } on MissingPluginException {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.unavailable,
        'temporary image cleanup is unavailable on this platform',
      );
    }
  }

  static ReverseImageInputReference _decodeReference(
    Object? message, {
    required ReverseImageInputSource source,
  }) {
    final map = _map(message);
    final uri = map['uri'];
    final mimeType = map['mimeType'];
    final sizeBytes = map['sizeBytes'];
    final permission = map['hasReadUriPermission'];
    if (uri is! String ||
        uri.trim().isEmpty ||
        mimeType is! String ||
        sizeBytes is! int ||
        permission is! bool) {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.malformedResponse,
        'image picker metadata is malformed',
      );
    }
    return ReverseImageInputReference(
      contentUri: uri,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      hasReadUriPermission: permission,
      source: source,
    );
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map) {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.malformedResponse,
        'image platform response is not a map',
      );
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const ReverseImagePlatformException(
          ReverseImagePlatformFailureCode.malformedResponse,
          'image platform response keys are malformed',
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static String _safePlatformMessage(
    String? message, {
    required String fallback,
  }) {
    final value = message?.trim();
    if (value == null || value.isEmpty) return fallback;
    return value.length <= 160 ? value : '${value.substring(0, 160)}…';
  }
}
