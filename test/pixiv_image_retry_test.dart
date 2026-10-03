import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/network/compat/pixiv_network_factory.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/image_network.dart';

const _url = 'https://i.pximg.net/img-master/retry.jpg';

/// A 1×1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _NoFileSystem implements FileSystem {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('scripted cache has no disk');
}

/// The image cache's network and disk boundary, scripted per attempt.
class _ScriptedCacheManager extends CacheManager {
  _ScriptedCacheManager(this.script)
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

class _Network extends PixivNetworkFactory {
  _Network(this.manager)
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

Stream<FileResponse> _transient(int _) =>
    Stream.error(const SocketException('connection reset'));

Stream<FileResponse> _notFound(int _) =>
    Stream.error(HttpExceptionWithStatus(404, 'not found'));

Future<void> _pump(
  WidgetTester tester,
  CacheManager manager, {
  double size = 200,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pixivNetworkFactoryProvider.overrideWithValue(_Network(manager)),
      ],
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Center(
          child: SizedBox.square(
            dimension: size,
            child: const PixivImage(url: _url),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// Lets real IO and image decoding finish, then flushes frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

bool _painted(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .any((image) => image.image != null);

void main() {
  // Each test resolves the same URL; a decoded or errored entry left in the
  // image cache would answer without asking the cache manager.
  setUp(
    () => PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages(),
  );
  testWidgets('a transient failure retries after 1 s and 3 s and then shows '
      'the image', (tester) async {
    mockPathProvider();
    final file = (await tester.runAsync(() async {
      final file = await IOFileSystem('parfait_retry').createFile('a.png');
      await file.writeAsBytes(_png);
      return file;
    }))!;
    final manager = _ScriptedCacheManager(
      (attempt) => attempt < 3
          ? _transient(attempt)
          : Stream.value(
              FileInfo(file, FileSource.Online, DateTime(2100), _url),
            ),
    );
    await _pump(tester, manager);
    expect(manager.requests, 1);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);

    await tester.pump(const Duration(milliseconds: 900));
    expect(manager.requests, 1);
    await tester.pump(const Duration(milliseconds: 100));
    await _settle(tester);
    expect(manager.requests, 2);

    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(manager.requests, 3);
    // Reading the file and decoding it are real IO.
    for (var i = 0; i < 20 && !_painted(tester); i++) {
      await _settle(tester);
    }
    expect(_painted(tester), isTrue);
    expect(find.byIcon(Icons.broken_image), findsNothing);
  });

  testWidgets('three failed retries end in a manual retry button', (
    tester,
  ) async {
    final manager = _ScriptedCacheManager(_transient);
    await _pump(tester, manager);
    for (final wait in const [1, 3, 8]) {
      await tester.pump(Duration(seconds: wait));
      await _settle(tester);
    }
    expect(manager.requests, 4);
    await tester.pump(const Duration(seconds: 30));
    expect(manager.requests, 4);
    expect(find.byTooltip('重新加载图片'), findsOneWidget);
  });

  testWidgets('a missing image is asked for once; the button asks again', (
    tester,
  ) async {
    final manager = _ScriptedCacheManager(_notFound);
    await _pump(tester, manager);
    await tester.pump(const Duration(seconds: 30));
    expect(manager.requests, 1);

    await tester.tap(find.byIcon(Icons.refresh));
    await _settle(tester);
    expect(manager.requests, 2);
  });

  testWidgets('a small image slot keeps the broken-image icon', (tester) async {
    final manager = _ScriptedCacheManager(_notFound);
    await _pump(tester, manager, size: 32);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });

  testWidgets('a pending retry dies with the widget', (tester) async {
    final manager = _ScriptedCacheManager(_transient);
    await _pump(tester, manager);
    expect(manager.requests, 1);
    await tester.pumpWidget(const SizedBox());
    // flutter_test fails the test if the backoff timer is still pending.
    expect(manager.requests, 1);
  });
}
