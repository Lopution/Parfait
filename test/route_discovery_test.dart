import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parfait/core/image/image_worker_protocol.dart';
import 'package:parfait/core/image/worker_route_memory.dart';
import 'package:parfait/core/network/compat/front_discovery.dart';
import 'package:parfait/core/network/compat/image_route_discovery.dart';
import 'package:parfait/core/network/compat/image_route_score_store.dart';
import 'package:parfait/core/network/compat/image_route_scores.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/network_fast_route_store.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/origin_refresh.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/core/network/compat/proven_origins.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';

import 'helpers/restricted_compat_support.dart';
import 'helpers/test_preferences.dart';

/// A Cloudflare address at the network boundary: its trace names [colo]
/// (none: a trace without one), and an image answers [status] after
/// [headersAfter]. A [refused] address never connects. Aborts are
/// honoured, as rhttp does.
class _Front extends http.BaseClient {
  _Front({
    this.colo,
    this.status = 200,
    this.headersAfter = Duration.zero,
    this.refused = false,
  });

  final String? colo;
  final int status;
  final Duration headersAfter;
  final bool refused;
  final paths = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    if (refused) throw const SocketException('refused');
    if (request.url.path == '/cdn-cgi/trace') {
      final body = colo == null ? 'fl=1\n' : 'fl=1\ncolo=$colo\n';
      return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
    }
    final abort = request is http.Abortable ? request.abortTrigger : null;
    await Future.any([
      Future<void>.delayed(headersAfter),
      if (abort != null)
        abort.then<void>(
          (_) => throw http.RequestAbortedException(request.url),
        ),
    ]);
    return http.StreamedResponse(
      Stream.value(Uint8List(20 * 1024)),
      status,
      contentLength: 20 * 1024,
    );
  }
}

/// An origin whose image answers 200 and then breaks off mid-body.
class _BrokenBody extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(_body(), 200);

  static Stream<List<int>> _body() async* {
    yield Uint8List(1024);
    throw const SocketException('reset');
  }
}

/// An origin that answers [statuses] in turn, then 503.
class _Statuses extends http.BaseClient {
  _Statuses(this.statuses);

  final List<int> statuses;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.value(utf8.encode('jpg')),
        statuses.isEmpty ? 503 : statuses.removeAt(0),
      );
}

final _lax1 = InternetAddress('104.18.10.118');
final _lax2 = InternetAddress('104.18.11.118');
final _seed = ImageRouteDiscovery.seedFront;
final _thumbnail = Uri.parse('https://i.pximg.net/c/250x250/img-master/a.jpg');

ImageRouteScore _score(double cost, {double weight = 3, double failed = 0}) =>
    ImageRouteScore(
      cost: cost,
      weight: weight,
      failureShare: failed,
      at: DateTime(2026, 11, 4),
    );

