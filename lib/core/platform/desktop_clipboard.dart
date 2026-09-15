import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../auth/account_transfer.dart';
import 'account_transfer_clipboard.dart';

/// Desktop [TransferClipboard] backed by Flutter's generic `Clipboard`.
///
/// Desktop platforms cannot set the Android `EXTRA_IS_SENSITIVE` flag, so
/// [capabilities] reports `sensitiveMarkSupported: false` and callers show
/// the existing explicit-warning path (the same contract Android < API 33
/// already uses). Timed auto-clear is approximated: [write] arms a timer
/// that clears only while our fingerprint still owns the clipboard.
class FlutterTransferClipboard implements TransferClipboard {
  FlutterTransferClipboard();

  Timer? _clearTimer;
  String? _ownedFingerprint;

  @override
  Future<TransferClipboardCapabilities> capabilities() async =>
      const TransferClipboardCapabilities(sensitiveMarkSupported: false);

  @override
  Future<void> write(String text, {required Duration clearAfter}) async {
    if (text.isEmpty || text.length > TransferEnvelope.maxEncodedLength) {
      throw const AccountTransferException(
        AccountTransferErrorCode.clipboardUnavailable,
        'clipboard payload is outside the supported size',
      );
    }
    final fingerprint = transferClipboardFingerprint(text);
    await Clipboard.setData(ClipboardData(text: text));
    _ownedFingerprint = fingerprint;
    _clearTimer?.cancel();
    _clearTimer = Timer(clearAfter, () {
      unawaited(clearIfCurrent(fingerprint));
    });
  }

  @override
  Future<TransferClipboardContent?> read() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) return null;
    return TransferClipboardContent(
      text: text,
      fingerprint: transferClipboardFingerprint(text),
    );
  }

  @override
  Future<bool> clearIfCurrent(String fingerprint) async {
    final current = await read();
    if (current == null || current.fingerprint != fingerprint) return false;
    await Clipboard.setData(const ClipboardData(text: ''));
    if (_ownedFingerprint == fingerprint) {
      _ownedFingerprint = null;
      _clearTimer?.cancel();
      _clearTimer = null;
    }
    return true;
  }
}
