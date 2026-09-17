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

abstract final class _ReverseImageInputMethods {
  static const channel = 'pixivfunc/reverse_image_input';
  static const pickImage = 'pickImage';
  static const copyToTemp = 'copyToTemp';
  static const deleteTemp = 'deleteTemp';
  static const armReverseUpload = 'armReverseUpload';
  static const disarmReverseUpload = 'disarmReverseUpload';
}

/// Arms an owned temporary input file to the next WebView file chooser so a
/// Cloudflare-fronted engine page uploads it without a second picker
/// (Ascii2D, TinEye — see `reverse_image_provider.dart`'s WebUpload outcome).
abstract interface class ReverseImageUploadArmer {
  /// Returns the content URI handed to the browser, or `null` when the
  /// platform has no chooser interception (desktop: the native picker runs
  /// and the user re-picks the file — the upload page still works).
  Future<String?> armUpload(String path);

  /// Clears a previously armed file (one-shot semantics on the platform
  /// side already consume it; disarm covers pages left before a chooser).
  Future<void> disarmUpload();
}

class MethodChannelReverseImageUploadArmer implements ReverseImageUploadArmer {
  MethodChannelReverseImageUploadArmer([
    this._channel = const MethodChannel(_ReverseImageInputMethods.channel),
  ]);

  final MethodChannel _channel;

  @override
  Future<String?> armUpload(String path) async {
    try {
      final message = await _channel.invokeMethod<Object?>(
        _ReverseImageInputMethods.armReverseUpload,
        {'path': path},
      );
      if (message is! String || message.isEmpty) {
        throw const ReverseImagePlatformException(
          ReverseImagePlatformFailureCode.malformedResponse,
          'armed image response is malformed',
        );
      }
      return message;
    } on ReverseImagePlatformException {
      rethrow;
    } on PlatformException catch (error) {
      throw ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.pickerFailed,
        _safePlatformMessage(error.message, fallback: 'image arm failed'),
      );
    } on MissingPluginException {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.unavailable,
        'image upload arming is unavailable on this platform',
      );
    }
  }

  @override
  Future<void> disarmUpload() async {
    try {
      await _channel.invokeMethod<Object?>(
        _ReverseImageInputMethods.disarmReverseUpload,
      );
    } on PlatformException catch (error) {
      throw ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.pickerFailed,
        _safePlatformMessage(error.message, fallback: 'image disarm failed'),
      );
    } on MissingPluginException {
      throw const ReverseImagePlatformException(
        ReverseImagePlatformFailureCode.unavailable,
        'image upload disarm is unavailable on this platform',
      );
    }
  }
}

/// Desktop degrade: WebView2 exposes no file-chooser interception, so the
/// engine page's native picker simply opens and the user re-picks the file.
class NoopReverseImageUploadArmer implements ReverseImageUploadArmer {
  const NoopReverseImageUploadArmer();

  @override
  Future<String?> armUpload(String path) async => null;

  @override
  Future<void> disarmUpload() async {}
}

class MethodChannelReverseImageInputPlatform
    implements ReverseImageInputPlatform {
  MethodChannelReverseImageInputPlatform([
    this._channel = const MethodChannel(_ReverseImageInputMethods.channel),
  ]);

  final MethodChannel _channel;

  @override
  Future<ReverseImageInputReference?> pickImage() async {
    try {
      final message = await _channel.invokeMethod<Object?>(
        _ReverseImageInputMethods.pickImage,
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
        _ReverseImageInputMethods.copyToTemp,
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
        _ReverseImageInputMethods.deleteTemp,
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
}

Map<String, Object?> _map(Object? value) {
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

String _safePlatformMessage(String? message, {required String fallback}) {
  final value = message?.trim();
  if (value == null || value.isEmpty) return fallback;
  return value.length <= 160 ? value : '${value.substring(0, 160)}…';
}
