@Tags(['socket'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:parfait/core/image/image_worker_client.dart';
import 'package:parfait/core/image/image_worker_host.dart';
import 'package:parfait/core/image/lane_permit_gate.dart';
import 'package:parfait/core/image/worker_image_provider.dart';
import 'package:parfait/core/image/image_demand.dart';

import 'helpers/image_network.dart';

void main() {
  // The widget-test binding installs a mock HttpOverrides answering 400
  // for everything — this test needs a real loopback server.
  late final HttpOverrides? previousOverrides;
  setUp(() {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });
  tearDown(() => HttpOverrides.global = previousOverrides);

  testWidgets('the provider resolves a worker-fetched file into an image', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('parfait-provider-');
    addTearDown(() => dir.delete(recursive: true));

    // Everything that does real IO — the loopback server, the worker host
    // and the provider resolve — lives inside runAsync; listeners
    // registered in the test's fake zone are never pumped during it.
    final image = (await tester.runAsync<ui.Image>(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.forEach((request) async {
          request.response
            ..contentLength = onePixelPng.length
            ..add(onePixelPng);
          await request.response.close();
        }),
      );

      final inbox = ReceivePort();
      final host = ImageWorkerHost(
        mainSendPort: inbox.sendPort,
        config: testImageWorkerConfig,
        cacheDir: dir.path,
        transportInit: () async {},
        fetchClient: IOClient.new,
      );
      addTearDown(host.close);
      unawaited(host.run());
      final client = await ImageWorkerClient.attach(
        inbox,
        demand: ImageDemand(),
      );
      addTearDown(client.dispose);

      final provider = WorkerImageProvider(
        client,
        'http://127.0.0.1:${server.port}/img/p0.jpg',
        priority: ImageFetchPriority.foreground,
      );
      return firstFrame(provider).timeout(const Duration(seconds: 10));
    }))!;
    expect((image.width, image.height), (1, 1));
  });
}
