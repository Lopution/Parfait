import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Fake image transport for the real `PriorityFileService` → `CacheManager`
/// chain. Every send is recorded. Unless [respond] returns a canned
/// response, the body stays open until the test closes it, so a lane
/// permit is observably held for the whole transfer.
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

var _managerSerial = 0;

/// A real [CacheManager] over [fileService], storing files under a fresh
/// temp directory with no persisted index. The path_provider channel is an
/// external boundary, so it is answered here.
CacheManager testImageCacheManager(FileService fileService) {
  final dir = Directory.systemTemp.createTempSync('parfait-img-');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
  final manager = CacheManager(
    Config(
      'parfait_images_test_${_managerSerial++}',
      repo: NonStoringObjectProvider(),
      fileService: fileService,
    ),
  );
  addTearDown(() async {
    await manager.dispose();
    messenger.setMockMethodCallHandler(pathChannel, null);
    await dir.delete(recursive: true);
  });
  return manager;
}

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
