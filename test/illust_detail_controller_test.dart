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
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/entity/illust_store.dart';
import 'package:pixiv_func/features/illust/detail/illust_detail_controller.dart';
import 'package:pixiv_func/features/search/tag_search_repository.dart';
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
  Future<AccountMetadataSnapshot> load() async =>
      const AccountMetadataSnapshot(
        accounts: [Account(id: '100', userId: 100, name: 'tester')],
        currentId: '100',
      );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

/// Drives PixivHttpClient with a scripted API transport.
Future<ProviderContainer> makeContainer(
  Future<http.Response> Function(http.Request request) handler,
) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final credentials = _FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(overrides: [
    credentialStoreProvider.overrideWithValue(credentials),
    accountMetadataRepositoryProvider
        .overrideWithValue(_FakeMetadataRepository()),
    oauthServiceProvider.overrideWithValue(
      OAuthService(
        client: MockClient((request) async =>
            throw StateError('refresh must not happen in these tests')),
      ),
    ),
    pixivHttpClientProvider.overrideWith((ref) {
      final client = clientRef[0];
      if (client == null) {
        throw StateError('client not wired yet');
      }
      return client;
    }),
  ]);
  final client = PixivHttpClient(
    client: MockClient(handler),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  clientRef[0] = client;
  await container.read(accountStoreProvider.future);
  return container;
}

http.Response okJson(Map<String, dynamic> json) => http.Response(
      jsonEncode(json),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('detail fetch merges the store and reports ready', () async {
    final container = await makeContainer((request) async {
      expect(request.url.path, '/v1/illust/detail');
      expect(request.url.queryParameters['illust_id'], '42');
      return okJson({
        'illust': illustJson(42, pageCount: 2, withMetaPages: true),
      });
    });
    addTearDown(container.dispose);

    final state = await container.read(illustDetailControllerProvider(42).future);
    expect(state, isA<IllustDetailReady>());
    final entity = container.read(illustStoreProvider).get(42)!;
    expect(entity.metaPages, hasLength(2));
    expect(entity.title, 'illust 42');
  });

  test('snapshot-first: store snapshot is renderable during the fetch',
      () async {
    final container = await makeContainer((request) async {
      await Future<void>.delayed(const Duration(seconds: 30));
      return okJson({'illust': illustJson(7)});
    });
    addTearDown(container.dispose);

    // Seed the store snapshot: the page renders this while loading.
    container.read(illustStoreProvider).mergeAll([
      parseIllust(illustJson(7, bookmarked: true)),
    ]);

    // Start the fetch without awaiting it.
    final provider = illustDetailControllerProvider(7);
    container.listen(provider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final async = container.read(provider);
    expect(async.isLoading, isTrue,
        reason: 'fetch in flight');
    final snapshot = container.read(illustStoreProvider).get(7)!;
    expect(snapshot.isBookmarked, isTrue,
        reason: 'R1: page renders the stale snapshot while loading');
  });

  test('404 maps to NotFound, not a generic error', () async {
    final container = await makeContainer((request) async {
      return http.Response('not found', 404);
    });
    addTearDown(container.dispose);
    final state = await container.read(illustDetailControllerProvider(9).future);
    expect(state, isA<IllustDetailNotFound>());
  });

  test('visible:false maps to Restricted', () async {
    final container = await makeContainer((request) async {
      return okJson({'illust': illustJson(11, visible: false)});
    });
    addTearDown(container.dispose);
    final state =
        await container.read(illustDetailControllerProvider(11).future);
    expect(state, isA<IllustDetailRestricted>());
  });

  test('network failure with snapshot keeps rendering data behind error',
      () async {
    final container = await makeContainer((request) async {
      throw http.ClientException('offline');
    });
    addTearDown(container.dispose);
    container.read(illustStoreProvider).mergeAll([
      parseIllust(illustJson(5, bookmarked: true)),
    ]);
    final state =
        await container.read(illustDetailControllerProvider(5).future);
    expect(state, isA<IllustDetailError>());
    final error = state as IllustDetailError;
    expect(error.hasSnapshot, isTrue);
    expect(error.snapshot!.id, 5);
  });

  test('network failure without snapshot surfaces retryable error', () async {
    var attempts = 0;
    final container = await makeContainer((request) async {
      attempts++;
      throw http.ClientException('offline');
    });
    addTearDown(container.dispose);
    final controller =
        container.read(illustDetailControllerProvider(6).notifier);
    final state = await container.read(illustDetailControllerProvider(6).future);
    expect(state, isA<IllustDetailError>());
    expect((state as IllustDetailError).hasSnapshot, isFalse);

    // reload re-runs the fetch.
    await controller.reload();
    final after = container.read(illustDetailControllerProvider(6)).value;
    expect(after, isA<IllustDetailError>());
    expect(attempts, 2);
  });

  test('tag search controller queries partial_match_for_tags and merges',
      () async {
    final container = await makeContainer((request) async {
      expect(request.url.path, '/v1/search/illust');
      expect(request.url.queryParameters['search_target'],
          'partial_match_for_tags');
      expect(request.url.queryParameters['word'], '風景');
      return okJson({
        'illusts': [illustJson(77), illustJson(78)],
        'next_url': null,
      });
    });
    addTearDown(container.dispose);

    final state =
        await container.read(tagSearchControllerProvider('風景').future);
    expect(state.showInitialError, isFalse);
    expect(state.ids, [77, 78]);
    expect(container.read(illustStoreProvider).get(77), isNotNull,
        reason: 'tag results merge into the shared store');
  });
}