void main() {
  test('the sample spreads over Cloudflare\'s prefixes by size', () {
    final prefixes = [
      for (final prefix in CloudflarePrefixes.all)
        (
          ByteData.sublistView(
            InternetAddress(prefix.split('/').first).rawAddress,
          ).getUint32(0),
          1 << (32 - int.parse(prefix.split('/').last)),
        ),
    ];
    int prefixOf(InternetAddress address) {
      final value = ByteData.sublistView(address.rawAddress).getUint32(0);
      return prefixes.indexWhere(
        (prefix) => value > prefix.$1 && value < prefix.$1 + prefix.$2 - 1,
      );
    }

    final eight = CloudflarePrefixes.sample(
      Random(1),
      8,
      exclude: {_seed.address},
    );
    expect(eight.map((a) => a.address).toSet(), hasLength(8));
    expect(eight.map(prefixOf), everyElement(isNonNegative));

    final many = CloudflarePrefixes.sample(Random(2), 3000);
    expect(many.map(prefixOf), everyElement(isNonNegative));
    // The two /13s are 69 % of the addresses.
    final inThirteens = many
        .where((a) => {11, 13}.contains(prefixOf(a)))
        .length;
    expect(inThirteens / many.length, inInclusiveRange(0.64, 0.74));

    final excluded = CloudflarePrefixes.sample(Random(1), 8).first;
    expect(
      CloudflarePrefixes.sample(
        Random(1),
        8,
        exclude: {excluded.address},
      ).map((a) => a.address),
      isNot(contains(excluded.address)),
    );
  });

  group('a run is due', () {
    final at = DateTime(2026, 11, 4, 12);
    final ran = ImageRouteDiscovery.initial.copyWith(
      lastRunAt: at.subtract(const Duration(hours: 6)),
    );
    for (final (name, state, loads, scores, due) in [
      (
        'after 20 loads on a new network',
        ImageRouteDiscovery.initial,
        20,
        <String, ImageRouteScore>{},
        true,
      ),
      (
        'not after 19',
        ImageRouteDiscovery.initial,
        19,
        <String, ImageRouteScore>{},
        false,
      ),
      (
        'when Cloudflare costs 1.5 times the origin',
        ran,
        0,
        {'ech:1.1.1.1': _score(3), 'origin': _score(2)},
        true,
      ),
      (
        'not at 1.4 times',
        ran,
        0,
        {'ech:1.1.1.1': _score(2.8), 'origin': _score(2)},
        false,
      ),
      (
        'when one front is bad and another fails 40 %',
        ran,
        0,
        {
          'ech:1.1.1.1': _score(3),
          'ech:1.1.1.2': _score(1, failed: 0.4),
          'origin': _score(2),
        },
        true,
      ),
      (
        'not when the failing one has less than two loads',
        ran,
        0,
        {
          'ech:1.1.1.1': _score(3),
          'ech:1.1.1.2': _score(1, weight: 1.5, failed: 0.4),
          'origin': _score(2),
        },
        false,
      ),
      (
        'when Cloudflare fails before any run',
        ImageRouteDiscovery.initial,
        3,
        {'ech:1.1.1.1': _score(12, failed: 1)},
        true,
      ),
      (
        'not within 6 hours of the last run',
        ran.copyWith(lastRunAt: at.subtract(const Duration(hours: 5))),
        0,
        {'ech:1.1.1.1': _score(3), 'origin': _score(2)},
        false,
      ),
      (
        'not within 12 hours after a run that kept nothing',
        ran.copyWith(fruitless: 1),
        0,
        {'ech:1.1.1.1': _score(3), 'origin': _score(2)},
        false,
      ),
      (
        'not when Cloudflare has no sample',
        ran,
        0,
        {'origin': _score(2)},
        false,
      ),
    ]) {
      test(name, () {
        expect(
          FrontDiscovery.due(state, loads: loads, scores: scores, now: at),
          due,
        );
      });
    }
  });

  test('a front worse than the best other for a day is dropped; a better '
      'sample starts the day again', () {
    final start = DateTime(2026, 11, 4);
    final front = ExtraFront(_seed, at: DateTime(2026, 11, 1));
    final worse = {echCandidate(_seed): _score(3), 'origin': _score(2)};
    final better = {echCandidate(_seed): _score(2.5), 'origin': _score(2)};

    var fronts = FrontDiscovery.judge([front], worse, start)!;
    expect(fronts.single.worseSince, start);
    final later = start.add(const Duration(hours: 23));
    expect(FrontDiscovery.judge(fronts, worse, later), isNull);
    fronts = FrontDiscovery.judge(fronts, better, later)!;
    expect(fronts.single.worseSince, isNull);
    fronts = FrontDiscovery.judge(fronts, worse, later)!;
    expect(
      FrontDiscovery.judge(fronts, worse, later.add(const Duration(days: 1))),
      isEmpty,
    );
    // Without a sample, or alone, it stays.
    expect(FrontDiscovery.judge([front], {'origin': _score(2)}, start), isNull);
    expect(
      FrontDiscovery.judge([front], {echCandidate(_seed): _score(9)}, start),
      isNull,
    );
  });

  test('a run keeps the two fronts that beat the hints or add a colo, '
      'rejects the 403, refused, colourless and slow ones, and only that '
      'network routes through them; labels are read again a day on', () {
    fakeAsync((async) {
      final addresses = CloudflarePrefixes.sample(
        Random(3),
        FrontDiscovery.probes,
        exclude: {_seed.address},
      );
      final second = const Duration(seconds: 1);
      final fronts = <String, _Front>{
        _lax1.address: _Front(colo: 'LAX'),
        _lax2.address: _Front(colo: 'LAX'),
        _seed.address: _Front(colo: 'HKG'),
        // Beats the hints.
        addresses[0].address: _Front(colo: 'HKG'),
        // A new colo, a little slower than the best hint.
        addresses[1].address: _Front(colo: 'SJC', headersAfter: second * 8),
        addresses[2].address: _Front(colo: 'HKG', status: 403),
        addresses[3].address: _Front(refused: true),
        // A colo the hints use, not a fifth better.
        addresses[4].address: _Front(colo: 'LAX', headersAfter: second * 8),
        addresses[5].address: _Front(),
        addresses[6].address: _Front(colo: 'LAX', headersAfter: second * 9),
        addresses[7].address: _Front(colo: 'NRT', headersAfter: second * 11),
      };
      final discovered = <(String, ImageRouteDiscovery)>[];
      late final FrontDiscovery discovery;
      final memory = WorkerImageRouteScoreMemory(
        onSample: (identity, sample) => discovery.noteSample(identity, sample),
        onDiscovery: (identity, d) => discovered.add((identity, d)),
      );
      final policy = NetworkAccessPolicy(
        revision: NetworkRevision(0, networkIdentity: 'unicom'),
        imageRouteScoreStore: memory,
        resolver: FakeEchResolver(
          [InternetAddress('1.2.3.80')],
          frontAddresses: [_lax1, _lax2],
        ),
        // A later run's addresses refuse.
        clientFactory: (route, _, _) =>
            fronts[route.address!.address] ?? _Front(refused: true),
        clock: () => clock.now(),
      );
      var idle = false;
      discovery = FrontDiscovery(
        policy,
        idle: () => idle,
        image: () => _thumbnail,
        random: Random(3),
      );
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );
      Future<void> get() async {
        await (await client.send(
          ImageRequest('GET', _thumbnail),
        )).stream.drain<void>();
      }

      unawaited(get());
      async.flushMicrotasks();
      void fail(InternetAddress front, int times) {
        for (var i = 0; i < times; i++) {
          policy.recordImageRouteSample(
            'unicom',
            ImageRouteSample.failure(echCandidate(front), at: clock.now()),
          );
        }
      }

      fail(_lax1, 4);
      fail(_lax2, 3);
      fail(_seed, 3);
      async.elapse(const Duration(minutes: 1));
      // Every Cloudflare front fails, but a visible image waits.
      for (final address in addresses) {
        expect(fronts[address.address]!.paths, isEmpty);
      }

      idle = true;
      fail(_lax1, 1);
      async.elapse(const Duration(minutes: 2));
      expect(fronts[addresses[0].address]!.paths, [
        '/cdn-cgi/trace',
        _thumbnail.path,
      ]);
      final (identity, state) = discovered.last;
      expect(identity, 'unicom');
      expect(state.fronts.map((f) => f.address.address), [
        addresses[0].address,
        addresses[1].address,
      ]);
      expect(state.rejected.keys.toSet(), {
        for (final i in [2, 3, 5, 7]) addresses[i].address,
      });
      expect(state.lastRunAt, isNotNull);
      expect(state.fruitless, 0);
      expect(
        {
          for (final MapEntry(:key, :value) in state.colos.entries)
            key: value.colo,
        },
        {
          _lax1.address: 'LAX',
          _lax2.address: 'LAX',
          _seed.address: 'HKG',
          addresses[0].address: 'HKG',
          addresses[1].address: 'SJC',
        },
      );

      // The kept front, not yet scored, is tried before the failing ones.
      final before = fronts[addresses[0].address]!.paths.length;
      unawaited(get());
      async.elapse(const Duration(seconds: 1));
      expect(fronts[addresses[0].address]!.paths, hasLength(before + 1));
      expect(
        policy.imageRouteStandings().map((s) => s.colo),
        containsAll(['LAX', 'HKG']),
      );

      // A day on, the next load through a front reads its colo again.
      async.elapse(const Duration(days: 1));
      final traces = fronts[_lax1.address]!.paths
          .where((path) => path == '/cdn-cgi/trace')
          .length;
      fail(_lax1, 1);
      async.elapse(const Duration(minutes: 2));
      expect(
        fronts[_lax1.address]!.paths.where((path) => path == '/cdn-cgi/trace'),
        hasLength(traces + 1),
      );

      policy.advanceNetworkRevision(networkIdentity: 'telecom');
      async.flushMicrotasks();
      expect(policy.imageRouteDiscovery.fronts.map((f) => f.address.address), [
        _seed.address,
      ]);
      discovery.close();
      unawaited(policy.dispose());
      async.flushMicrotasks();
    });
  });

  test('the worker sends its discoveries home, and a config sent before '
      'the main isolate heard of one does not undo it', () {
    final sent = <(String, ImageRouteDiscovery)>[];
    final memory = WorkerImageRouteScoreMemory(
      onDiscovery: (identity, discovery) => sent.add(switch (decodeWorkerEvent(
        encodeWorkerEvent(RouteDiscoveryEvent(identity, discovery)),
      )) {
        RouteDiscoveryEvent(:final networkIdentity, :final discovery) => (
          networkIdentity,
          discovery,
        ),
        _ => throw StateError('not a discovery'),
      }),
    );
    final mine = ImageRouteDiscovery(
      fronts: [ExtraFront(InternetAddress('104.16.1.2'), at: DateTime(2026))],
    );
    memory
      ..reseed('unicom', const {}, null)
      ..discovered('unicom', mine)
      ..reseed('unicom', const {}, ImageRouteDiscovery.initial)
      ..reseed('cafe', const {}, ImageRouteDiscovery.initial);
    expect(sent.single.$1, 'unicom');
    expect(sent.single.$2.fronts.single.address.address, '104.16.1.2');
    expect(
      memory.discoveryFor('unicom'),
      completion(
        isA<ImageRouteDiscovery>().having(
          (d) => d.fronts.single.address.address,
          'front',
          '104.16.1.2',
        ),
      ),
    );
    expect(
      memory.discoveryFor('cafe'),
      completion(same(ImageRouteDiscovery.initial)),
    );
  });

  test('a discovery survives a restart and seeds a new worker\'s '
      'candidates', () async {
    installPreferencesForTest(InMemorySharedPreferencesAsync.empty());
    final kept = InternetAddress('104.16.1.2');
    final store = ImageRouteScoreStore(preferences: SharedPreferencesAsync());
    store.discovered(
      'unicom',
      ImageRouteDiscovery(
        fronts: [ExtraFront(kept, at: DateTime(2026, 11, 4))],
        lastRunAt: DateTime(2026, 11, 4),
        colos: {kept.address: FrontColo('HKG', at: DateTime(2026, 11, 4))},
      ),
    );
    await store.flush();

    final restarted = ImageRouteScoreStore(
      preferences: SharedPreferencesAsync(),
    );
    final config = ImageWorkerConfig.fromJson(
      jsonDecode(
            jsonEncode(
              ImageWorkerConfig(
                imageSource: 'i.pximg.net',
                mode: 'automatic',
                networkIdentity: 'unicom',
                echFrontHost: 'cloudflare-ech.com',
                dohEndpoints: const [],
                bootstrapNoSniEnabled: false,
                routeDiscovery: await restarted.discoveryFor('unicom'),
              ).toJson(),
            ),
          )
          as Map<String, Object?>,
    );
    expect(await restarted.discoveryFor('cafe'), isNull);

    final memory = WorkerImageRouteScoreMemory()
      ..reseed(
        config.networkIdentity,
        config.routeScores,
        config.routeDiscovery,
      );
    final sent = <String>[];
    final policy = NetworkAccessPolicy(
      revision: NetworkRevision(0, networkIdentity: 'unicom'),
      imageRouteScoreStore: memory,
      resolver: FakeEchResolver(
        [InternetAddress('1.2.3.80')],
        frontAddresses: [_lax1, _lax2],
      ),
      clientFactory: (route, _, _) => RouteLogClient(
        route,
        sent,
        route.address == kept
            ? FakeClient()
            : FakeClient(failure: const SocketException('refused')),
      ),
    );
    addTearDown(policy.dispose);
    await pumpEventQueue();
    expect(policy.imageRouteDiscovery.lastRunAt, DateTime(2026, 11, 4));

    final response = await PixivPolicyHttpClient(
      policy: policy,
      purpose: PixivDestinationPurpose.image,
    ).send(ImageRequest('GET', _thumbnail));
    await response.stream.drain<void>();
    // The kept front took the seed's place.
    expect(sent, [_lax1.address, _lax2.address, kept.address]);
  });

  group('origin refresh', () {
    final served = InternetAddress('210.140.139.200');
    final refused = InternetAddress('210.140.139.201');
    final forbidden = InternetAddress('210.140.139.202');
    final builtIn = PixivFastRouteStore.originAddresses.first;
    final sample = ImageRouteSample.failure('origin', at: DateTime(2026));

    test('it keeps the address DNS names that serves an image, ignores '
        'those that do not, and asks once a day', () async {
      installPreferencesForTest(InMemorySharedPreferencesAsync.empty());
      final store = PixivFastRouteStore(preferences: SharedPreferencesAsync());
      final resolver = FakeResolver([
        builtIn,
        served,
        refused,
        forbidden,
      ], source: DnsSource.doh);
      final probed = <String>[];
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        bootstrapNoSniEnabled: true,
        fastRouteStore: store,
        clientFactory: (route, _, _) => RouteLogClient(
          route,
          probed,
          switch (route.address?.address) {
            final a when a == served.address => FakeClient(body: 'jpg'),
            final a when a == forbidden.address => FakeClient(statusCode: 403),
            _ => FakeClient(failure: const SocketException('refused')),
          },
        ),
      );
      addTearDown(policy.dispose);
      var idle = false;
      final refresh = OriginRefresh(
        policy,
        idle: () => idle,
        image: () => _thumbnail,
      );

      refresh.noteSample('unicom', sample);
      await refresh.settled;
      expect(resolver.calls, 0, reason: 'a visible image waits');
      idle = true;
      refresh
        ..noteSample('unicom', sample)
        ..noteSample('unicom', sample);
      await refresh.settled;
      expect(resolver.calls, 1);
      expect(probed, [served, refused, forbidden].map((a) => a.address));
      final restarted = PixivFastRouteStore(
        preferences: SharedPreferencesAsync(),
      );
      await pumpEventQueue();
      expect(
        (await restarted.provenOrigins())!.addresses.map((a) => a.address),
        [served.address],
      );

      final again = OriginRefresh(
        policy,
        idle: () => true,
        image: () => _thumbnail,
      )..noteSample('unicom', sample);
      await again.settled;
      expect(resolver.calls, 1);
    });

    test('a visible image arriving mid-refresh stops it before the next '
        'probe; the next idle sample probes the rest of the same DNS '
        'answer', () async {
      installPreferencesForTest(InMemorySharedPreferencesAsync.empty());
      final store = PixivFastRouteStore(preferences: SharedPreferencesAsync());
      final second = InternetAddress('210.140.139.203');
      final probed = <String>[];
      final resolver = FakeResolver([served, second], source: DnsSource.doh);
      final policy = NetworkAccessPolicy(
        resolver: resolver,
        bootstrapNoSniEnabled: true,
        fastRouteStore: store,
        clientFactory: (route, _, _) =>
            RouteLogClient(route, probed, FakeClient(body: 'jpg')),
      );
      addTearDown(policy.dispose);
      final refresh = OriginRefresh(
        policy,
        // The first probe's image is seen; then a visible image waits.
        idle: () => probed.length != 1,
        image: () => _thumbnail,
      )..noteSample('unicom', sample);
      await refresh.settled;
      expect(probed, [served.address]);
      expect((await store.provenOrigins())!.addresses.map((a) => a.address), [
        served.address,
      ]);

      probed.add('visible image done');
      refresh.noteSample('unicom', sample);
      await refresh.settled;
      expect(probed.last, second.address);
      expect(resolver.calls, 1);
      final origins = (await store.provenOrigins())!;
      expect(origins.addresses.map((a) => a.address), [
        served.address,
        second.address,
      ]);
      expect(origins.refreshedAt.year, isNot(1970));
    });

    for (final (failure, origin) in <(String, http.Client Function())>[
      ('is refused', () => FakeClient(failure: const SocketException('x'))),
      ('breaks off its body', _BrokenBody.new),
      ('answers 503', () => FakeClient(statusCode: 503, body: '')),
    ]) {
      test(
        'a proven address from a new worker\'s config is tried after the '
        'last served one, and is skipped once it $failure three loads in '
        'a row, even after an origin refresh; a built-in one never is',
        () async {
          final config = ImageWorkerConfig.fromJson(
            jsonDecode(
                  jsonEncode(
                    ImageWorkerConfig(
                      imageSource: 'i.pximg.net',
                      mode: 'automatic',
                      networkIdentity: 'unicom',
                      echFrontHost: 'cloudflare-ech.com',
                      dohEndpoints: const [],
                      bootstrapNoSniEnabled: true,
                      provenOrigins: ProvenOrigins([
                        served,
                      ], refreshedAt: DateTime(2026, 11, 4)),
                    ).toJson(),
                  ),
                )
                as Map<String, Object?>,
          );
          final memory = WorkerFastRouteMemory(
            WorkerRouteMemoryState(origins: config.provenOrigins),
          );
          final sent = <String>[];
          final policy = NetworkAccessPolicy(
            resolver: FakeResolver([InternetAddress('1.2.3.4')]),
            bootstrapNoSniEnabled: true,
            fastRouteStore: memory,
            clientFactory: (route, _, _) => RouteLogClient(
              route,
              sent,
              route.kind == NetworkRouteKind.bootstrapNoSni
                  ? origin()
                  : FakeClient(failure: const SocketException('refused')),
            ),
          );
          final client = PixivPolicyHttpClient(
            policy: policy,
            purpose: PixivDestinationPurpose.image,
          );
          addTearDown(policy.dispose);
          Future<void> load() async {
            final status = await client
                .get(_thumbnail)
                .then((r) => r.statusCode, onError: (Object _) => 0);
            expect(status, isNot(200));
          }

          final book = PixivFastRouteStore.originAddresses.length + 1;
          // Three turns of the book, then one without the skipped address.
          for (var i = 0; i < 4 * book - 1; i++) {
            await load();
          }
          final origins = sent.where((a) => a.startsWith('210.140.139.'));
          final bootstrap =
              PixivFastRouteStore.bootstrap['i.pximg.net']!.address;
          expect(origins.take(2), [bootstrap, served.address]);
          expect(origins.where((a) => a == served.address), hasLength(3));
          expect(origins.where((a) => a == bootstrap), hasLength(4));

          // An origin refresh that ends in the same addresses does not bring
          // the skipped one back.
          policy.rememberProvenOrigins(
            ProvenOrigins([served], refreshedAt: DateTime(2026, 11, 5)),
          );
          for (var i = 0; i < book; i++) {
            await load();
          }
          expect(sent.where((a) => a == served.address), hasLength(3));
        },
      );
    }

    test('a whole image from a proven address between its failures starts '
        'its count again', () async {
      final statuses = [503, 503, 200];
      final sent = <String>[];
      final policy = NetworkAccessPolicy(
        resolver: FakeResolver([InternetAddress('1.2.3.4')]),
        bootstrapNoSniEnabled: true,
        fastRouteStore: WorkerFastRouteMemory(
          WorkerRouteMemoryState(
            origins: ProvenOrigins([
              served,
            ], refreshedAt: DateTime(2026, 11, 4)),
          ),
        ),
        clientFactory: (route, _, _) => RouteLogClient(
          route,
          sent,
          route.kind != NetworkRouteKind.bootstrapNoSni
              ? FakeClient(failure: const SocketException('refused'))
              : route.address == served
              ? _Statuses(statuses)
              : FakeClient(statusCode: 503, body: ''),
        ),
      );
      final client = PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.image,
      );
      addTearDown(policy.dispose);
      final book = PixivFastRouteStore.originAddresses.length + 1;
      for (var i = 0; i < 8 * book; i++) {
        await client.get(_thumbnail);
      }
      // Two failures, a whole image, then three more before the skip.
      expect(sent.where((a) => a == served.address), hasLength(6));
    });

    test('the worker sends its proven origins home, and a config sent '
        'before the main isolate heard of them does not undo them', () async {
      final sent = <ProvenOrigins>[];
      final state = WorkerRouteMemoryState();
      final memory = WorkerFastRouteMemory(
        state,
        onOriginsProven: (origins) => sent.add(
          (decodeWorkerEvent(encodeWorkerEvent(OriginsProvenEvent(origins)))
                  as OriginsProvenEvent)
              .origins,
        ),
      );
      final mine = ProvenOrigins([served], refreshedAt: DateTime(2026, 11, 4));
      state.reseedOrigins(null);
      memory.proveOrigins(mine);
      state.reseedOrigins(ProvenOrigins(const [], refreshedAt: DateTime(2026)));
      expect(sent.single.addresses.single.address, served.address);
      expect((await memory.provenOrigins())!.addresses.single, served);
    });
  });
}
