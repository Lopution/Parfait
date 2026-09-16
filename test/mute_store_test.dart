import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/mute/mute_models.dart';
import 'package:pixiv_func/core/mute/mute_predicate.dart';
import 'package:pixiv_func/core/mute/mute_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/settings/preference_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

/// Mute API transport: serves `/v1/mute/list` from [listTags]/[listUsers]
/// and records every `/v1/mute/edit` body for assertions.
class _MuteApiFixture {
  final List<Map<String, String>> edits = [];

  Set<String> listTags = {};
  List<Map<String, dynamic>> listUsers = [];
  int listStatus = 200;
  int editStatus = 200;

  http.Client build() {
    return MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith('/v1/mute/list')) {
        return http.Response(
          jsonEncode({
            'muted_tags': [
              for (final tag in listTags) {'tag': tag, 'tag_translation': ''},
            ],
            'muted_users': listUsers,
            'mute_limit_count': 500,
          }),
          listStatus,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/v1/mute/edit')) {
        edits.add(Uri.splitQueryString(request.body));
        return http.Response(
          jsonEncode({'error': listStatus == 200 ? null : 'x'}),
          editStatus,
          headers: {'content-type': 'application/json'},
        );
      }
      fail('unexpected ${request.method} ${request.url}');
    });
  }
}

typedef World = (ProviderContainer, _MuteApiFixture, SharedPreferencesAsync);

Future<World> _makeWorld({
  Set<String> listTags = const {},
  List<Map<String, dynamic>> listUsers = const [],
  List<String> legacyBlockedTags = const [],
  int listStatus = 200,
  int editStatus = 200,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences({
    if (legacyBlockedTags.isNotEmpty)
      PreferenceKeys.blockedTags: legacyBlockedTags,
  });
  final prefs = SharedPreferencesAsync();
  final fixture = _MuteApiFixture()
    ..listTags = listTags
    ..listUsers = listUsers
    ..listStatus = listStatus
    ..editStatus = editStatus;
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
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in this test');
          }),
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
    client: fixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return (container, fixture, prefs);
}

/// Waits until [condition] holds or the deadline passes. Hydration is
/// async work fired from build(), so assertions poll instead of assuming
/// a fixed number of event-loop turns.
Future<void> _until(
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 10),
  int maxTurns = 200,
}) async {
  for (var i = 0; i < maxTurns; i++) {
    if (condition()) return;
    await Future<void>.delayed(step);
  }
  fail('condition not met within ${maxTurns * step.inMilliseconds}ms');
}

