import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the network identity channels (the connectivity plugin's, and
/// Android's own) with a steady Wi-Fi link until the test ends. They are an
/// external boundary: the network policy listens to one as soon as anything
/// creates the network factory (an image, a request). Unanswered, the
/// missing-plugin replies to its listen and cancel calls land whenever real
/// async runs (`runAsync`) and surface as test exceptions; a steady link
/// also keeps the network identity from cycling.
void answerConnectivityChannels() {
  const statusChannel = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  const checkChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const identityChannel = EventChannel('parfait/network_identity/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(statusChannel, (_) async => null);
  messenger.setMockMethodCallHandler(checkChannel, (_) async => ['wifi']);
  messenger.setMockStreamHandler(
    identityChannel,
    MockStreamHandler.inline(
      onListen: (_, events) => events.success('wifi:00000000'),
    ),
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(statusChannel, null);
    messenger.setMockMethodCallHandler(checkChannel, null);
    messenger.setMockStreamHandler(identityChannel, null);
  });
}
