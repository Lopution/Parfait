import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';

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

/// Answers the path_provider channel (an external boundary) with a fresh
/// temp directory, removed after the test.
Directory mockPathProvider() {
  final dir = Directory.systemTemp.createTempSync('parfait-img-');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
  addTearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    await dir.delete(recursive: true);
  });
  return dir;
}

/// A real [CacheManager] over [fileService], storing files under a fresh
/// temp directory with no persisted index.
CacheManager testImageCacheManager(FileService fileService) {
  mockPathProvider();
  final manager = CacheManager(
    Config(
      'parfait_images_test_${_managerSerial++}',
      repo: NonStoringObjectProvider(),
      fileService: fileService,
    ),
  );
  addTearDown(manager.dispose);
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

/// A 1×1 PNG.
final _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// A fresh download of [url] whose file is a decodable 1×1 PNG, written
/// under a mocked temp directory (real IO).
Future<FileInfo> onePixelPngDownload(WidgetTester tester, String url) async {
  mockPathProvider();
  final file = (await tester.runAsync(() async {
    final file = await IOFileSystem('parfait_png').createFile('a.png');
    await file.writeAsBytes(_onePixelPng);
    return file;
  }))!;
  return FileInfo(file, FileSource.Online, DateTime(2100), url);
}

class _NoFileSystem implements FileSystem {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('scripted cache has no disk');
}

/// The image cache's network and disk boundary, scripted per attempt.
class ScriptedCacheManager extends CacheManager {
  ScriptedCacheManager(this.script)
    : super(
        Config(
          'parfait_scripted',
          repo: NonStoringObjectProvider(),
          fileSystem: _NoFileSystem(),
        ),
      );

  final Stream<FileResponse> Function(int attempt) script;
  var requests = 0;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => script(++requests);
}

/// A network factory whose image cache is [manager]; API calls fail.
class ScriptedImageNetwork extends PixivNetworkFactory {
  ScriptedImageNetwork(this.manager)
    : super(
        NetworkAccessPolicy(
          clientFactory: (_, _, _) =>
              MockClient((_) async => http.Response('', 500)),
        ),
      );

  final CacheManager manager;

  @override
  CacheManager get imageCacheManager => manager;
}
