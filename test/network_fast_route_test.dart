import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:pixiv_func/core/download/download_transport.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/network_fast_route_store.dart';
import 'package:pixiv_func/core/network/compat/pixiv_network_factory.dart';
import 'package:pixiv_func/core/network/compat/network_policy.dart';
import 'package:pixiv_func/core/network/compat/policy_download_transport.dart';
import 'package:pixiv_func/core/network/compat/secure_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _RecordingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{}')),
      200,
      request: request,
    );
  }
}

class _Resolver implements SecureResolver {
  var calls = 0;

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    calls++;
    return ResolvedHost(
      host: host,
      addresses: [InternetAddress('1.2.3.4')],
      dnsSource: DnsSource.system,
      revision: revision,
    );
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test(
    'every native Pixiv exit shares the policy and strict tiers are first',
    () async {
      final resolver = _Resolver();
      final store = PixivFastRouteStore(preferences: SharedPreferencesAsync());
      final clients = <String, _RecordingClient>{};
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        fastRouteStore: store,
        insecureNoSniEnabled: true,
        clientFactory: (route, host, purpose) =>
            clients.putIfAbsent('${purpose.name}|$host', _RecordingClient.new),
      );
      final factory = PixivNetworkFactory(policy);
      addTearDown(factory.dispose);

      await factory.apiClient.get(
        Uri.parse('https://app-api.pixiv.net/v1/illust/recommended'),
      );
      await factory.oauthClient.get(
        Uri.parse('https://oauth.secure.pixiv.net/auth/token'),
      );
      await factory
          .client(PixivDestinationPurpose.image)
          .get(Uri.parse('https://i.pximg.net/img-master/img/1/2/3/a.jpg'));

      final download = PolicyDownloadTransport(policy: policy);
      addTearDown(download.dispose);
      final response = await download.open(
        Uri.parse('https://s.pximg.net/img-original/img/1/2/3/a.jpg'),
        headers: const {},
        cancelToken: DownloadCancelToken(),
      );
      await response.stream.drain<void>();
      await response.close();

      // Strict tiers are verified before the unverified fast address: each
      // host resolves once through DoH.
      expect(resolver.calls, 4);
      for (final client in clients.values) {
        expect(client.requests, isNotEmpty);
        expect(
          client.requests,
          everyElement(
            predicate<http.BaseRequest>((request) => request.method == 'GET'),
          ),
        );
      }
    },
  );

  test('fast host addresses survive an app restart', () async {
    final preferences = SharedPreferencesAsync();
    await preferences.setString(
      PixivFastRouteStore.storageKey,
      jsonEncode({'i.pximg.net': '1.2.3.44'}),
    );
    final store = PixivFastRouteStore(preferences: preferences);

    expect((await store.addressFor('i.pximg.net'))?.address, '1.2.3.44');
    expect((await store.addressFor('s.pximg.net'))?.address, '210.140.139.133');
  });

  test('policy warmup creates API, OAuth, web and both image pools', () async {
    final created = <({NetworkRoute route, String host})>[];
    final policy = NetworkAccessPolicy(
      fastRouteStore: PixivFastRouteStore(
        preferences: SharedPreferencesAsync(),
      ),
      insecureNoSniEnabled: true,
      clientFactory: (route, host, _) {
        created.add((route: route, host: host));
        return _RecordingClient();
      },
    );
    addTearDown(policy.dispose);

    await policy.warmUp();

    expect(created, hasLength(5));
    expect(
      created.map((entry) => entry.host),
      containsAll(<String>[
        'app-api.pixiv.net',
        'oauth.secure.pixiv.net',
        'www.pixiv.net',
        'i.pximg.net',
        's.pximg.net',
      ]),
    );
    expect(
      created.map((entry) => entry.route.kind),
      everyElement(NetworkRouteKind.insecureNoSni),
    );
  });

  test('a failed fast address is cooled before the next request', () async {
    var now = DateTime.utc(2026, 9, 3);
    final policy = NetworkAccessPolicy(
      resolver: StaticSecureResolver(addresses: [InternetAddress('1.2.3.4')]),
      fastRouteStore: PixivFastRouteStore(
        preferences: SharedPreferencesAsync(),
      ),
      insecureNoSniEnabled: true,
      clock: () => now,
    );
    addTearDown(policy.dispose);
    final destination = policy.registry.require(
      Uri.parse('https://app-api.pixiv.net/v1/illust/recommended'),
      PixivDestinationPurpose.appApi,
    );
    final attempted = <NetworkRouteKind>[];

    Future<void> run() => policy.runLadder<void>(
      destination: destination,
      cancelSignal: null,
      canReplay: false,
      attempt: (route, _) async {
        attempted.add(route.kind);
        throw const NetworkFailureException(NetworkFailureKind.connect);
      },
    );

    await expectLater(run(), throwsA(isA<NetworkFailureException>()));
    expect(attempted, [
      NetworkRouteKind.dohRealSni,
      NetworkRouteKind.direct,
      NetworkRouteKind.insecureNoSni,
    ]);

    attempted.clear();
    await expectLater(run(), throwsA(isA<NetworkFailureException>()));
    expect(
      attempted,
      isNot(contains(NetworkRouteKind.insecureNoSni)),
      reason: 'the cooled fast address must not be tried again',
    );

    now = now.add(const Duration(seconds: 31));
    attempted.clear();
    await expectLater(run(), throwsA(isA<NetworkFailureException>()));
    expect(attempted, contains(NetworkRouteKind.insecureNoSni));
  });
}
