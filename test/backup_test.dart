import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/backup/backup_envelope.dart';
import 'package:pixiv_func/core/backup/backup_service.dart';
import 'package:pixiv_func/core/history/history_database.dart';
import 'package:pixiv_func/core/history/history_models.dart';
import 'package:pixiv_func/core/history/history_repository.dart';
import 'package:pixiv_func/core/mute/mute_models.dart';
import 'package:pixiv_func/core/mute/mute_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/platform/saf_tree.dart';
import 'package:pixiv_func/core/settings/preference_keys.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

/// Records every `/v1/mute/edit` body; `/v1/mute/list` answers from
/// [listTags]/[listUsers]. Mirrors the mute_store_test fixture.
class _MuteApiFixture {
  final edits = <Map<String, String>>[];

  Set<String> listTags = {};
  List<Map<String, dynamic>> listUsers = [];
  int editStatus = 200;

  http.Client build() => MockClient((request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/v1/mute/list')) {
      return http.Response(
        jsonEncode({
          'muted_tags': [
            for (final tag in listTags) {'tag': tag},
          ],
          'muted_users': listUsers,
          'mute_limit_count': 500,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/v1/mute/edit')) {
      edits.add(Uri.splitQueryString(request.body));
      return http.Response('{}', editStatus);
    }
    fail('unexpected ${request.method} ${request.url}');
  });
}

class _FakeTreePicker implements SafTreePicker {
  _FakeTreePicker(this.nextTree);

  String? nextTree;
  int picks = 0;

  @override
  Future<String?> pickTree() async {
    picks++;
    return nextTree;
  }
}

class _FakeSink implements SafDocumentSink {
  _FakeSink(this.uri, {this.failOnWrite = false});

  @override
  final String uri;
  final bool failOnWrite;
  final bytes = <int>[];
  var closed = false;
  var deleted = false;

  @override
  Future<void> write(List<int> chunk) async {
    if (failOnWrite) throw StateError('write failed');
    bytes.addAll(chunk);
  }

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> delete() async => deleted = true;
}

class _FakeSinkFactory implements SafDocumentSinkFactory {
  _FakeSink? last;
  String? lastTreeUri;
  String? lastDisplayName;
  String? lastMimeType;
  bool failOnWrite = false;

  @override
  Future<SafDocumentSink> create({
    required String treeUri,
    required String displayName,
    required String mimeType,
    Object? owner,
  }) async {
    lastTreeUri = treeUri;
    lastDisplayName = displayName;
    lastMimeType = mimeType;
    return last = _FakeSink('content://backup/1', failOnWrite: failOnWrite);
  }
}

typedef _World = ({
  ProviderContainer container,
  BackupService service,
  _MuteApiFixture api,
  _FakeSinkFactory sinks,
  _FakeTreePicker picker,
  HistoryRepository history,
});

Future<_World> _world({
  String? accountId = '100',
  Set<String> listTags = const {},
  List<Map<String, dynamic>> listUsers = const [],
  int editStatus = 200,
  Map<String, Object?>? seededSettings,
  List<HistoryRecord> seededHistory = const [],
  String? nextTree = 'tree-1',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences({
    if (seededSettings != null)
      PreferenceKeys.settings: jsonEncode(seededSettings),
  });

  final api = _MuteApiFixture()
    ..listTags = listTags
    ..listUsers = listUsers
    ..editStatus = editStatus;
  final accounts = accountId == null
      ? const <Account>[]
      : [Account(id: accountId, userId: 100, name: 'tester')];
  final credentials = FakeCredentialStore();
  if (accountId != null) {
    credentials.seed(
      accountId,
      const Credential(accessToken: 'access', refreshToken: 'refresh'),
    );
  }

  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      ...accountProviderOverrides(
        metadataRepository: FakeAccountMetadataRepository(
          accounts: accounts,
          currentId: accountId,
        ),
        credentialStore: credentials,
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((_) async => fail('no refresh expected')),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired');
        return client;
      }),
    ],
  );
  clientRef[0] = PixivHttpClient(
    client: api.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);

