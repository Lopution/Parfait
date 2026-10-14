import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/errors/error_category.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/local_network_address.dart';
import 'package:parfait/core/platform/local_network.dart';
import 'package:parfait/core/settings/settings_controller.dart';

import 'helpers/settings_world.dart';

class _FakePermission implements LocalNetworkPermission {
  _FakePermission({this.proxy});

  bool granted = false;
  bool answer = false;
  String? proxy;
  int dialogs = 0;

  /// While set, the dialog stays up until it completes.
  Completer<bool>? dialog;

  @override
  Future<bool> isGranted() async => granted;

  @override
  Future<bool> request() async {
    dialogs++;
    return granted = await (dialog?.future ?? Future.value(answer));
  }

  @override
  Future<String?> proxyHost() async => proxy;
}

/// `nas.home.example` sits on the local network; anything else is public.
Future<List<InternetAddress>> _lookup(String host) async => [
  InternetAddress(host == 'nas.home.example' ? '192.168.1.5' : '104.18.1.1'),
];

void main() {
  test("local network addresses follow Android 17's definition", () {
    const local = [
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.2',
      '169.254.1.1',
      '100.64.0.1',
      '224.0.0.251',
      '255.255.255.255',
      'fe80::1',
      'fd00::1',
      'ff02::fb',
      '::ffff:192.168.1.2',
    ];
    const elsewhere = [
      '127.0.0.1',
      '::1',
      '8.8.8.8',
      '172.32.0.1',
      '100.128.0.1',
      '2606:4700::1',
      '::ffff:8.8.8.8',
      '::ffff:127.0.0.1',
    ];
    for (final address in local) {
      expect(isLocalNetworkAddress(InternetAddress(address)), isTrue);
    }
    for (final address in elsewhere) {
      expect(isLocalNetworkAddress(InternetAddress(address)), isFalse);
    }
  });

  test('a local host asks with the system dialog; no fails at once', () async {
    final permission = _FakePermission();
    final gate = LocalNetworkGate(permission, lookup: _lookup);

    await gate.ensure('pixiv.example');
    expect(permission.dialogs, 0);

    await expectLater(
      gate.ensure('nas.home.example'),
      throwsA(isA<LocalNetworkBlocked>()),
    );
    expect(permission.dialogs, 1);
    expect(await gate.isLocalHost('printer.local'), isTrue);
    expect(
      categorizeError(ApiNetworkError(const LocalNetworkBlocked('x'))),
      ErrorCategory.localNetwork,
    );

    permission.answer = true;
    await gate.ensure('192.168.1.2');
    expect(permission.dialogs, 2);
    await gate.ensure('192.168.1.2');
    expect(permission.dialogs, 2);
  });

  test('configured local hosts ask once; denied, none connects', () async {
    final permission = _FakePermission(proxy: '192.168.1.9')
      ..dialog = Completer();
    final repository = FakeSettingsRepository(
      baseTestSettings().copyWith(
        imageSource: 'https://nas.home.example',
        dohEndpointOverride: 'https://192.168.1.2/dns-query',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(repository),
        localNetworkGateProvider.overrideWithValue(
          LocalNetworkGate(permission, lookup: _lookup),
        ),
      ],
    );
    addTearDown(container.dispose);
    final blocked = container.listen(
      localNetworkBlockedHostsProvider,
      (_, _) {},
    );
    await container.read(settingsProvider.future);
    await pumpEventQueue();

    // Blocked while the dialog is up, and after it is denied.
    const local = {'nas.home.example', '192.168.1.2', '192.168.1.9'};
    expect(blocked.read(), local);
    permission.dialog!.complete(false);
    await pumpEventQueue();
    expect(blocked.read(), local);
    expect(permission.dialogs, 1);
    container.read(localNetworkBlockedHostsProvider.notifier).refresh();
    await pumpEventQueue();
    expect(permission.dialogs, 1);

    var connected = false;
    final policy = NetworkAccessPolicy(
      registry: PixivDestinationRegistry(extraImageHosts: {'nas.home.example'}),
      localNetworkBlockedHosts: blocked.read(),
      clientFactory: (_, _, _) => throw StateError('connected'),
    );
    addTearDown(policy.dispose);
    await expectLater(
      policy.runLadder<void>(
        destination: policy.registry.require(
          Uri.parse('https://nas.home.example/img/1.jpg'),
          PixivDestinationPurpose.image,
        ),
        cancelSignal: null,
        canReplay: true,
        attempt: (_, _) => connected = true,
      ),
      throwsA(isA<LocalNetworkBlocked>()),
    );
    expect(connected, isFalse);

    permission.granted = true;
    container.read(localNetworkBlockedHostsProvider.notifier).refresh();
    await pumpEventQueue();
    expect(blocked.read(), isEmpty);
  });
}
