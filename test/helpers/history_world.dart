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
  bool signedOut = false,
}) async {
  final credentials = FakeCredentialStore();
  if (!signedOut) {
    credentials.seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  }
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        signedOut
            ? FakeAccountMetadataRepository()
            : FakeAccountMetadataRepository(
                accounts: const [
                  Account(id: '100', userId: 100, name: 'tester'),
                ],
                currentId: '100',
              ),
      ),
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

HistoryRecord historyRecord(int id, {HistoryContentType? type}) =>
    HistoryRecord(
      accountId: '100',
      contentType: type ?? HistoryContentType.illust,
      contentId: id,
      lastViewedAt: DateTime.utc(2026, 9, 20, 10),
      snapshot: HistorySnapshot(title: 'work $id', authorName: 'author $id'),
    );
