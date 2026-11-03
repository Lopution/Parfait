import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/network/compat/auto_image_source.dart';
import 'package:parfait/core/network/compat/image_route_score_store.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/policy_download_transport.dart';
import 'package:parfait/core/network/compat/route_kind_store.dart';
import 'package:parfait/core/network/compat/route_memory.dart';
import 'package:parfait/core/settings/image_mirror.dart';

import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';

import 'helpers/restricted_compat_support.dart';
import 'helpers/test_preferences.dart';

/// An image client over [policy], which the test disposes.
PixivPolicyHttpClient _imageClient(NetworkAccessPolicy policy) {
  addTearDown(policy.dispose);
  return PixivPolicyHttpClient(
    policy: policy,
    purpose: PixivDestinationPurpose.image,
  );
}

void main() {
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
        // A cold mirror races its own top two tiers (direct + noSni); both
        // requests retarget to the mirror host.
        expect(direct.requests, hasLength(1));
        expect(secure.requests, hasLength(1));
        for (final request in [...direct.requests, ...secure.requests]) {
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
            return switch (route.kind) {
              NetworkRouteKind.direct => FakeClient(
                failure: const SocketException('Connection refused'),
              ),
              NetworkRouteKind.noSni => FakeClient(failure: certError),
              _ => FakeClient(body: 'ok'),
            };
          },
        );
        final client = _imageClient(policy);

        final response = await client.get(
          Uri.parse('https://i.pixiv.re/a.jpg'),
        );
        expect(response.statusCode, 200);
        expect(attempts, [
          NetworkRouteKind.direct,
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
          return switch (route.kind) {
            NetworkRouteKind.direct => FakeClient(failure: certError),
            NetworkRouteKind.noSni => FakeClient(
              failure: SocketException('Connection refused'),
            ),
            _ => FakeClient(body: 'must-not-send'),
          };
        },
      );
      final client = _imageClient(policy);

      await expectLater(
        client.get(Uri.parse('https://i.pixiv.re/a.jpg')),
        throwsA(same(certError)),
      );
      expect(attempts, [
        NetworkRouteKind.direct,
        NetworkRouteKind.noSni,
      ], reason: 'a real-SNI mismatch on direct never falls through');
    });
  });

  group('stream idle guard', () {
    // rhttp's transfer, and its socket, outlive an abandoned exchange until
    // the server sends again; only the request's abort ends them.
    Future<void> aborted(http.BaseRequest request) =>
        (request as http.Abortable).abortTrigger!.timeout(
          const Duration(seconds: 5),
        );

    test('send() surfaces a headers timeout for image clients, aborting '
        'the request', () async {
      final inner = NeverSendClient();
      final policy = NetworkAccessPolicy(
        imageHeadersTimeout: const Duration(milliseconds: 50),
        clientFactory: (_, _, _) => inner,
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
      await aborted(inner.requests.single);
    });

    // An image body from [inner], behind a 50 ms idle timeout.
    Future<Stream<List<int>>> guardedBody(http.Client inner) async {
      final policy = NetworkAccessPolicy(
        imageIdleTimeout: const Duration(milliseconds: 50),
        clientFactory: (_, _, _) => inner,
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
      return response.stream;
    }

    // An image body that stalls after its first bytes.
    Future<Stream<List<int>>> stalledBody([Object? error]) =>
        guardedBody(StallClient(1, error));

    for (final (name, read) in [
      ('toList', (Stream<List<int>> body) => body.toList()),
      ('drain', (Stream<List<int>> body) => body.drain<void>()),
    ]) {
      test('the response body errors after an idle gap: $name', () async {
        await expectLater(
          read(await stalledBody()),
          throwsA(isA<TimeoutException>()),
        );
      });
    }

    // rhttp's cancel waits for Rust's next event, and a `.map` under
    // `await for` (the worker's cache write) handed the idle timeout on
    // only once that cancel ended: stalled images failed 15–30 s late.
    test(
      'a mapped body errors after an idle gap though its cancel waits',
      () async {
        final rust = RustBodyClient();
        final body = (await guardedBody(rust)).map((chunk) => chunk);
        rust.port.add([1]);
        await expectLater(
          Future(() async {
            await for (final _ in body) {}
          }).timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError('the idle timeout was held'),
          ),
          throwsA(isA<TimeoutException>()),
        );
      },
    );

    for (final (name, abandon) in [
      (
        'it idles',
        (Stream<List<int>> body) =>
            body.drain<void>().then((_) {}, onError: (Object _) {}),
      ),
      (
        'its reader cancels',
        (Stream<List<int>> body) => body.listen(null).cancel(),
      ),
    ]) {
      test('an abandoned body aborts its request: $name', () async {
        final rust = RustBodyClient();
        final body = await guardedBody(rust);
        rust.port.add([1]);
        await abandon(body);
        await aborted(rust.requests.single);
      });
    }

    test('a body that errs and goes on still times out', () async {
      final errors = <Object>[];
      final timedOut = Completer<void>();
      (await stalledBody(StateError('blip'))).listen(
        null,
        onError: (Object error) {
          errors.add(error);
          if (error is TimeoutException) timedOut.complete();
        },
      );
      await timedOut.future;
      expect(errors, [isA<StateError>(), isA<TimeoutException>()]);
    });

    test('an idle timeout nobody handles reaches the zone', () async {
      final body = await stalledBody();
      final caught = Completer<Object>();
      runZonedGuarded(() => body.listen(null), (error, _) {
        caught.complete(error);
      });
      expect(await caught.future, isA<TimeoutException>());
    });

    // A stalled body that died after the idle timeout let it go ended the
    // image worker with the raw rhttp error.
    test('a body error after the idle timeout is dropped', () async {
      final rust = RustBodyClient();
      final received = <Object>[];
      final timedOut = Completer<void>();
      (await guardedBody(rust)).listen(
        received.add,
        onError: (Object error) {
          received.add(error);
          if (error is TimeoutException) timedOut.complete();
        },
      );
      rust.port.add([1]);
      await timedOut.future;
      expect(received, [
        [1],
        isA<TimeoutException>(),
      ]);
      rust.port.add('error decoding response body');
      await pumpEventQueue();
    });

    test('a cancel completes though the body errs after it', () async {
      final rust = RustBodyClient();
      final body = (await guardedBody(rust)).listen(null);
      rust.port.add([1]);
      await pumpEventQueue();
      final cancelled = body.cancel();
      rust.port.add('error decoding response body');
      await cancelled;
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
        final client = _imageClient(policy);

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
        final coldSends = client.requests.length;
        await httpClient.get(imageUri);

        // The second request goes straight to the remembered route.
        expect(client.requests, hasLength(coldSends + 1));
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
      final realSni = FakeClient(body: 'realSni');
      final policy = NetworkAccessPolicy(
        registry: mirrorRegistry(),
        resolver: FakeResolver([InternetAddress('1.2.3.4')]),
        clientFactory: (route, _, _) =>
            route.kind == NetworkRouteKind.dohRealSni ? realSni : failing,
      );
      final client = _imageClient(policy);

      final response = await client.get(imageUri);

      expect(response.statusCode, 200);
      expect(failing.requests, hasLength(2));
      expect(realSni.requests, hasLength(1));
      expect(
        policy.rememberedRouteKind('i.pixiv.re'),
        NetworkRouteKind.dohRealSni,
      );
    });

    test('a cold mirror answers from direct while DoH hangs', () async {
      for (final resolver in [
        FakeResolver([
          InternetAddress('1.2.3.4'),
        ], answered: Completer<void>().future),
        // Rejected as private: no DoH tier can be built.
        FakeResolver([InternetAddress('192.168.1.10')]),
      ]) {
        final sends = <NetworkRouteKind>[];
        final policy = NetworkAccessPolicy(
          registry: mirrorRegistry(),
          resolver: resolver,
          mode: NetworkMode.compatPrefer,
          // Slower than a failed lookup, so both race paths are taken.
          clientFactory: (route, _, _) => DelayedClient(
            KindClient(route.kind, sends, {}),
            const Duration(milliseconds: 20),
          ),
        );
        final client = _imageClient(policy);

        final response = await client.get(imageUri);

        expect(response.statusCode, 200);
        expect(sends, [NetworkRouteKind.direct]);
        expect(resolver.calls, 1, reason: 'the racing tier is still sought');
        expect(
          policy.rememberedRouteKind('i.pixiv.re'),
          NetworkRouteKind.direct,
        );
      }
    });

    test(
      'a persisted route kind seeds the group preference on warm-up',
      () async {
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
      final source = AutoImageSource(preferences: SharedPreferencesAsync());
      await source.remember('wifi', 'i.pixiv.re');

      expect(await source.winnerFor('wifi'), 'i.pixiv.re');
      expect(await source.winnerFor('cellular'), isNull);
      // A fresh instance reads the same store — the winner survives a
      // cold start.
      final reloaded = AutoImageSource(preferences: SharedPreferencesAsync());
      expect(await reloaded.winnerFor('wifi'), 'i.pixiv.re');
    });

    test('the next winner replaces a damaged record', () async {
      final preferences = SharedPreferencesAsync();
      await preferences.setString(AutoImageSource.storageKey, '{not json');
      final source = AutoImageSource(preferences: preferences);

      await source.remember('wifi', 'i.pixiv.re');

      expect(await source.winnerFor('wifi'), 'i.pixiv.re');
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

    test('only a mirror host exhausting its ladder reports '
        'onImageHostExhausted', () async {
      final exhausted = <String>[];
      final policy = autoPolicy(
        (_) => FakeClient(failure: const SocketException('refused')),
      );
      policy.onImageHostExhausted = exhausted.add;
      final client = _imageClient(policy);

      for (final host in ['i.pximg.net', 'i.pixiv.re']) {
        await expectLater(
          client.get(Uri.parse('https://$host/img/a.jpg')),
          throwsA(anything),
        );
      }
      expect(exhausted, ['i.pixiv.re']);
    });
  });

  group('network modes', () {
    /// The routes one pixiv image GET walks when every one is refused.
    Future<List<String>> runExhaustingLadder(NetworkMode mode) async {
      final order = <String>[];
      final policy = NetworkAccessPolicy(
        resolver: FakeEchResolver(
          [InternetAddress('1.2.3.70')],
          frontAddresses: [InternetAddress('1.2.3.81')],
        ),
        bootstrapNoSniEnabled: true,
        mode: mode,
        clientFactory: (route, canonicalHost, purpose) {
          order.add('${route.kind.name} ${route.address?.address ?? ''}');
          return FakeClient(failure: const SocketException('refused'));
        },
      );
      final client = _imageClient(policy);
      await expectLater(
        client.get(Uri.parse('https://i.pximg.net/img-master/img/x_p0.jpg')),
        throwsA(anything),
      );
      return order;
    }

    test('pixiv images walk their candidates, then dohRealSni and direct, '
        'in either mode', () async {
      for (final mode in [NetworkMode.automatic, NetworkMode.compatPrefer]) {
        expect(await runExhaustingLadder(mode), [
          'ech 1.2.3.81',
          'ech 162.159.152.4',
          'bootstrapNoSni 210.140.139.133',
          'dohRealSni 1.2.3.70',
          'direct ',
        ], reason: mode.name);
      }
    });

    group('pixiv image route scores', () {
      // An image body behind a 50 ms idle timeout on the front 1.2.3.81 or
      // the seed front; [sent] logs which one each GET went to.
      ({
        NetworkAccessPolicy policy,
        Future<Stream<List<int>>> Function({bool background}) get,
      })
      imageGets(
        List<String> sent, {
        ImageRouteScoreMemory? scores,
        String network = 'initial',
      }) {
        final policy = NetworkAccessPolicy(
          revision: NetworkRevision(0, networkIdentity: network),
          imageRouteScoreStore: scores,
          resolver: FakeEchResolver(
            [InternetAddress('1.2.3.80')],
            frontAddresses: [InternetAddress('1.2.3.81')],
          ),
          imageIdleTimeout: const Duration(milliseconds: 50),
          clientFactory: (route, _, _) =>
              RouteLogClient(route, sent, StallClient()),
        );
        final client = _imageClient(policy);
        final uri = Uri.parse('https://i.pximg.net/img-master/img/x_p0.jpg');
        return (
          policy: policy,
          get: ({bool background = false}) async => (await client.send(
            ImageRequest('GET', uri, background: background),
          )).stream,
        );
      }

      test('a stalled body counts against its route; one given up does '
          'not', () async {
        final sent = <String>[];
        final get = imageGets(sent).get;

        await (await get()).listen(null).cancel();
        await expectLater(
          (await get()).drain<void>(),
          throwsA(isA<TimeoutException>()),
        );
        await get();
        expect(sent, ['1.2.3.81', '1.2.3.81', '162.159.152.4']);
      });

      test('a prefetch may try another route; a visible load never', () async {
        final sent = <String>[];
        final get = imageGets(sent).get;

        await get(background: true);
        await get();
        expect(sent, ['162.159.152.4', '1.2.3.81']);
      });

      test('a network starts on the route that served it last time', () async {
        installPreferencesForTest(InMemorySharedPreferencesAsync.empty());
        final sent = <String>[];
        final store = ImageRouteScoreStore(
          preferences: SharedPreferencesAsync(),
        );
        await expectLater(
          (await imageGets(
            sent,
            scores: store,
            network: 'home',
          ).get()).drain<void>(),
          throwsA(isA<TimeoutException>()),
        );
        await store.flush();

        // The next start, at home and elsewhere; then elsewhere turns
        // into home.
        final restarted = ImageRouteScoreStore(
          preferences: SharedPreferencesAsync(),
        );
        final home = imageGets(sent, scores: restarted, network: 'home');
        final elsewhere = imageGets(sent, scores: restarted, network: 'cafe');
        await pumpEventQueue();
        await home.get();
        await elsewhere.get();
        elsewhere.policy.advanceNetworkRevision(networkIdentity: 'home');
        await pumpEventQueue();
        await elsewhere.get();
        expect(sent, [
          '1.2.3.81',
          '162.159.152.4',
          '1.2.3.81',
          '162.159.152.4',
        ]);
      });
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
        purpose: PixivDestinationPurpose.appApi,
      );
      await client.get(apiUri);

      final snapshot = policy.effectiveRouteSnapshot();
      expect(snapshot.keys, contains(apiUri.host));
      expect(snapshot[apiUri.host], isNotNull);
    });
  });
}
