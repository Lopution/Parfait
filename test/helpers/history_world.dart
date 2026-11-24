import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

import 'fake_account.dart';
import 'image_network.dart';

/// A real history repository on an in-memory no-isolate FFI database holding
/// [records], closed at teardown.
Future<HistoryRepository> openHistoryRepository(
  List<HistoryRecord> records,
) async {
  // Under FLUTTER_TEST, default HistoryDatabase uses databaseFactoryFfiNoIsolate
  // with an isolated in-memory database (singleInstance: false) so reads and
  // writes complete on microtasks without spawning a background SQLite isolate
  // or touching disk.
  final database = HistoryDatabase();
  addTearDown(database.close);
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

/// Runs [change], then drains both real-zone and fake-zone microtasks until
/// every in-memory no-isolate history database query and resulting frame has
/// settled.
///
/// Databases opened inside `tester.runAsync` schedule their `sqflite` lock
/// continuations on the real zone, while widgets query them from the fake
/// zone; alternating zero-delay real-loop yields with `tester.pump()` drains
/// both zones in sub-millisecond time without deadlocking `_rawLock`.
Future<void> settleHistory(
  WidgetTester tester,
  HistoryRepository history, [
  Future<void> Function()? change,
]) async {
  Future<void> drain() async {
    var quietTurns = 0;
    for (var i = 0; i < 64; i++) {
      await tester.pump();
      Object? probeError;
      StackTrace? probeStack;
      final idle = await tester.runAsync(() async {
        // Yield once so real-zone continuations from widget queries complete
        // before probing the FIFO lock.
        await Future<void>.delayed(Duration.zero);
        final probe = history.count(accountId: '100');
        var done = false;
        unawaited(
          probe.then(
            (_) => done = true,
            onError: (Object error, StackTrace stack) {
              probeError = error;
              probeStack = stack;
              done = true;
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        return done;
      });
      if (probeError != null) {
        Error.throwWithStackTrace(probeError!, probeStack!);
      }
      await tester.pump();
      if (idle == true && tester.binding.microtaskCount == 0) {
        quietTurns += 1;
        if (quietTurns >= 2) {
          // Flush any zero-duration timers scheduled during layout (e.g.
          // EasyRefresh's ballistic simulation check) on the final frame.
          await tester.pump(Duration.zero);
          return;
        }
      } else {
        quietTurns = 0;
      }
    }
    throw StateError('history database never drained');
  }

  await drain();
  if (change != null) {
    await tester.runAsync(change);
    await drain();
  }
}

HistoryRecord historyRecord(
  int id, {
  HistoryContentType? type,
  String accountId = '100',
  String? title,
  String? authorName,
  int? authorId,
  String? tagsText,
}) => HistoryRecord(
  accountId: accountId,
  contentType: type ?? HistoryContentType.illust,
  contentId: id,
  lastViewedAt: DateTime.utc(2026, 9, 20, 10),
  snapshot: HistorySnapshot(
    title: title ?? 'work $id',
    authorName: authorName ?? 'author $id',
    authorId: authorId,
    tagsText: tagsText,
  ),
);
