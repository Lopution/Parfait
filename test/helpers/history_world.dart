import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/auth/oauth_service.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/history/history_database.dart';
import 'package:parfait/core/history/history_models.dart';
import 'package:parfait/core/history/history_repository.dart';
import 'package:parfait/core/image/image_worker_providers.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_account.dart';
import 'image_network.dart';

/// A real history repository on a fresh ffi database holding [records],
/// closed and deleted at teardown. Real I/O: call inside
/// [WidgetTester.runAsync].
Future<HistoryRepository> openHistoryRepository(
  List<HistoryRecord> records,
) async {
  final directory = await Directory.systemTemp.createTemp('hist-');
  final database = HistoryDatabase(
    factory: databaseFactoryFfi,
    databasePath: path.join(directory.path, 'history.db'),
  );
  addTearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });
  // Open now, in the caller's zone: sqflite's reply port binds to the zone
  // that opens the database, and one first opened by a widget in the fake
  // zone never hears back from the tear-down's close.
  await database.database;
  final repository = HistoryRepository(database: database);
  for (final record in records) {
    await repository.upsert(record);
  }
  return repository;
}

/// Real async I/O (the ffi-backed history database) only resolves while
/// the real event loop turns, so every step that touches the repository
/// or waits on provider futures runs inside [WidgetTester.runAsync].
Future<ProviderContainer> makeHistoryWorld(
  HistoryRepository repository, {
  IllustStore? illustStore,
}) async {
  final credentials = FakeCredentialStore();
  await seedAccounts([
    const Account(id: '100', userId: 100, name: 'tester'),
  ], currentId: '100');
  credentials.seed(
    '100',
    const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
  );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer.test(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      historyRepositoryProvider.overrideWithValue(repository),
      // The cards' images would otherwise spawn a real worker isolate.
      imageWorkerProvider.overrideWithValue(stalledImageWorker()),
      if (illustStore != null)
        illustStoreProvider.overrideWithValue(illustStore),
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

/// Runs [change], then pumps until the widgets have no database call left.
/// The ffi database answers on the real loop, and a call the widgets made
/// in the fake zone, or one chained behind it (a tracker's next commit),
/// may still be running when a fixed number of rounds is over. Every such
/// call starts sqflite's lock-warning timer in the fake zone and cancels it
/// through a fake microtask once it holds the lock, so a pending microtask
/// shows one ran since the last pump. Each round pumps and queues a probe
/// on the database's FIFO lock: the widgets are done when the probe
/// completes without a pump and no call took the lock meanwhile. A probe
/// held back is pumped through before the next round. Two more frames
/// deliver the results.
Future<void> settleHistory(
  WidgetTester tester,
  HistoryRepository history, [
  Future<void> Function()? change,
]) => tester.runAsync(() async {
  await change?.call();
  var pumps = 0;
  Future<void> pump() {
    if (++pumps > 1000) throw StateError('history database never drained');
    return tester.pump();
  }

  while (true) {
    await pump();
    final probe = history.count(accountId: '100');
    var drained = false;
    probe.whenComplete(() => drained = true).ignore();
    final idle = await Future.any([
      probe.then((_) => true),
      Future<bool>.delayed(const Duration(milliseconds: 100), () => false),
    ]);
    if (idle && tester.binding.microtaskCount == 0) break;
    while (!drained) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await pump();
    }
  }
  for (var i = 0; i < 2; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
});

HistoryRecord historyRecord(
  int id, {
  HistoryContentType? type,
  String accountId = '100',
}) => HistoryRecord(
  accountId: accountId,
  contentType: type ?? HistoryContentType.illust,
  contentId: id,
  lastViewedAt: DateTime.utc(2026, 9, 20, 10),
  snapshot: HistorySnapshot(title: 'work $id', authorName: 'author $id'),
);
