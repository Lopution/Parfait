import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the connectivity plugin's channels with a steady Wi-Fi link
/// until the test ends. Connectivity is an external boundary: the network
/// policy listens to it as soon as anything creates the network factory
/// (an image, a request). Unanswered, the missing-plugin replies to its
/// listen and cancel calls land whenever real async runs (`runAsync`) and
/// surface as test exceptions; a steady link also keeps the network
/// identity from cycling.
void answerConnectivityChannels() {
  const statusChannel = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  const checkChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(statusChannel, (_) async => null);
  messenger.setMockMethodCallHandler(checkChannel, (_) async => ['wifi']);
  addTearDown(() {
    messenger.setMockMethodCallHandler(statusChannel, null);
    messenger.setMockMethodCallHandler(checkChannel, null);
  });
}