void main() {
  test('hydrate merges server tags/users and marks synced', () async {
    final (container, _, _) = await _makeWorld(
      listTags: {'nsfw-tag'},
      listUsers: [
        {
          'user_id': 42,
          'user_name': 'muted-author',
          'user_account': 'ma',
          'user_profile_image_urls': {'medium': 'https://i.pximg.net/u.jpg'},
        },
      ],
    );
    container.read(muteStoreProvider);
    await _until(() => container.read(muteStoreProvider).serverSynced);

    final state = container.read(muteStoreProvider);
    expect(state.tags, contains('nsfw-tag'));
    expect(state.users[42]?.name, 'muted-author');
  });

  test(
    'legacy blocked tags migrate: effective immediately, pushed once',
    () async {
      final (container, fixture, prefs) = await _makeWorld(
        listTags: {'already-remote'},
        legacyBlockedTags: ['already-remote', 'legacy-only'],
      );
      container.read(muteStoreProvider);
      await _until(
        () =>
            container.read(muteStoreProvider).serverSynced &&
            fixture.edits.isNotEmpty,
      );
      await _until(
        () => container.read(muteStoreProvider).legacyTagsPending.isEmpty,
      );

      final state = container.read(muteStoreProvider);
      expect(state.tags, containsAll(['already-remote', 'legacy-only']));
      // Only the tag missing server-side is pushed.
      expect(fixture.edits, hasLength(1));
      expect(fixture.edits.single['add_tags[]'], 'legacy-only');
      expect(await prefs.getStringList(PreferenceKeys.blockedTags), isNull);
    },
  );

  test('failed migration keeps legacy tags effective and pending', () async {
    final (container, _, prefs) = await _makeWorld(
      legacyBlockedTags: ['legacy'],
      editStatus: 500,
    );
    container.read(muteStoreProvider);
    await _until(() => container.read(muteStoreProvider).serverSynced);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(muteStoreProvider);
    expect(state.tags, contains('legacy'));
    expect(state.legacyTagsPending, {'legacy'});
    // Pref survives so the next session retries the push.
    expect(await prefs.getStringList(PreferenceKeys.blockedTags), ['legacy']);
  });

  test('offline hydrate keeps local mutes effective', () async {
    final (container, _, _) = await _makeWorld(listStatus: 500);
    final store = container.read(muteStoreProvider.notifier);
    container.read(muteStoreProvider);
    await store.toggleWork(7);
    await _until(() => container.read(muteStoreProvider).pending.isEmpty);

    final state = container.read(muteStoreProvider);
    expect(state.serverSynced, isFalse);
    expect(state.workIds, {7});
  });

  test('work mute persists per account and toggles off', () async {
    final (container, _, prefs) = await _makeWorld();
    final store = container.read(muteStoreProvider.notifier);
    await store.toggleWork(7);
    await store.toggleWork(9);
    await store.toggleWork(7);

    expect(container.read(muteStoreProvider).workIds, {9});
    final raw = await prefs.getString('muted_works_100');
    expect(jsonDecode(raw!), [9]);
  });

  test('tag toggle is optimistic and issues the wire edit', () async {
    final (container, fixture, _) = await _makeWorld();
    container.read(muteStoreProvider);
    await _until(() => container.read(muteStoreProvider).serverSynced);

    await container.read(muteStoreProvider.notifier).toggleTag('bad-tag');
    expect(container.read(muteStoreProvider).tags, contains('bad-tag'));
    expect(fixture.edits.single['add_tags[]'], 'bad-tag');

    await container.read(muteStoreProvider.notifier).toggleTag('bad-tag');
    expect(container.read(muteStoreProvider).tags, isNot(contains('bad-tag')));
    expect(fixture.edits.last['delete_tags[]'], 'bad-tag');
  });

  test(
    'failed tag edit rolls the optimistic state back and rethrows',
    () async {
      final (container, _, _) = await _makeWorld(editStatus: 500);
      container.read(muteStoreProvider);
      await _until(() => container.read(muteStoreProvider).serverSynced);

      await expectLater(
        container.read(muteStoreProvider.notifier).toggleTag('x'),
        throwsA(anything),
      );
      expect(container.read(muteStoreProvider).tags, isNot(contains('x')));
      expect(container.read(muteStoreProvider).pending, isEmpty);
    },
  );

  test('user toggle uses user_ids fields', () async {
    final (container, fixture, _) = await _makeWorld();
    const user = MutedUser(userId: 42, name: 'author', account: 'a');
    await container.read(muteStoreProvider.notifier).toggleUser(user);
    expect(container.read(muteStoreProvider).users.keys, {42});
    expect(fixture.edits.single['add_user_ids[]'], '42');

    await container.read(muteStoreProvider.notifier).toggleUser(user);
    expect(container.read(muteStoreProvider).users, isEmpty);
    expect(fixture.edits.last['delete_user_ids[]'], '42');
  });

  group('muteHitFor', () {
    IllustEntity entity({int id = 1, int userId = 42, String tag = 'nsfw'}) {
      final json = illustJson(id)
        ..['user'] = {
          'id': userId,
          'name': 'author',
          'account': 'a',
          'profile_image_urls': <String, String>{},
        }
        ..['tags'] = [
          {'name': tag},
        ];
      return parseIllust(json);
    }

    test('work > user > tag precedence', () {
      const state = MuteState(
        tags: {'nsfw'},
        users: {42: MutedUser(userId: 42, name: 'author')},
        workIds: {1},
      );
      expect(muteHitFor(entity(), state)?.kind, MuteKind.work);
      expect(muteHitFor(entity(id: 2), state)?.kind, MuteKind.user);
      expect(muteHitFor(entity(id: 2, userId: 7), state)?.kind, MuteKind.tag);
      expect(muteHitFor(entity(id: 2, userId: 7, tag: 'ok'), state), isNull);
    });
  });
}
