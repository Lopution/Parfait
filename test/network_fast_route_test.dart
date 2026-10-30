import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/restricted_compat_support.dart' show FakeResolver;
import 'helpers/settings_world.dart' show RecordingClient;
import 'package:http/http.dart' as http;
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/network_fast_route_store.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/policy_download_transport.dart';
import 'package:parfait/core/network/compat/route_kind_store.dart';
import 'package:parfait/core/network/compat/secure_resolver.dart';
import 'package:parfait/core/network/rhttp_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _HandshakeFailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw const NetworkFailureException(NetworkFailureKind.tlsHandshake);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'every native Pixiv exit shares the policy and strict tiers are first',
    () async {
      final resolver = FakeResolver([InternetAddress('1.2.3.4')]);
      final store = PixivFastRouteStore(preferences: SharedPreferencesAsync());
      final clients = <String, RecordingClient>{};
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        fastRouteStore: store,
        bootstrapNoSniEnabled: true,
        clientFactory: (route, host, purpose) =>
            clients.putIfAbsent('${purpose.name}|$host', RecordingClient.new),
      );
      final factory = PixivNetworkFactory(policy);

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
      // host resolves once through DoH. Pixiv image hosts do not race, so
      // no host resolves twice.
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

  test('image host addresses survive a restart; other hosts drop', () async {
    final preferences = SharedPreferencesAsync();
    // Older versions stored the Cloudflare answer DoH gave for the API.
    await preferences.setString(
      PixivFastRouteStore.storageKey,
      jsonEncode({'i.pximg.net': '1.2.3.44', 'app-api.pixiv.net': '1.2.3.45'}),
    );
    final store = PixivFastRouteStore(preferences: preferences);

    expect((await store.addressFor('i.pximg.net'))?.address, '1.2.3.44');
    expect((await store.addressFor('s.pximg.net'))?.address, '210.140.139.133');
    expect(await store.addressFor('app-api.pixiv.net'), isNull);
  });

  test('policy warmup creates only the two image pools', () async {
    final created = <({NetworkRoute route, String host})>[];
    final policy = NetworkAccessPolicy(
      fastRouteStore: PixivFastRouteStore(
        preferences: SharedPreferencesAsync(),
      ),
      bootstrapNoSniEnabled: true,
      clientFactory: (route, host, _) {
        created.add((route: route, host: host));
        return RecordingClient();
      },
    );
    addTearDown(policy.dispose);

    await policy.warmUp();

    expect(created.map((entry) => entry.host), ['i.pximg.net', 's.pximg.net']);
    expect(
      created.map((entry) => entry.route.kind),
      everyElement(NetworkRouteKind.bootstrapNoSni),
    );
  });

  test('a warm-up the native transport fails completes quietly', () async {
    // The app starts the warm-up unawaited; requests meet the failure.
    final ready = RhttpGate.ready;
    RhttpGate.ready = Future<void>.error(StateError('rhttp did not load'))
      ..ignore();
    addTearDown(() => RhttpGate.ready = ready);
    final policy = NetworkAccessPolicy(
      fastRouteStore: PixivFastRouteStore(
        preferences: SharedPreferencesAsync(),
      ),
      clientFactory: (_, _, _) => RecordingClient(),
    );
    addTearDown(policy.dispose);

    await PixivNetworkFactory(policy).warmUp();
  });

  test('a failed fast address is cooled before the next request', () async {
    var now = DateTime.utc(2026, 9, 3);
    final policy = NetworkAccessPolicy(
      resolver: StaticSecureResolver(addresses: [InternetAddress('1.2.3.4')]),
      fastRouteStore: PixivFastRouteStore(
        preferences: SharedPreferencesAsync(),
      ),
      bootstrapNoSniEnabled: true,
      clock: () => now,
    );
    addTearDown(policy.dispose);
    final attempted = <NetworkRouteKind>[];

    Future<void> run() => _failEveryTier(
      policy,
      'https://i.pximg.net/img-master/a.jpg',
      PixivDestinationPurpose.image,
      attempted,
    );

    await run();
    expect(attempted.last, NetworkRouteKind.bootstrapNoSni);

    attempted.clear();
    await run();
    expect(
      attempted,
      isNot(contains(NetworkRouteKind.bootstrapNoSni)),
      reason: 'the cooled fast address must not be tried again',
    );

    now = now.add(const Duration(seconds: 31));
    attempted.clear();
    await run();
    expect(attempted, contains(NetworkRouteKind.bootstrapNoSni));
  });

  test('API, OAuth and web never reach the bootstrap tier', () async {
    final routeKinds = RouteKindStore(preferences: SharedPreferencesAsync());
    // Older versions could persist the tier as the API group's preference
    // after pixiv's origin answered 403.
    await routeKinds.remember('initial', 'cloudflare', 'bootstrapNoSni');
    final policy = NetworkAccessPolicy(
      resolver: StaticSecureResolver(addresses: [InternetAddress('1.2.3.4')]),
      fastRouteStore: PixivFastRouteStore(
        preferences: SharedPreferencesAsync(),
      ),
      routeKindStore: routeKinds,
      bootstrapNoSniEnabled: true,
      clientFactory: (_, _, _) => RecordingClient(),
    );
    addTearDown(policy.dispose);
    await policy.warmUp();
    await pumpEventQueue();
    expect(
      policy.rememberedGroupRouteKind(
        PixivDestinationPurpose.appApi,
        'app-api.pixiv.net',
      ),
      isNull,
      reason: 'a persisted bootstrap preference is dropped on seeding',
    );

    for (final (url, purpose) in [
      ('https://app-api.pixiv.net/v1/ping', PixivDestinationPurpose.appApi),
      (
        'https://oauth.secure.pixiv.net/auth/token',
        PixivDestinationPurpose.oauth,
      ),
      ('https://www.pixiv.net/ajax/user/11', PixivDestinationPurpose.pixivWeb),
      ('https://accounts.pixiv.net/login', PixivDestinationPurpose.accountsWeb),
    ]) {
      final attempted = <NetworkRouteKind>[];
      await _failEveryTier(policy, url, purpose, attempted);
      expect(attempted, isNotEmpty, reason: url);
      expect(
        attempted,
        isNot(contains(NetworkRouteKind.bootstrapNoSni)),
        reason: url,
      );
    }
  });

  test('only a noSni success teaches the bootstrap tier an address', () async {
    final store = PixivFastRouteStore(preferences: SharedPreferencesAsync());

    Future<void> fetch(String resolved, {required bool noSniWorks}) async {
      final policy = NetworkAccessPolicy(
        resolver: StaticSecureResolver(addresses: [InternetAddress(resolved)]),
        fastRouteStore: store,
        bootstrapNoSniEnabled: true,
        clientFactory: (route, _, _) =>
            route.kind == NetworkRouteKind.noSni && !noSniWorks
            ? _HandshakeFailingClient()
            : RecordingClient(),
      );
      addTearDown(policy.dispose);
      await PixivNetworkFactory(policy)
          .client(PixivDestinationPurpose.image)
          .get(Uri.parse('https://i.pximg.net/img-master/a.jpg'));
      await pumpEventQueue();
    }

    await fetch('1.2.3.4', noSniWorks: true);
    expect((await store.addressFor('i.pximg.net'))?.address, '1.2.3.4');

    await fetch('1.2.3.5', noSniWorks: false);
    expect(
      (await store.addressFor('i.pximg.net'))?.address,
      '1.2.3.4',
      reason: 'a DoH answer that failed the empty-SNI handshake is not stored',
    );
  });
}

/// Runs [url] through [policy]'s ladder with every attempt refused,
/// recording the kinds it tried.
Future<void> _failEveryTier(
  NetworkAccessPolicy policy,
  String url,
  PixivDestinationPurpose purpose,
  List<NetworkRouteKind> attempted,
) => expectLater(
  policy.runLadder<void>(
    destination: policy.registry.require(Uri.parse(url), purpose),
    cancelSignal: null,
    canReplay: false,
    attempt: (route, _) async {
      attempted.add(route.kind);
      throw const NetworkFailureException(NetworkFailureKind.connect);
    },
  ),
  throwsA(isA<NetworkFailureException>()),
);
