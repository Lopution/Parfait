import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_transfer.dart';
import '../settings/preference_keys.dart';
import 'account_transfer_clipboard.dart';

/// Cross-platform [TransferClipboard] backed by Flutter's generic `Clipboard`
/// (iOS, Windows, macOS, Linux).
///
/// None of these targets expose Android's `EXTRA_IS_SENSITIVE` flag, so
/// [capabilities] reports `sensitiveMarkSupported: false` and callers show the
/// existing explicit-warning path. When [preferences] is supplied, the active
/// fingerprint and expiry timestamp are persisted so [sweepExpired] can clear
/// stale clipboard payloads across background suspends or process restarts.
class FlutterTransferClipboard implements ExpirableTransferClipboard {
  FlutterTransferClipboard({
    SharedPreferencesAsync? preferences,
    DateTime Function()? now,
  }) : _preferences = preferences,
       _now = now ?? DateTime.now;

  final SharedPreferencesAsync? _preferences;
  final DateTime Function() _now;
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
    final expiresAtMs = _now().toUtc().add(clearAfter).millisecondsSinceEpoch;
    await _persistState(fingerprint: fingerprint, expiresAtMs: expiresAtMs);
    _armTimer(fingerprint, clearAfter);
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
    if (_ownedFingerprint == fingerprint) {
      _ownedFingerprint = null;
      _clearTimer?.cancel();
      _clearTimer = null;
    }
    if (current == null || current.fingerprint != fingerprint) {
      await _clearPersistedIfMatching(fingerprint);
      return false;
    }
    await Clipboard.setData(const ClipboardData(text: ''));
    await _clearPersistedIfMatching(fingerprint);
    return true;
  }

  @override
  Future<bool> sweepExpired() async {
    final prefs = _preferences;
    if (prefs == null) return false;
    final String? raw;
    try {
      raw = await prefs.getString(PreferenceKeys.transferClipboardState);
    } catch (_) {
      return false;
    }
    if (raw == null || raw.isEmpty) return false;

    final String fingerprint;
    final int expiresAtMs;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> ||
          decoded['fingerprint'] is! String ||
          decoded['expiresAtMs'] is! int) {
        await _removePersistedState();
        return false;
      }
      fingerprint = decoded['fingerprint']! as String;
      expiresAtMs = decoded['expiresAtMs']! as int;
    } on FormatException {
      await _removePersistedState();
      return false;
    }

    final remainingMs = expiresAtMs - _now().toUtc().millisecondsSinceEpoch;
    if (remainingMs <= 0) {
      return clearIfCurrent(fingerprint);
    }
    if (_clearTimer == null) {
      _ownedFingerprint = fingerprint;
      _armTimer(fingerprint, Duration(milliseconds: remainingMs));
    }
    return false;
  }

  void _armTimer(String fingerprint, Duration delay) {
    _clearTimer?.cancel();
    _clearTimer = Timer(delay, () {
      unawaited(clearIfCurrent(fingerprint));
    });
  }

  /// Cancels any active in-process auto-clear timer on teardown.
  void dispose() {
    _clearTimer?.cancel();
    _clearTimer = null;
  }

  Future<void> _persistState({
    required String fingerprint,
    required int expiresAtMs,
  }) async {
    final prefs = _preferences;
    if (prefs == null) return;
    try {
      await prefs.setString(
        PreferenceKeys.transferClipboardState,
        jsonEncode({'fingerprint': fingerprint, 'expiresAtMs': expiresAtMs}),
      );
    } catch (_) {
      // Persistence failure should not block the foreground transfer copy.
    }
  }

  Future<void> _clearPersistedIfMatching(String fingerprint) async {
    final prefs = _preferences;
    if (prefs == null) return;
    try {
      final raw = await prefs.getString(PreferenceKeys.transferClipboardState);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?> &&
          decoded['fingerprint'] == fingerprint) {
        await prefs.remove(PreferenceKeys.transferClipboardState);
      }
    } catch (_) {
      // Ignore cleanup errors on shutdown/startup paths.
    }
  }

  Future<void> _removePersistedState() async {
    final prefs = _preferences;
    if (prefs == null) return;
    try {
      await prefs.remove(PreferenceKeys.transferClipboardState);
    } catch (_) {}
  }
}
