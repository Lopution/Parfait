import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/test_preferences.dart';

import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/network/compat/auto_image_source.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/policy_download_transport.dart';
import 'package:parfait/core/network/compat/route_kind_store.dart';
import 'package:parfait/core/settings/image_mirror.dart';

import 'helpers/restricted_compat_support.dart';

void main() {
  installMemoryPreferences();

  TestWidgetsFlutterBinding.ensureInitialized();

  group('image mirror integration', () {
    test('extra image hosts gain image trust and nothing else', () {
      final registry = PixivDestinationRegistry(
        extraImageHosts: {'i.pixiv.cat', 's.pixiv.cat'},
      );

      expect(
        registry
            .require(
              Uri.parse('https://i.pixiv.cat/img-original/img/1_p0.jpg'),
              PixivDestinationPurpose.image,
            )
            .canonicalHost,
        'i.pixiv.cat',
      );
      for (final purpose in [
        PixivDestinationPurpose.appApi,
        PixivDestinationPurpose.oauth,
        PixivDestinationPurpose.accountsWeb,
        PixivDestinationPurpose.pixivWeb,
      ]) {
        expect(
          () =>
              registry.require(Uri.parse('https://i.pixiv.cat/v1/x'), purpose),
          throwsA(isA<PixivDestinationException>()),
          reason: 'a mirror host must never become a $purpose target',
        );
      }
      expect(
        () => registry.require(
          Uri.parse('https://unregistered.example.com/a.jpg'),
          PixivDestinationPurpose.image,
        ),
        throwsA(isA<PixivDestinationException>()),
      );
    });

    test(
      'the image client rewrites to the mirror before destination resolution',
      () async {
        final mirror = ImageMirror.of('i.pixiv.cat');
        final direct = FakeClient(
          failure: SocketException('Connection refused'),
        );
        final ech = FakeClient(body: 'must-not-send');
        final secure = FakeClient(body: '{"ok":true}');
        final resolver = FakeEchResolver(
          [InternetAddress('1.2.3.60')],
          frontAddresses: [InternetAddress('1.2.3.61')],
        );
        final policy = NetworkAccessPolicy(
          registry: PixivDestinationRegistry(
            extraImageHosts: mirror.extraHosts,
          ),
          resolver: resolver,
          clientFactory: (route, canonicalHost, _) => switch (route.kind) {
            NetworkRouteKind.direct => direct,
            NetworkRouteKind.ech => ech,
            _ => secure,
          },
        );
        addTearDown(policy.dispose);
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
          urlRewriter: mirror.rewrite,
        );

        final response = await client.get(
          Uri.parse('https://i.pximg.net/img-original/img/1_p0.jpg?x=1'),
          headers: const {'Referer': 'https://www.pixiv.net/'},
        );

        expect(response.statusCode, 200);
        expect(
          resolver.echCalls,
          0,
          reason: 'a third-party mirror never enters the Pixiv ECH tier',
        );
        expect(ech.requests, isEmpty);
        expect(direct.requests, isEmpty);
        // A cold mirror races its own top two tiers (noSni + dohRealSni);
        // both requests retarget to the mirror host.
        expect(secure.requests, hasLength(2));
        for (final request in secure.requests) {
          expect(request.url.host, 'i.pixiv.cat');
        }
        final sent = secure.requests.first;
        expect(sent.url.host, 'i.pixiv.cat');
        expect(sent.url.path, '/img-original/img/1_p0.jpg');
        expect(sent.url.query, 'x=1');
        expect(sent.headers['Referer'], 'https://www.pixiv.net/');
        expect(policy.hasStrictRouteMemory('i.pixiv.cat'), isTrue);
      },
    );

    test('the factory only rewrites image-purpose requests', () async {
      final mirror = ImageMirror.of('i.pixiv.cat');
      final backend = FakeClient(body: '{}');
      final policy = NetworkAccessPolicy(
        registry: PixivDestinationRegistry(extraImageHosts: mirror.extraHosts),
        resolver: FakeResolver([InternetAddress('1.2.3.62')]),
        clientFactory: (route, canonicalHost, _) => backend,
      );
      addTearDown(policy.dispose);
      final factory = PixivNetworkFactory(
        policy,
        imageUrlRewriter: mirror.rewrite,
      );

      await factory.apiClient.get(
        Uri.parse('https://app-api.pixiv.net/v1/illust/recommended'),
      );
      expect(backend.requests.single.url.host, 'app-api.pixiv.net');

      await factory
          .client(PixivDestinationPurpose.image)
          .get(Uri.parse('https://s.pximg.net/avatar/u/1.jpg'));
      expect(backend.requests.last.url.host, 's.pixiv.cat');
    });

    test('a rewritten host missing from the registry fails loudly', () async {
      final policy = NetworkAccessPolicy(
        clientFactory: (_, _, _) => FakeClient(),
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
        urlRewriter: ImageMirror.of('i.pixiv.cat').rewrite,
      );

      await expectLater(
        client.get(Uri.parse('https://i.pximg.net/a.jpg')),
        throwsA(isA<PixivDestinationException>()),
      );
    });

    test(
      'downloads follow the mirror and keep the rewritten prefix path',
      () async {
        final mirror = ImageMirror.of('https://proxy.example.com/pixiv');
        final backend = FakeClient(body: 'bytes');
        final policy = NetworkAccessPolicy(
          registry: PixivDestinationRegistry(
            extraImageHosts: mirror.extraHosts,
          ),
          resolver: FakeResolver([InternetAddress('1.2.3.63')]),
          clientFactory: (route, canonicalHost, _) => backend,
        );
        final transport = PolicyDownloadTransport(
          policy: policy,
          imageMirror: mirror,
        );
        addTearDown(() async {
          await transport.dispose();
          await policy.dispose();
        });

        final response = await transport.open(
          Uri.parse('https://i.pximg.net/img-original/img/2_p0.jpg'),
          headers: const {},
          cancelToken: DownloadCancelToken(),
        );
        await response.stream.drain<void>();
        await response.close();

        final sent = backend.requests.single;
        expect(sent.url.host, 'proxy.example.com');
        expect(sent.url.path, '/pixiv/img-original/img/2_p0.jpg');
      },
    );

    test('pximg route memory never leaks onto a mirror host', () async {
      final resolver = FakeEchResolver(
        [InternetAddress('1.2.3.64')],
        frontAddresses: [InternetAddress('1.2.3.67')],
      );
      final policy = NetworkAccessPolicy(
        registry: PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'}),
        resolver: resolver,
        clientFactory: (route, canonicalHost, _) => switch (route.kind) {
          NetworkRouteKind.ech ||
          NetworkRouteKind.noSni => FakeClient(body: 'ok'),
          _ => FakeClient(failure: SocketException('Connection refused')),
        },
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );

      await client.get(Uri.parse('https://i.pximg.net/a.jpg'));
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pximg.net',
        ),
        NetworkRouteKind.ech,
        reason: 'pximg remembers its own ECH success',
      );
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pixiv.re',
        ),
        isNull,
        reason:
            'the pximg preference must not seed the mirror group — the ECH '
            'config only covers pixiv hosts',
      );

      // The mirror still tries its own noSni tier first (its fallback
      // ordering), and that success seeds the *mirror* group instead.
      await client.get(Uri.parse('https://i.pixiv.re/a.jpg'));
      expect(policy.rememberedRouteKind('i.pixiv.re'), NetworkRouteKind.noSni);
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pixiv.re',
        ),
        NetworkRouteKind.noSni,
      );
    });

    test(
      'a mirror empty-SNI certificate mismatch falls through to real SNI',
      () async {
        final certError = rhttp.RhttpInvalidCertificateException(
          request: rhttp.HttpRequest(
            method: rhttp.HttpMethod.get,
            url: 'https://i.pixiv.re/a.jpg',
          ),
          message: 'default vhost certificate does not match i.pixiv.re',
        );
        final attempts = <NetworkRouteKind>[];
        final policy = NetworkAccessPolicy(
          registry: PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'}),
          resolver: FakeResolver([InternetAddress('1.2.3.65')]),
          clientFactory: (route, canonicalHost, _) {
            attempts.add(route.kind);
            return route.kind == NetworkRouteKind.noSni
                ? FakeClient(failure: certError)
                : FakeClient(body: 'ok');
          },
        );
        addTearDown(policy.dispose);
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );

        final response = await client.get(
          Uri.parse('https://i.pixiv.re/a.jpg'),
        );
        expect(response.statusCode, 200);
        expect(attempts, [
          NetworkRouteKind.noSni,
          NetworkRouteKind.dohRealSni,
        ], reason: 'empty-SNI cert failure advances instead of aborting');
        expect(
          policy.rememberedRouteKind('i.pixiv.re'),
          NetworkRouteKind.dohRealSni,
        );
      },
    );

    test('a real-SNI certificate mismatch stays terminal', () async {
      final certError = rhttp.RhttpInvalidCertificateException(
        request: rhttp.HttpRequest(
          method: rhttp.HttpMethod.get,
          url: 'https://i.pixiv.re/a.jpg',
        ),
        message: 'hostname mismatch',
      );
      final attempts = <NetworkRouteKind>[];
      final policy = NetworkAccessPolicy(
        registry: PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'}),
        resolver: FakeResolver([InternetAddress('1.2.3.66')]),
        clientFactory: (route, canonicalHost, _) {
          attempts.add(route.kind);
          return route.kind == NetworkRouteKind.noSni
              ? FakeClient(failure: SocketException('Connection refused'))
              : FakeClient(failure: certError);
        },
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );

      await expectLater(
        client.get(Uri.parse('https://i.pixiv.re/a.jpg')),
        throwsA(same(certError)),
      );
      expect(attempts, [
        NetworkRouteKind.noSni,
        NetworkRouteKind.dohRealSni,
      ], reason: 'a real-SNI mismatch never falls through to direct');
    });
  });

  group('stream idle guard', () {
    test('send() surfaces a headers timeout for image clients', () async {
      final policy = NetworkAccessPolicy(
        imageHeadersTimeout: const Duration(milliseconds: 50),
        clientFactory: (_, _, _) => NeverSendClient(),
      );
      addTearDown(policy.dispose);
      final client = policy.clientFor(
        PixivDestinationPurpose.image,
        NetworkRoute.direct(policy.revision),
        'i.pximg.net',
      );

      await expectLater(
        client.get(Uri.parse('https://i.pximg.net/a.jpg')),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('the response body errors after an idle gap', () async {
      final policy = NetworkAccessPolicy(
        imageIdleTimeout: const Duration(milliseconds: 50),
        clientFactory: (_, _, _) => StallClient(),
      );
      addTearDown(policy.dispose);
      final client = policy.clientFor(
        PixivDestinationPurpose.image,
        NetworkRoute.direct(policy.revision),
        'i.pximg.net',
      );

      final response = await client.send(
        http.Request('GET', Uri.parse('https://i.pximg.net/a.jpg')),
      );
      await expectLater(
        response.stream.toList(),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  // Racing is for mirrors only; pixiv's own image hosts stay serial on ECH
  // (see the 'pixiv image hosts stay on ECH' group).
  group('cold-start image racing', () {
    final imageUri = Uri.parse('https://i.pixiv.re/img-master/img/x_p0.jpg');
    PixivDestinationRegistry mirrorRegistry() =>
        PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'});

    test(
      'a cold mirror GET races the top two tiers and keeps the winner',
      () async {
        final noSni = FakeClient(body: 'noSni');
        final realSni = DelayedClient(
          FakeClient(body: 'realSni'),
          const Duration(milliseconds: 200),
        );
        final policy = NetworkAccessPolicy(
          registry: mirrorRegistry(),
          resolver: FakeResolver([InternetAddress('1.2.3.4')]),
          clientFactory: (route, _, _) => switch (route.kind) {
            NetworkRouteKind.noSni => noSni,
            _ => realSni,
          },
        );
        addTearDown(policy.dispose);
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );

        final response = await client.get(imageUri);

        expect(response.statusCode, 200);
        // Both top tiers were attempted in parallel.
        expect(noSni.requests, hasLength(1));
        expect(realSni.requests, hasLength(1));
        // The faster tier won and is remembered for the next request.
        expect(
          policy.rememberedRouteKind('i.pixiv.re'),
          NetworkRouteKind.noSni,
        );
      },
    );

    test(
      'a warm host does not race — the remembered route is used alone',
      () async {
        final client = FakeClient(body: 'ok');
        final policy = NetworkAccessPolicy(
          registry: mirrorRegistry(),
          resolver: FakeResolver([InternetAddress('1.2.3.4')]),
          clientFactory: (_, _, _) => client,
        );
        addTearDown(policy.dispose);
        final httpClient = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );

        await httpClient.get(imageUri);
        await httpClient.get(imageUri);

        // Cold first request raced two tiers; the second request goes
        // straight to the remembered route — one send each leg.
        expect(client.requests, hasLength(3));
        expect(policy.rememberedRouteKind('i.pixiv.re'), isNotNull);
      },
    );

    test('a cold API GET stays serial — racing is image-only', () async {
      final client = FakeClient(body: 'ok');
      final policy = NetworkAccessPolicy(
        resolver: FakeResolver([InternetAddress('1.2.3.4')]),
        clientFactory: (_, _, _) => client,
      );
      addTearDown(policy.dispose);
      final httpClient = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );

      await httpClient.get(apiUri);

      // The strict tier answered; no second tier was sent in parallel.
      expect(client.requests, hasLength(1));
    });

    test('both raced tiers failing falls back to the serial ladder', () async {
      final failing = FakeClient(failure: const SocketException('refused'));
      final direct = FakeClient(body: 'direct');
      final policy = NetworkAccessPolicy(
        registry: mirrorRegistry(),
        resolver: FakeResolver([InternetAddress('1.2.3.4')]),
        clientFactory: (route, _, _) =>
            route.kind == NetworkRouteKind.direct ? direct : failing,
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );

      final response = await client.get(imageUri);

      expect(response.statusCode, 200);
      expect(failing.requests, hasLength(2));
      expect(direct.requests, hasLength(1));
      expect(policy.rememberedRouteKind('i.pixiv.re'), NetworkRouteKind.direct);
    });

    test(
      'a persisted route kind seeds the group preference on warm-up',
      () async {
        SharedPreferencesAsyncPlatform.instance = memoryPreferences();
        final preferences = SharedPreferencesAsync();
        final store = RouteKindStore(preferences: preferences);
        // A previous session learned that dohRealSni works for mirrors.
        await store.remember('initial', 'imageMirror', 'dohRealSni');

        final noSni = FakeClient(failure: const SocketException('refused'));
        final realSni = FakeClient(body: 'realSni');
        final policy = NetworkAccessPolicy(
          registry: mirrorRegistry(),
          resolver: FakeResolver([InternetAddress('1.2.3.4')]),
          routeKindStore: store,
          clientFactory: (route, _, _) => switch (route.kind) {
            NetworkRouteKind.noSni => noSni,
            _ => realSni,
          },
        );
        addTearDown(policy.dispose);
        await policy.warmUp();
        // warmUp's seeding is fire-and-forget; let it land before racing.
        await Future<void>.delayed(Duration.zero);

        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );
        final response = await client.get(imageUri);

        expect(response.statusCode, 200);
        // The seeded preference made dohRealSni the first tier — noSni was
        // never raced because a group preference exists (not cold).
        expect(noSni.requests, isEmpty);
        expect(realSni.requests, hasLength(1));
      },
    );
  });

  group('pixiv image hosts stay on ECH', () {
    final imageUri = Uri.parse('https://i.pximg.net/img-master/img/x_p0.jpg');
    late List<NetworkRouteKind> attempts;
    late Set<NetworkRouteKind> down;
    late DateTime now;

    setUp(() {
      attempts = [];
      down = {};
      now = DateTime(2026, 10, 3, 12);
    });

    NetworkAccessPolicy ladderPolicy({
      RouteKindStore? store,
      PixivDestinationRegistry? registry,
    }) {
      final policy = NetworkAccessPolicy(
        registry: registry,
        resolver: FakeEchResolver(
          [InternetAddress('1.2.3.80')],
          frontAddresses: [InternetAddress('1.2.3.81')],
        ),
        routeKindStore: store,
        clock: () => now,
        clientFactory: (route, _, _) => KindClient(route.kind, attempts, down),
      );
      addTearDown(policy.dispose);
      return policy;
    }

    /// One image GET; returns the route kinds it was sent on, in order.
    Future<List<NetworkRouteKind>> fetch(NetworkAccessPolicy policy) async {
      attempts.clear();
      final response = await PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      ).get(imageUri);
      expect(response.statusCode, 200);
      return List.of(attempts);
    }

    Future<void> coolEch(NetworkAccessPolicy policy) async {
      down.add(NetworkRouteKind.ech);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);
      expect(await fetch(policy), [
        NetworkRouteKind.noSni,
      ], reason: 'two failures in a row cool ECH down');
    }

    test('a cold GET goes to ECH alone instead of racing', () async {
      final policy = ladderPolicy();

      expect(await fetch(policy), [NetworkRouteKind.ech]);
      expect(policy.rememberedRouteKind('i.pximg.net'), NetworkRouteKind.ech);
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pximg.net',
        ),
        NetworkRouteKind.ech,
      );
    });

    test('one ECH failure only moves that request', () async {
      final policy = ladderPolicy();
      down.add(NetworkRouteKind.ech);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);

      down.clear();
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
      ], reason: 'the remembered origin route gives way to ECH');
      expect(policy.rememberedRouteKind('i.pximg.net'), NetworkRouteKind.ech);
    });

    test('the cooldown doubles after every failed retry, capped', () async {
      final policy = ladderPolicy();
      await coolEch(policy);

      var cooldown = const Duration(minutes: 1);
      for (final next in const [2, 4, 8, 10, 10]) {
        now = now.add(cooldown - const Duration(seconds: 1));
        expect(await fetch(policy), [
          NetworkRouteKind.noSni,
        ], reason: 'still cooling within $cooldown');
        now = now.add(const Duration(seconds: 1));
        expect(await fetch(policy), [
          NetworkRouteKind.ech,
          NetworkRouteKind.noSni,
        ], reason: 'ECH is retried once $cooldown has passed');
        cooldown = Duration(minutes: next);
      }
    });

    test('an ECH success clears the failure count', () async {
      final policy = ladderPolicy();
      await coolEch(policy);

      now = now.add(const Duration(minutes: 1));
      down.clear();
      expect(await fetch(policy), [NetworkRouteKind.ech]);

      down.add(NetworkRouteKind.ech);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ], reason: 'one failure after a success does not cool ECH yet');
    });

    test('a cooling ECH tier is still the last resort', () async {
      final policy = ladderPolicy();
      await coolEch(policy);

      down
        ..clear()
        ..addAll({
          NetworkRouteKind.noSni,
          NetworkRouteKind.dohRealSni,
          NetworkRouteKind.direct,
        });
      expect(await fetch(policy), [
        NetworkRouteKind.noSni,
        NetworkRouteKind.dohRealSni,
        NetworkRouteKind.direct,
        NetworkRouteKind.ech,
      ]);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
      ], reason: 'that ECH success ended the cooldown');
    });

    test('a network change forgets the cooldown', () async {
      final policy = ladderPolicy();
      await coolEch(policy);

      down.clear();
      policy.advanceNetworkRevision(networkIdentity: 'cellular');
      expect(await fetch(policy), [NetworkRouteKind.ech]);
    });

    test('origin-tier successes are neither shared nor persisted', () async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final policy = ladderPolicy(
        store: RouteKindStore(preferences: SharedPreferencesAsync()),
      );
      Future<String?> persistedImageKind() async {
        // Writes are fire-and-forget; read back through a fresh store.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final reloaded = RouteKindStore(preferences: SharedPreferencesAsync());
        return (await reloaded.kindsFor('initial'))?['image'];
      }

      down.add(NetworkRouteKind.ech);
      expect(await fetch(policy), [
        NetworkRouteKind.ech,
        NetworkRouteKind.noSni,
      ]);
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pximg.net',
        ),
        isNull,
      );
      // Selecting ECH may already have stored it; the origin tier that
      // actually carried the request must not replace it.
      expect(await persistedImageKind(), isNot('noSni'));

      down.clear();
      expect(await fetch(policy), [NetworkRouteKind.ech]);
      expect(await persistedImageKind(), 'ech');
    });

    test('a persisted origin-tier image preference is ignored', () async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final store = RouteKindStore(preferences: SharedPreferencesAsync());
      // Written by a version that let the origin tier win the race.
      await store.remember('initial', 'image', 'noSni');
      await store.remember('initial', 'imageMirror', 'dohRealSni');
      final policy = ladderPolicy(
        store: store,
        registry: PixivDestinationRegistry(extraImageHosts: {'i.pixiv.re'}),
      );
      await policy.warmUp();
      await Future<void>.delayed(Duration.zero);

      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pximg.net',
        ),
        isNull,
      );
      expect(
        policy.rememberedGroupRouteKind(
          PixivDestinationPurpose.image,
          'i.pixiv.re',
        ),
        NetworkRouteKind.dohRealSni,
        reason: 'mirror preferences are still honored',
      );
      expect(await fetch(policy), [NetworkRouteKind.ech]);
    });
  });

  group('auto image source', () {
    NetworkAccessPolicy autoPolicy(
      http.Client Function(String host) clientFor,
    ) {
      return NetworkAccessPolicy(
        registry: PixivDestinationRegistry(
          extraImageHosts: Set<String>.of(ImageMirror.autoCandidates),
        ),
        resolver: FakeResolver([InternetAddress('1.2.3.62')]),
        clientFactory: (route, canonicalHost, purpose) =>
            clientFor(canonicalHost),
      );
    }

    test('the winner persists scoped to the network identity', () async {
      installMemoryPreferences();
      final source = AutoImageSource(preferences: SharedPreferencesAsync());
      await source.remember('wifi', 'i.pixiv.re');

      expect(await source.winnerFor('wifi'), 'i.pixiv.re');
      expect(await source.winnerFor('cellular'), isNull);
      // A fresh instance reads the same store — the winner survives a
      // cold start.
      final reloaded = AutoImageSource(preferences: SharedPreferencesAsync());
      expect(await reloaded.winnerFor('wifi'), 'i.pixiv.re');
    });

    test('race picks the fastest transfer, not the first response', () async {
      final big = List.filled(32 * 1024, 7);
      final policy = autoPolicy(
        (host) => switch (host) {
          // Direct answers fast but its body arrives after a delay — a
          // TTFB race would crown it; throughput ranking must not.
          'i.pximg.net' => DelayedClient(
            FakeClient(body: utf8.decode(big)),
            const Duration(milliseconds: 300),
          ),
          'i.pixiv.re' => FakeClient(body: utf8.decode(big)),
          _ => FakeClient(failure: const SocketException('refused')),
        },
      );
      addTearDown(policy.dispose);

      final result = await AutoImageSource.race(policy);
      expect(result?.host, 'i.pixiv.re');
      expect(result?.bps, isNotNull);
    });

    test(
      'race falls back to the first reachable host without a body',
      () async {
        final policy = autoPolicy(
          (host) => switch (host) {
            'i.pixiv.re' => FakeClient(body: '{}'), // reachable, unmeasurable
            _ => FakeClient(failure: const SocketException('refused')),
          },
        );
        addTearDown(policy.dispose);

        final result = await AutoImageSource.race(policy);
        expect(result?.host, 'i.pixiv.re');
        expect(result?.bps, isNull);
      },
    );

    test('race returns null when every candidate fails', () async {
      final policy = autoPolicy(
        (_) => FakeClient(failure: const SocketException('refused')),
      );
      addTearDown(policy.dispose);

      expect(await AutoImageSource.race(policy), isNull);
    });

    test('a body cut off by the deadline ranks on what it delivered', () async {
      final policy = autoPolicy(
        (host) => switch (host) {
          // Throttled: 40 KB arrive, the rest not before the deadline.
          'i.pximg.net' => StallClient(40 * 1024),
          // Answered, but too little data to measure.
          'i.pixiv.re' => StallClient(1024),
          _ => FakeClient(failure: const SocketException('refused')),
        },
      );
      addTearDown(policy.dispose);

      final result = await AutoImageSource.race(
        policy,
        timeout: const Duration(milliseconds: 300),
      );
      expect(result?.host, 'i.pximg.net');
      expect(result?.bps, isNotNull);
    });

    test('a probe cut off below the measurable minimum loses', () async {
      final policy = autoPolicy(
        (host) => host == 'i.pixiv.re'
            ? StallClient(1024)
            : FakeClient(failure: const SocketException('refused')),
      );
      addTearDown(policy.dispose);

      expect(
        await AutoImageSource.race(
          policy,
          timeout: const Duration(milliseconds: 300),
        ),
        isNull,
        reason: 'headers alone do not make a usable source',
      );
    });

    test(
      'a mirror host exhausting its ladder reports onImageHostExhausted',
      () async {
        final exhausted = <String>[];
        final policy = autoPolicy(
          (_) => FakeClient(failure: const SocketException('refused')),
        );
        policy.onImageHostExhausted = exhausted.add;
        addTearDown(policy.dispose);
        final client = PixivPolicyHttpClient(
          policy: policy,
          purpose: PixivDestinationPurpose.image,
        );

        await expectLater(
          client.get(Uri.parse('https://i.pixiv.re/img/a.jpg')),
          throwsA(anything),
        );
        expect(exhausted, ['i.pixiv.re']);
      },
    );

    test('canonical pximg hosts never trigger onImageHostExhausted', () async {
      final exhausted = <String>[];
      final policy = autoPolicy(
        (_) => FakeClient(failure: const SocketException('refused')),
      );
      policy.onImageHostExhausted = exhausted.add;
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );

      await expectLater(
        client.get(Uri.parse('https://i.pximg.net/img/a.jpg')),
        throwsA(anything),
      );
      expect(exhausted, isEmpty);
    });
  });

  group('network modes', () {
    Future<List<NetworkRouteKind>> runExhaustingLadder(NetworkMode mode) async {
      final order = <NetworkRouteKind>[];
      final policy = NetworkAccessPolicy(
        resolver: FakeResolver([InternetAddress('1.2.3.70')]),
        insecureNoSniEnabled: true,
        mode: mode,
        clientFactory: (route, canonicalHost, purpose) {
          order.add(route.kind);
          return FakeClient(failure: const SocketException('refused'));
        },
      );
      addTearDown(policy.dispose);
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.appApi,
      );
      await expectLater(
        client.get(Uri.parse('https://app-api.pixiv.net/v1/ping')),
        throwsA(anything),
      );
      return order;
    }

    test('automatic keeps direct ahead of the insecure bootstrap', () async {
      final order = await runExhaustingLadder(NetworkMode.automatic);
      // ECH yields no route without an ECH-capable resolver, so the
      // observable ladder is DoH → direct → insecure bootstrap.
      expect(order, [
        NetworkRouteKind.dohRealSni,
        NetworkRouteKind.direct,
        NetworkRouteKind.insecureNoSni,
      ]);
    });

    test('compatPrefer walks every compat tier before direct', () async {
      final order = await runExhaustingLadder(NetworkMode.compatPrefer);
      expect(order, [
        NetworkRouteKind.dohRealSni,
        NetworkRouteKind.insecureNoSni,
        NetworkRouteKind.direct,
      ]);
    });

    test('effectiveRouteSnapshot reports settled per-host kinds', () async {
      final policy = NetworkAccessPolicy(
        resolver: FakeResolver([InternetAddress('1.2.3.71')]),
        clientFactory: (route, canonicalHost, purpose) =>
            FakeClient(body: '{}'),
      );
      addTearDown(policy.dispose);
      expect(policy.effectiveRouteSnapshot(), isEmpty);

      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );
      await client.get(Uri.parse('https://i.pximg.net/img/a.jpg'));

      final snapshot = policy.effectiveRouteSnapshot();
      expect(snapshot.keys, contains('i.pximg.net'));
      expect(snapshot['i.pximg.net'], isNotNull);
    });
  });
}
