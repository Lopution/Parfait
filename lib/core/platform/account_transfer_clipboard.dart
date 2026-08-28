import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../auth/account_transfer.dart';

/// Clipboard snapshot returned only after an explicit user-triggered read.
/// The fingerprint is an opaque equality handle; it is not clipboard text.
class TransferClipboardContent {
  const TransferClipboardContent({
    required this.text,
    required this.fingerprint,
  });

  final String text;
  final String fingerprint;
}

/// Platform boundary for the account-transfer clipboard lifecycle.
abstract interface class TransferClipboard {
  Future<void> write(String text, {required Duration clearAfter});

  Future<TransferClipboardContent?> read();

  /// Clears only if the currently owned clipboard content still has the given
  /// fingerprint. Returns false when the user or another app replaced it.
  Future<bool> clearIfCurrent(String fingerprint);
}

abstract final class TransferClipboardMethods {
  static const channel = 'pixivfunc/account_transfer_clipboard';
  static const write = 'write';
  static const read = 'read';
  static const clearIfCurrent = 'clearIfCurrent';
}

/// Android channel implementation. There is intentionally no fallback to
/// Flutter's generic clipboard API because that fallback cannot set the
/// Android sensitive flag or perform conditional clearing.
class MethodChannelTransferClipboard implements TransferClipboard {
  MethodChannelTransferClipboard([
    this._channel = const MethodChannel(TransferClipboardMethods.channel),
  ]);

  final MethodChannel _channel;

  @override
  Future<void> write(String text, {required Duration clearAfter}) async {
    if (text.isEmpty || text.length > TransferEnvelope.maxEncodedLength) {
      throw const AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard payload is outside the supported size',
      );
    }
    if (clearAfter <= Duration.zero ||
        clearAfter > TransferEnvelope.maxLifetime) {
      throw const AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard expiry is outside the supported window',
      );
    }
    final fingerprint = transferClipboardFingerprint(text);
    try {
      final result = await _channel.invokeMethod<Object?>(
        TransferClipboardMethods.write,
        <String, Object?>{
          'text': text,
          'fingerprint': fingerprint,
          'clearAfterMs': clearAfter.inMilliseconds,
        },
      );
      if (result != true) {
        throw const AccountTransferException(
          AccountTransferErrorCode.clipboardUnavailable,
          'clipboard write was not confirmed',
        );
      }
    } on AccountTransferException {
      rethrow;
    } on PlatformException catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard write is unavailable',
        cause: error,
      );
    } on MissingPluginException catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard write is unavailable on this platform',
        cause: error,
      );
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard write failed',
        cause: error,
      );
    }
  }

  @override
  Future<TransferClipboardContent?> read() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        TransferClipboardMethods.read,
      );
      if (raw == null) return null;
      if (raw is! Map) {
        throw const AccountTransferException(
          AccountTransferErrorCode.clipboardUnavailable,
          'clipboard response is malformed',
        );
      }
      final map = <Object?, Object?>{};
      for (final entry in raw.entries) {
        map[entry.key] = entry.value;
      }
      if (map.length != 2 ||
          !map.containsKey('text') ||
          !map.containsKey('fingerprint')) {
        throw const AccountTransferException(
          AccountTransferErrorCode.clipboardUnavailable,
          'clipboard response is malformed',
        );
      }
      final text = map['text'];
      final fingerprint = map['fingerprint'];
      if (text is! String ||
          fingerprint is! String ||
          text.isEmpty ||
          text.length > TransferEnvelope.maxEncodedLength ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
          transferClipboardFingerprint(text) != fingerprint) {
        throw const AccountTransferException(
          AccountTransferErrorCode.clipboardUnavailable,
          'clipboard response is malformed',
        );
      }
      return TransferClipboardContent(text: text, fingerprint: fingerprint);
    } on AccountTransferException {
      rethrow;
    } on PlatformException catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard read is unavailable',
        cause: error,
      );
    } on MissingPluginException catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard read is unavailable on this platform',
        cause: error,
      );
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard read failed',
        cause: error,
      );
    }
  }

  @override
  Future<bool> clearIfCurrent(String fingerprint) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw const AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard fingerprint is malformed',
      );
    }
    try {
      final result = await _channel.invokeMethod<Object?>(
        TransferClipboardMethods.clearIfCurrent,
        <String, Object?>{'fingerprint': fingerprint},
      );
      if (result is! bool) {
        throw const AccountTransferException(
          AccountTransferErrorCode.clipboardUnavailable,
          'clipboard clear response is malformed',
        );
      }
      return result;
    } on AccountTransferException {
      rethrow;
    } on PlatformException catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard clear is unavailable',
        cause: error,
      );
    } on MissingPluginException catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard clear is unavailable on this platform',
        cause: error,
      );
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard clear failed',
        cause: error,
      );
    }
  }
}

String transferClipboardFingerprint(String text) =>
    sha256.convert(utf8.encode(text)).toString();
