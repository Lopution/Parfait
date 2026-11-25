import 'package:parfait/core/platform/android_intent_channel.dart';

/// Shared test double for [OutboundUrlOpener] (TEST-10).
class RecordingOutboundUrlOpener implements OutboundUrlOpener {
  final urls = <String>[];
  Object? error;

  @override
  Future<void> openExternal(String url) async {
    urls.add(url);
    if (error case final failure?) throw failure;
  }
}
