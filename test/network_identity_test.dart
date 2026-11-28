import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/platform/network_identity.dart';

class _FakeConnectivity implements Connectivity {
  _FakeConnectivity({required this.initialResult, required this.changes});

  final Future<List<ConnectivityResult>> Function() initialResult;
  final Stream<List<ConnectivityResult>> changes;
  int streamSubscriptions = 0;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() => initialResult();

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    streamSubscriptions++;
    return changes;
  }
}

void main() {
  test(
    'missing Linux NetworkManager DBus error stops before subscribing to onConnectivityChanged',
    () async {
      final controller = StreamController<List<ConnectivityResult>>.broadcast();
      addTearDown(controller.close);
      final fake = _FakeConnectivity(
        initialResult: () async => throw Exception(
          'org.freedesktop.DBus.Error.ServiceUnknown: The name org.freedesktop.NetworkManager was not provided',
        ),
        changes: controller.stream,
      );
      final source = ConnectivityNetworkIdentitySource(
        createConnectivity: () => fake,
      );

      final emitted = await source.identities().toList();
      expect(emitted, isEmpty);
      expect(fake.streamSubscriptions, 0);
    },
  );

  test(
    'non-DBus initial error still follows stream changes and absorbs runtime stream errors',
    () async {
      final controller = StreamController<List<ConnectivityResult>>.broadcast();
      addTearDown(controller.close);
      final fake = _FakeConnectivity(
        initialResult: () async => throw StateError('transient probe failure'),
        changes: controller.stream,
      );
      final source = ConnectivityNetworkIdentitySource(
        createConnectivity: () => fake,
      );

      final emitted = <String>[];
      final sub = source.identities().listen(emitted.add);
      addTearDown(sub.cancel);

      await Future<void>.delayed(Duration.zero);
      expect(fake.streamSubscriptions, 1);

      controller.addError(StateError('runtime DBus drop'));
      controller.add([ConnectivityResult.wifi, ConnectivityResult.vpn]);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, ['vpn+wifi']);
    },
  );
}
