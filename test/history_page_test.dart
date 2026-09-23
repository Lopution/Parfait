import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/history/history_database.dart';
import 'package:pixiv_func/core/history/history_models.dart';
import 'package:pixiv_func/core/history/history_repository.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/features/history/history_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

/// Real async I/O (the ffi-backed history database) only resolves while
/// the real event loop turns, so every step that touches the repository
/// or waits on provider futures runs inside [WidgetTester.runAsync].
Future<ProviderContainer> _makeWorld(HistoryRepository repository) async {
  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      historyRepositoryProvider.overrideWithValue(repository),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async => http.Response('{}', 200)),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
    ],
  );
  clientRef[0] = PixivHttpClient(
    client: MockClient((request) async => http.Response('{}', 200)),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  return container;
}

HistoryRecord _record(int id, {HistoryContentType? type}) => HistoryRecord(
  accountId: '100',
  contentType: type ?? HistoryContentType.illust,
  contentId: id,
  lastViewedAt: DateTime.utc(2026, 9, 20, 10),
  snapshot: HistorySnapshot(title: 'work $id', authorName: 'author $id'),
);

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: const [Locale('zh')],
    locale: const Locale('zh'),
    home: const HistoryPage(),
  ),
);

Future<ProviderContainer> _seedPage(
  WidgetTester tester,
  List<HistoryRecord> records,
) async {
  // Phone-sized surface: the confirm sheet's 0.35-height fraction box
  // overflows on the 800x600 default viewport and pushes the buttons out.
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late ProviderContainer container;
  await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp('hist-');
    final database = HistoryDatabase(
      factory: databaseFactoryFfi,
      databasePath: path.join(directory.path, 'history.db'),
    );
    final repository = HistoryRepository(database: database);
    for (final record in records) {
      await repository.upsert(record);
    }
    container = await _makeWorld(repository);
    await tester.pumpWidget(_app(container));
    // Let the first page load land on the real event loop.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    addTearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });
  });
  return container;
}

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  testWidgets('long-press enters selection mode and toggles membership', (
    tester,
  ) async {
    await _seedPage(tester, [_record(1), _record(2)]);

    expect(find.text('work 1'), findsOneWidget);

    // Long-press enters management mode with the row selected — the
    // AppBar swaps to the selection surface (primaryContainer + count).
    await tester.longPress(find.text('work 1'));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.select_all), findsOneWidget);

    // In selection mode a plain tap toggles instead of navigating — the
    // row's own ink is absorbed by the selection wrapper, so warnIfMissed
    // stays off for these deliberate parent hits.
    await tester.tap(find.text('work 2'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(find.text('work 1'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);

    // The close button exits the mode and restores the normal AppBar.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('已选 1 项'), findsNothing);
    expect(find.text('历史记录'), findsOneWidget);
  });

  testWidgets('manage action enters mode; select-all then delete clears', (
    tester,
  ) async {
    await _seedPage(tester, [
      _record(1),
      _record(2),
      _record(3, type: HistoryContentType.novel),
    ]);

    await tester.tap(find.byTooltip('管理'));
    await tester.pump();
    expect(find.text('已选 0 项'), findsOneWidget);

    await tester.tap(find.byTooltip('全选'));
    await tester.pump();
    expect(find.text('已选 3 项'), findsOneWidget);

    // Delete goes through the shared confirm bottom sheet, then the rows
    // disappear and the mode exits.
    // The sheet + confirm interactions stay in fake-async so pump() can
    // drive the entry/exit animations to completion; only the ffi-backed
    // deletes need the real event loop afterwards.
    await tester.tap(find.byTooltip('删除历史记录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('删除后将不可恢复'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('work 1'), findsNothing);
    expect(find.text('暂无浏览历史'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);
  });

  testWidgets('system back exits selection mode instead of popping', (
    tester,
  ) async {
    await _seedPage(tester, [_record(1)]);

    await tester.longPress(find.text('work 1'));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);

    final popped = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(popped, isTrue);
    expect(find.text('已选 1 项'), findsNothing);
    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('work 1'), findsOneWidget);
  });
}
