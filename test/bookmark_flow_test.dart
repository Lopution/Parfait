import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/bookmark/bookmark_actions.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_store.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/illust_fixtures.dart';

class _FakeCredentialStore implements CredentialStore {
  final _secrets = <String, Credential>{};

  void seed(String accountId, Credential credential) =>
      _secrets[accountId] = credential;

  @override
  Future<Credential?> read(String accountId) async => _secrets[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async =>
      _secrets[accountId] = credential;

  @override
  Future<void> delete(String accountId) async => _secrets.remove(accountId);
}

class _FakeMetadataRepository implements AccountMetadataRepository {
  @override
  Future<AccountMetadataSnapshot> load() async => const AccountMetadataSnapshot(
    accounts: [Account(id: '100', userId: 100, name: 'tester')],
    currentId: '100',
  );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

class _RecordedRequest {
  _RecordedRequest(this.method, this.uri, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> body;
}

/// HTTP transport recording bookmark calls; completion of each response can
/// be held back with [gate] to observe the pending phase.
class _BookmarkApiFixture {
  _BookmarkApiFixture({this.gate});

  final void Function(_RecordedRequest request)? gate;

  final List<_RecordedRequest> requests = [];

  int addStatus = 200;
  int deleteStatus = 200;

  http.Client build() {
    return MockClient((request) async {
      final recorded = _RecordedRequest(
        request.method,
        request.url,
        Uri.splitQueryString(request.body),
      );
      requests.add(recorded);
      gate?.call(recorded);
      final status = request.url.path.endsWith('/add')
          ? addStatus
          : deleteStatus;
      return http.Response(
        jsonEncode({'message': '', 'is_success': status == 200}),
        status,
        headers: {'content-type': 'application/json'},
      );
    });
  }
}

typedef World = (ProviderContainer, _BookmarkApiFixture);

Future<World> _makeWorld({
  void Function(_RecordedRequest request)? gate,
  int addStatus = 200,
  int deleteStatus = 200,
}) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final fixture = _BookmarkApiFixture(gate: gate)
    ..addStatus = addStatus
    ..deleteStatus = deleteStatus;
  final credentials = _FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        _FakeMetadataRepository(),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in this test');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) {
          throw StateError('client not wired yet');
        }
        return client;
      }),
    ],
  );
  final client = PixivHttpClient(
    client: fixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return (container, fixture);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test(
    'short press sends exactly one public add and confirms (R3/R4)',
    () async {
      final (container, fixture) = await _makeWorld();
      const key = BookmarkKey(BookmarkEntityType.illust, 42);

      await container.read(bookmarkActionsProvider).toggle(key);

      expect(fixture.requests, hasLength(1));
      expect(fixture.requests.single.uri.path, '/v2/illust/bookmark/add');
      expect(fixture.requests.single.body['illust_id'], '42');
      expect(fixture.requests.single.body['restrict'], 'public');
      expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isTrue);
      expect(container.read(bookmarkStoreProvider)[key]!.isPending, isFalse);
    },
  );

  test('short press on a bookmarked work sends delete (R6)', () async {
    final (container, fixture) = await _makeWorld();
    const key = BookmarkKey(BookmarkEntityType.illust, 42);
    container
        .read(bookmarkStoreProvider.notifier)
        .observeRemote(key, bookmarked: true, snapshotRevision: 0);

    await container.read(bookmarkActionsProvider).toggle(key);

    expect(fixture.requests.single.uri.path, '/v1/illust/bookmark/delete');
    expect(fixture.requests.single.body['illust_id'], '42');
    expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isFalse);
  });

  test('pending phase is observable and non-optimistic (R4)', () async {
    final inFlight = Completer<void>();
    final (container, fixture) = await _makeWorld(
      gate: (_) {
        if (!inFlight.isCompleted) inFlight.complete();
      },
    );
    const key = BookmarkKey(BookmarkEntityType.illust, 7);

    final action = container.read(bookmarkActionsProvider).toggle(key);
    await inFlight.future;

    final entry = container.read(bookmarkStoreProvider)[key]!;
    expect(entry.isPending, isTrue, reason: 'spinner phase observable');
    expect(entry.bookmarked, isFalse, reason: 'no optimistic flip');

    await action;
    expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isTrue);
  });

  test('failure restores the confirmed icon and surfaces error (R5)', () async {
    final (container, _) = await _makeWorld(addStatus: 500);
    const key = BookmarkKey(BookmarkEntityType.illust, 8);

    await container.read(bookmarkActionsProvider).toggle(key);

    final entry = container.read(bookmarkStoreProvider)[key]!;
    expect(entry.bookmarked, isFalse);
    expect(entry.isPending, isFalse);
    expect(entry.error, isNotNull);
  });

  test('rapid duplicate toggles fire only one request (R5)', () async {
    final (container, fixture) = await _makeWorld();
    const key = BookmarkKey(BookmarkEntityType.illust, 9);

    final first = container.read(bookmarkActionsProvider).toggle(key);
    final second = container.read(bookmarkActionsProvider).toggle(key);
    await first;
    await second;

    expect(fixture.requests, hasLength(1));
  });

  test('sheet confirm sends the chosen restrict (R3)', () async {
    final (container, fixture) = await _makeWorld();
    const key = BookmarkKey(BookmarkEntityType.illust, 10);

    await container
        .read(bookmarkActionsProvider)
        .addWithRestrict(key, BookmarkRestrict.private);

    expect(fixture.requests.single.uri.path, '/v2/illust/bookmark/add');
    expect(fixture.requests.single.body['restrict'], 'private');
    expect(
      container.read(bookmarkStoreProvider)[key]!.restrict,
      BookmarkRestrict.private,
    );
  });

  test(
    'feed merge gates a stale snapshot behind a local confirmation (R2)',
    () async {
      final (container, _) = await _makeWorld();
      const key = BookmarkKey(BookmarkEntityType.illust, 11);
      final store = container.read(illustStoreProvider);
      final bookmarks = container.read(bookmarkStoreProvider.notifier);

      // Entity arrives unbookmarked and merges before any local action.
      store.mergeAll([_entity(11, bookmarked: false)]);
      expect(store.get(11)!.isBookmarked, isFalse);

      // Local add confirms at revision R; a refetch that STARTED before R
      // must not clear it.
      await container.read(bookmarkActionsProvider).toggle(key);
      final staleRevision = bookmarks.revisionNow() - 1;
      store.mergeAll([
        _entity(11, bookmarked: false),
      ], bookmarkSnapshotRevision: staleRevision);
      expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isTrue);
      expect(
        store.get(11)!.isBookmarked,
        isTrue,
        reason: 'entity payload follows the canonical store',
      );

      // A refetch started after the confirmation is fresh and applies.
      store.mergeAll([
        _entity(11, bookmarked: false),
      ], bookmarkSnapshotRevision: bookmarks.revisionNow() + 1);
      expect(container.read(bookmarkStoreProvider)[key]!.bookmarked, isFalse);
    },
  );
}

IllustEntity _entity(int id, {required bool bookmarked}) =>
    parseIllust(illustJson(id, bookmarked: bookmarked));
