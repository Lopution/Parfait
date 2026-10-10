import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parfait/core/image/image_worker.dart';
import 'package:parfait/core/image/image_worker_client.dart';
import 'package:parfait/core/image/image_worker_host.dart';
import 'package:parfait/core/image/image_worker_protocol.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/image/image_demand.dart';

/// Fake image transport. Every send is recorded. Unless [respond] returns
/// a canned response, the body stays open until the test closes it, so a
/// lane permit is observably held for the whole transfer.
class HeldBodyClient extends http.BaseClient {
  HeldBodyClient({this.respond});

  final http.StreamedResponse? Function(http.BaseRequest request)? respond;
  final requests = <http.BaseRequest>[];
  final bodies = <StreamController<List<int>>>[];

  List<String> get urls => [for (final r in requests) r.url.toString()];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final canned = respond?.call(request);
    if (canned != null) return canned;
    final body = StreamController<List<int>>();
    bodies.add(body);
    return http.StreamedResponse(body.stream, 200, request: request);
  }

  /// Ends every body still open.
  Future<void> closeAll() async {
    for (final body in List.of(bodies)) {
      if (!body.isClosed) await body.close();
    }
  }
}

/// Serves [files] by URL, honouring `Range: bytes=a-b` with a 206 and its
/// `Content-Range` unless [honorRange] is off. With [hold], every body
/// waits for [releaseHeld] — a transfer that keeps its permit.
class RangeServingClient extends http.BaseClient {
  RangeServingClient(this.files, {this.honorRange = true, this.hold = false});

  final Map<String, Uint8List> files;
  final bool honorRange;
  final bool hold;
  final requests = <http.BaseRequest>[];
  final _held = <(StreamController<List<int>>, Uint8List)>[];

  static const _chunk = 64 * 1024;
  static final _rangePattern = RegExp(r'^bytes=(\d+)-(\d+)$');

  List<String> get urls => [for (final r in requests) r.url.toString()];
  List<String?> get ranges => [for (final r in requests) r.headers['range']];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final data = files[request.url.toString()];
    if (data == null) {
      return http.StreamedResponse(const Stream.empty(), 404, request: request);
    }
    final range = _rangePattern.firstMatch(request.headers['range'] ?? '');
    if (!honorRange || range == null) {
      return http.StreamedResponse(
        _body(data),
        200,
        contentLength: data.length,
        request: request,
        headers: {'etag': '"v1"'},
      );
    }
    final start = int.parse(range.group(1)!);
    final last = math.min(int.parse(range.group(2)!), data.length - 1);
    final slice = Uint8List.sublistView(data, start, last + 1);
    return http.StreamedResponse(
      _body(slice),
      206,
      contentLength: slice.length,
      request: request,
      headers: {
        'content-range': 'bytes $start-$last/${data.length}',
        'etag': '"v1"',
      },
    );
  }

  Stream<List<int>> _body(Uint8List bytes) {
    if (hold) {
      final body = StreamController<List<int>>();
      _held.add((body, bytes));
      return body.stream;
    }
    return Stream.fromIterable([
      for (var i = 0; i < bytes.length; i += _chunk)
        Uint8List.sublistView(bytes, i, math.min(i + _chunk, bytes.length)),
    ]);
  }

  /// Sends and ends every held body; a body nobody reads yet keeps its
  /// bytes until it is listened to.
  void releaseHeld() {
    final held = List.of(_held);
    _held.clear();
    for (final (body, bytes) in held) {
      body.add(bytes);
      unawaited(body.close());
    }
  }
}

/// [size] bytes of a repeating pattern that no shifted copy matches.
Uint8List patternBytes(int size) =>
    Uint8List.fromList([for (var i = 0; i < size; i++) i * 31 % 251]);

/// Lets queued microtasks and immediate timers run (real async only).
Future<void> settleIo([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Polls [condition] in real time; disk-backed cache work needs actual IO
/// turns, not just microtasks. Fails after [timeout].
Future<void> pollUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Real IO turns between pumps until [done] — an in-process worker's hops
/// each need one — failing after a bound.
Future<void> pumpIoUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'settled within the bound');
}

/// Unmounts the tree and lets the release grace run out: releasing a URL
/// whose worker transfer is still in flight arms a re-check timer, which
/// must not outlive the test.
Future<void> unmountPastReleaseGrace(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(releaseGrace);
}

/// A 1×1 PNG.
final onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// The config in-process test workers run with: direct `i.pximg.net`, no
/// DoH.
const testImageWorkerConfig = ImageWorkerConfig(
  imageSource: 'i.pximg.net',
  mode: 'directOnly',
  networkIdentity: 'test-net',
  echFrontHost: 'cloudflare-ech.com',
  dohEndpoints: [],
  bootstrapNoSniEnabled: true,
);

/// A real [ImageWorker] whose isolates are in-process [ImageWorkerHost]s
/// behind the real protocol, disk cache and scheduler; [fetchClient] is the
/// network. Its IO is real, so a widget test drives it with `runAsync`
/// turns between pumps.
ImageWorker inProcessImageWorker(http.Client Function() fetchClient) {
  final dir = Directory.systemTemp.createTempSync('parfait-worker-');
  final hosts = <ImageWorkerHost>[];
  final worker = ImageWorker(
    config: () async => testImageWorkerConfig,
    start: (config, demand) {
      final inbox = ReceivePort();
      final host = ImageWorkerHost(
        mainSendPort: inbox.sendPort,
        config: config,
        cacheDir: dir.path,
        transportInit: () async {},
        fetchClient: fetchClient,
      );
      hosts.add(host);
      unawaited(host.run());
      return ImageWorkerClient.attach(inbox, demand: demand);
    },
  );
  // Only the synchronous half of each shutdown: the futures were made in
  // the test's fake zone, which nobody pumps once the body has returned.
  addTearDown(() {
    unawaited(worker.dispose());
    for (final host in hosts) {
      unawaited(host.close());
    }
    dir.deleteSync(recursive: true);
  });
  return worker;
}

/// A client whose worker is a script on the far side of the protocol, for
/// answers no in-process host can give (a policy with settled routes):
/// every route request gets [routes], every lookup a miss, and anything
/// else no answer.
Future<ImageWorkerClient> scriptedImageWorkerClient(
  ImageDemand demand, {
  Map<String, String> routes = const {},
}) {
  final inbox = ReceivePort();
  final peer = ReceivePort();
  void reply(WorkerEvent event) =>
      inbox.sendPort.send(encodeWorkerEvent(event));
  peer.listen((raw) {
    switch (decodeWorkerMessage(raw)) {
      case RoutesMessage(:final id):
        reply(RoutesEvent(id, routes));
      case LookupMessage(:final id):
        reply(CachedEvent(id, null));
      case _:
        break;
    }
  });
  addTearDown(peer.close);
  reply(ReadyEvent(peer.sendPort));
  return ImageWorkerClient.attach(inbox, demand: demand);
}

/// A worker whose isolate never comes up: every image on it stays a
/// placeholder. For tests about how an image is set up, not loaded.
ImageWorker stalledImageWorker() => ImageWorker(
  start: (_, _) => Completer<ImageWorkerClient>().future,
  config: () async => testImageWorkerConfig,
);

/// [child] under a scope whose images never load, for tests about
/// something else: every `PixivImage` needs a [ProviderScope].
Widget withStalledImages(Widget child) => ProviderScope(
  overrides: [imageWorkerProvider.overrideWithValue(stalledImageWorker())],
  child: child,
);