  final dir = await Directory.systemTemp.createTemp('pixiv-backup-test-');
  addTearDown(() => dir.delete(recursive: true));
  final database = HistoryDatabase(
    factory: databaseFactoryFfi,
    databasePath: p.join(dir.path, 'history.db'),
  );
  addTearDown(database.close);
  final history = HistoryRepository(database: database);
  if (accountId != null) {
    for (final record in seededHistory) {
      await history.upsert(record);
    }
  }

  final picker = _FakeTreePicker(nextTree);
  final sinks = _FakeSinkFactory();
  final service = BackupService(
    settingsReader: () => container.read(settingsProvider.future),
    settingsWriter: (settings) =>
        container.read(settingsProvider.notifier).replaceAll(settings),
    muteStore: container.read(muteStoreProvider.notifier),
    muteStateReader: () => container.read(muteStoreProvider),
    historyRepository: history,
    treePicker: picker,
    sinkFactory: sinks,
    currentAccountId: () => accountId,
    now: () => DateTime.utc(2026, 9, 20, 10, 30),
  );
  return (
    container: container,
    service: service,
    api: api,
    sinks: sinks,
    picker: picker,
    history: history,
  );
}

HistoryRecord _record(
  int contentId, {
  String accountId = '100',
  HistoryContentType type = HistoryContentType.illust,
  DateTime? lastViewedAt,
  String title = 'work',
}) {
  return HistoryRecord(
    accountId: accountId,
    contentType: type,
    contentId: contentId,
    lastViewedAt: lastViewedAt ?? DateTime.utc(2026, 9, 1),
    snapshot: HistorySnapshot(title: '$title $contentId', authorName: 'author'),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('BackupEnvelope', () {
    test('round-trips settings, mutes and history rows', () {
      final envelope = BackupEnvelope(
        exportedAt: DateTime.utc(2026, 9, 20, 10, 30),
        accountId: '100',
        settings: const {'languageTag': 'en-US', 'themeCode': 0},
        muteTags: {'nsfw', 'spoiler'},
        muteUsers: const [MutedUser(userId: 42, name: 'author', account: 'a')],
        muteWorkIds: {7, 9},
        history: [_record(5)],
      );

      final parsed = BackupEnvelope.parse(envelope.encode());

      expect(parsed.exportedAt, envelope.exportedAt);
      expect(parsed.accountId, '100');
      expect(parsed.settings['languageTag'], 'en-US');
      expect(parsed.muteTags, {'nsfw', 'spoiler'});
      expect(parsed.muteUsers.single.userId, 42);
      expect(parsed.muteUsers.single.account, 'a');
      expect(parsed.muteWorkIds, {7, 9});
      final row = parsed.history.single;
      expect(row.accountId, '100');
      expect(row.contentType, HistoryContentType.illust);
      expect(row.contentId, 5);
      expect(row.snapshot.title, 'work 5');
    });

    test('rejects garbage bytes', () {
      expect(
        () => BackupEnvelope.parse(utf8.encode('not json {')),
        throwsA(
          isA<BackupImportException>().having(
            (e) => e.code,
            'code',
            BackupImportErrorCode.notJson,
          ),
        ),
      );
    });

    test('rejects an unknown schema tag', () {
      final bytes = utf8.encode(jsonEncode({'schema': 'other.v9'}));
      expect(
        () => BackupEnvelope.parse(bytes),
        throwsA(
          isA<BackupImportException>().having(
            (e) => e.code,
            'code',
            BackupImportErrorCode.unknownSchema,
          ),
        ),
      );
    });

    test('rejects structurally malformed fields', () {
      Map<String, Object?> doc() => {
        'schema': BackupEnvelope.schema,
        'exportedAt': '2026-09-20T10:30:00Z',
      };

      for (final patch in [
        {'exportedAt': 42},
        {'settings': 'oops'},
        {'mutes': 'oops'},
        {
          'mutes': {
            'tags': [1],
          },
        },
        {
          'mutes': {
            'users': [
              {'userId': 'x', 'name': 'y'},
            ],
          },
        },
        {
          'mutes': {
            'workIds': [-1],
          },
        },
        {'history': 'oops'},
        {
          'history': [
            {'content_id': 'x'},
          ],
        },
      ]) {
        final json = doc()..addAll(patch);
        expect(
          () => BackupEnvelope.parse(utf8.encode(jsonEncode(json))),
          throwsA(isA<BackupImportException>()),
          reason: 'patch $patch must not parse',
        );
      }
    });

    test('fileName carries a timestamped json suffix', () {
      expect(
        BackupEnvelope.fileName(DateTime.utc(2026, 9, 20, 10, 5)),
        'pixiv-func-backup-20260920-1005.json',
      );
    });
  });

  group('BackupService export', () {
    test('writes the effective mute set and paged history to SAF', () async {
      final world = await _world(
        listTags: {'server-tag'},
        listUsers: [
          {'user_id': 42, 'user_name': 'author', 'user_account': 'a'},
        ],
        seededSettings: {'languageTag': 'ja'},
        seededHistory: [_record(1), _record(2), _record(3)],
      );
      final container = world.container;
      container.read(muteStoreProvider);
      final store = container.read(muteStoreProvider.notifier);
      await store.ensureHydrated();
      await store.toggleWork(7);
      await store.toggleTag('local-tag');

      final uri = await world.service.export();

      expect(uri, 'content://backup/1');
      expect(world.picker.picks, 1);
      expect(world.sinks.lastTreeUri, 'tree-1');
      expect(
        world.sinks.lastDisplayName,
        'pixiv-func-backup-20260920-1030.json',
      );
      expect(world.sinks.lastMimeType, 'application/json');

      final parsed = BackupEnvelope.parse(world.sinks.last!.bytes);
      expect(parsed.accountId, '100');
      expect(parsed.settings['languageTag'], 'ja-JP');
      expect(parsed.muteTags, containsAll(['server-tag', 'local-tag']));
      expect(parsed.muteUsers.single.userId, 42);
      expect(parsed.muteWorkIds, {7});
      expect(parsed.history.map((r) => r.contentId), containsAll([1, 2, 3]));
    });

    test('picker cancel produces no document', () async {
      final world = await _world(nextTree: null);
      expect(await world.service.export(), isNull);
      expect(world.sinks.last, isNull);
    });

    test('a failed write deletes the partial document and rethrows', () async {
      final world = await _world();
      world.sinks.failOnWrite = true;

      await expectLater(world.service.export(), throwsA(isA<StateError>()));
      expect(world.sinks.last!.deleted, isTrue);
    });
  });

  group('BackupService apply', () {
    test(
      'merge adds server mutes, unions work ids and keeps newer history',
      () async {
        final older = DateTime.utc(2026, 9, 1);
        final newer = DateTime.utc(2026, 9, 10);
        final world = await _world(
          listTags: {'existing-tag'},
          seededSettings: {'languageTag': 'en-US'},
          seededHistory: [
            _record(1, lastViewedAt: newer), // local is newer → kept
            _record(2, lastViewedAt: older), // import is newer → replaced
          ],
        );
        final container = world.container;
        container.read(muteStoreProvider);
        final store = container.read(muteStoreProvider.notifier);
        await store.ensureHydrated();
        await store.toggleWork(7); // pre-existing local work mute

        final envelope = BackupEnvelope(
          exportedAt: DateTime.utc(2026, 9, 20),
          accountId: 'other-account',
          settings: const {'languageTag': 'ja', 'enableLocalBlockR18': true},
          muteTags: {'existing-tag', 'imported-tag'},
          muteUsers: const [MutedUser(userId: 42, name: 'a')],
          muteWorkIds: {7, 9},
          history: [
            _record(1, accountId: 'other-account', lastViewedAt: older),
            _record(2, accountId: 'other-account', lastViewedAt: newer),
            _record(3, accountId: 'other-account', lastViewedAt: older),
          ],
        );

        final result = await world.service.apply(
          envelope,
          BackupImportStrategy.merge,
        );

        expect(result.tagsAdded, 1); // existing-tag skipped
        expect(result.usersAdded, 1);
        expect(result.workMutesChanged, 1); // only 9 added, 7 stays
        expect(result.historyRows, 2); // row 1 skipped (local newer)

        final mute = container.read(muteStoreProvider);
        expect(mute.tags, containsAll(['existing-tag', 'imported-tag']));
        expect(mute.users.keys, {42});
        expect(mute.workIds, {7, 9});
        expect(
          world.api.edits.where((e) => e.containsKey('add_tags[]')),
          hasLength(1),
        );

        final settings = container.read(settingsProvider).value!;
        expect(settings.languageTag, 'ja-JP');
        expect(settings.enableLocalBlockR18, isTrue);

        final rows = await world.history.page(accountId: '100', limit: 100);
        expect(rows.total, 3);
        final byId = {for (final r in rows.records) r.contentId: r};
        // Imported rows land under the *current* account.
        expect(byId.values.every((r) => r.accountId == '100'), isTrue);
        expect(byId[1]!.lastViewedAt, newer);
        expect(byId[2]!.lastViewedAt, newer);
        expect(byId[3]!.lastViewedAt, older);
      },
    );

    test(
      'overwrite replaces local work mutes and clears history first',
      () async {
        final world = await _world(seededHistory: [_record(1), _record(2)]);
        final container = world.container;
        container.read(muteStoreProvider);
        final store = container.read(muteStoreProvider.notifier);
        await store.ensureHydrated();
        await store.toggleWork(7); // not in the import → removed
        await store.toggleWork(8); // in the import → kept

        final envelope = BackupEnvelope(
          exportedAt: DateTime.utc(2026, 9, 20),
          settings: const {'languageTag': 'ru'},
          muteWorkIds: {8, 9},
          history: [_record(9, accountId: 'other', title: 'imported')],
        );

        final result = await world.service.apply(
          envelope,
          BackupImportStrategy.overwrite,
        );

        expect(result.workMutesChanged, 2); // +9, -7
        expect(result.historyRows, 1);
        expect(container.read(muteStoreProvider).workIds, {8, 9});

        final rows = await world.history.page(accountId: '100', limit: 100);
        expect(rows.total, 1);
        expect(rows.records.single.contentId, 9);
        expect(rows.records.single.snapshot.title, 'imported 9');
        expect(container.read(settingsProvider).value!.languageTag, 'ru-RU');
      },
    );

    test('import without a usable account fails visibly', () async {
      final world = await _world(accountId: null);

      final envelope = BackupEnvelope(
        exportedAt: DateTime.utc(2026, 9, 20),
        settings: const {},
      );
      await expectLater(
        world.service.apply(envelope, BackupImportStrategy.merge),
        throwsA(
          isA<BackupImportException>().having(
            (e) => e.code,
            'code',
            BackupImportErrorCode.accountRequired,
          ),
        ),
      );
    });

    test('a failed server mute edit aborts before local writes', () async {
      final world = await _world(
        editStatus: 500,
        seededSettings: {'languageTag': 'en-US'},
      );
      world.container.read(muteStoreProvider);
      await world.container.read(muteStoreProvider.notifier).ensureHydrated();

      final envelope = BackupEnvelope(
        exportedAt: DateTime.utc(2026, 9, 20),
        settings: const {'languageTag': 'ja'},
        muteTags: {'boom-tag'},
        history: [_record(1)],
      );

      await expectLater(
        world.service.apply(envelope, BackupImportStrategy.merge),
        throwsA(anything),
      );
      // Settings and history were not touched by the failed import.
      expect(
        (await world.container.read(settingsProvider.future)).languageTag,
        'en-US',
      );
      expect((await world.history.page(accountId: '100')).total, 0);
    });
  });
}
