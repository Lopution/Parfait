import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart → native widget maintenance channel.
///
/// Native (Android) owns AppWidgetManager and WorkManager; Dart owns the
/// account state and the snapshot store. These methods are the only bridge:
/// the platform side never receives account ids, tokens or image bytes —
/// only the fact that render state changed, plus the account revision used
/// to key scheduled work.
abstract final class WidgetChannel {
  static const MethodChannel _channel = MethodChannel('pixivfunc/widget');

  /// A new snapshot is active (or the store was cleared); native re-renders
  /// every widget from the store and re-keys scheduled work.
  static Future<void> notifySnapshotChanged(int accountRevision) =>
      _invoke('notifySnapshotChanged', accountRevision);

  /// The previous account must disappear from the home screen: native
  /// deletes render state and cancels its scheduled work.
  static Future<void> clearSnapshot() => _invoke('clearSnapshot', null);

  /// Explicit refresh request (used after transient failures).
  static Future<void> requestRefresh() => _invoke('requestRefresh', null);

  static Future<void> _invoke(String method, Object? argument) async {
    try {
      await _channel.invokeMethod<void>(method, argument);
    } on MissingPluginException {
      // Non-Android platforms have no widget host; nothing to schedule.
    } on PlatformException catch (error) {
      // Foreground scheduling is best-effort, but the failure remains
      // observable; the background worker path owns authoritative retries.
      debugPrint(
        'WidgetChannel $method failed: ${error.code}: ${error.message}',
      );
    }
  }
}
