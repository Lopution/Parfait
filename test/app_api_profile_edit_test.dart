import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/profile/app_api_profile_edit_repository.dart';
import 'package:pixiv_func/core/profile/profile_edit_models.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/core/user/user_repository.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _FakeUserRepository implements UserRepository {
  UserEntity detail = const UserEntity(
    id: 42,
    name: 'tester',
    account: 'tester',
  );

  @override
  Future<UserEntity> fetchDetail(
    int userId, {
    CancelToken? cancelToken,
  }) async => detail.copyWith(id: userId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not used by the profile edit adapter');
}

class _RecordedMultipart {
  _RecordedMultipart(this.request, this.body);

  final http.Request request;
  final List<int> body;
}

Future<(PixivHttpClient, ProviderContainer)> _client({
  required List<_RecordedMultipart> sent,
  int status = 200,
  String body = '{}',
}) async {
  final transport = MockClient((request) async {
    sent.add(_RecordedMultipart(request, request.bodyBytes));
    return http.Response(
      body,
      status,
      headers: {'content-type': 'application/json'},
    );
  });
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(
        FakeCredentialStore()..seed(
          '100',
          const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
        ),
      ),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient(
            (request) async => fail('refresh should not happen in this test'),
          ),
        ),
      ),
    ],
  );
  final client = PixivHttpClient(
    client: transport,
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: container.read(credentialStoreProvider),
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  return (client, container);
}

ProfileSubmitRequest _request(ProfilePatch patch) =>
    ProfileSubmitRequest(patch: patch);

ProfilePatch _textPatch({String name = 'novo nome'}) => ProfilePatch(
  accountId: '100',
  userId: 42,
  textFields: {ProfileField.displayName: name},
  images: const {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('capabilities advertise the app-api channel and fields', () async {
    final (client, container) = await _client(sent: []);
    addTearDown(container.dispose);
    final repo = PixivAppApiProfileEditRepository(
      client: client,
      userRepository: _FakeUserRepository(),
    );
    final capabilities = await repo.loadCapabilities(
      accountId: '100',
      userId: 42,
    );
    expect(capabilities.channel, ProfileEditChannel.appApi);
    expect(capabilities.isAvailable, isTrue);
    expect(capabilities.supports(ProfileField.displayName), isTrue);
    expect(capabilities.supports(ProfileField.comment), isTrue);
    expect(capabilities.supports(ProfileField.webpage), isTrue);
    expect(capabilities.supports(ProfileField.avatar), isTrue);
    expect(capabilities.supports(ProfileField.background), isFalse);
  });

  test('submit posts multipart user_name to v1/user/profile/edit', () async {
    final sent = <_RecordedMultipart>[];
    final (client, container) = await _client(sent: sent);
    addTearDown(container.dispose);
    final users = _FakeUserRepository();
    final repo = PixivAppApiProfileEditRepository(
      client: client,
      userRepository: users,
    );

    final outcome = await repo.submit(_request(_textPatch()));

    if (outcome is ProfileEditSubmitFailure) {
      fail('submit failed: ${outcome.code} ${outcome.message}');
    }
    expect(outcome, isA<ProfileEditConfirmed>());
    expect(sent, hasLength(1));
    final request = sent.single.request;
    expect(request.url.path, '/v1/user/profile/edit');
    expect(request.method, 'POST');
    expect(
      request.headers['content-type'],
      startsWith('multipart/form-data; boundary='),
    );
    expect(request.headers['authorization'], 'Bearer access-1');
    final body = utf8.decode(sent.single.body);
    expect(body, contains('Content-Disposition: form-data; name="user_name"'));
    expect(body, contains('novo nome'));
    // The web wire name must not leak into the app-api contract.
    expect(body, isNot(contains('name="name"')));
  });

  test('empty patch fails as invalid without touching the network', () async {
    final sent = <_RecordedMultipart>[];
    final (client, container) = await _client(sent: sent);
    addTearDown(container.dispose);
    final repo = PixivAppApiProfileEditRepository(
      client: client,
      userRepository: _FakeUserRepository(),
    );
    final outcome = await repo.submit(
      _request(
        ProfilePatch(
          accountId: '100',
          userId: 42,
          textFields: const {},
          images: const {},
        ),
      ),
    );
    expect(outcome, isA<ProfileEditSubmitFailure>());
    expect(
      (outcome as ProfileEditSubmitFailure).code,
      ProfileEditFailureCode.invalid,
    );
    expect(sent, isEmpty);
  });

  test(
    'a patch outside the channel fails unavailable without a request',
    () async {
      final sent = <_RecordedMultipart>[];
      final (client, container) = await _client(sent: sent);
      addTearDown(container.dispose);
      final repo = PixivAppApiProfileEditRepository(
        client: client,
        userRepository: _FakeUserRepository(),
      );
      final outcome = await repo.submit(
        _request(
          ProfilePatch(
            accountId: '100',
            userId: 42,
            textFields: const {},
            images: {ProfileField.background: _fakeSelection()},
          ),
        ),
      );
      expect(outcome, isA<ProfileEditSubmitFailure>());
      expect(
        (outcome as ProfileEditSubmitFailure).code,
        ProfileEditFailureCode.unavailable,
      );
      expect(sent, isEmpty);
    },
  );

  test(
    'a soft JSON error envelope on HTTP 200 surfaces as a failure',
    () async {
      final sent = <_RecordedMultipart>[];
      final (client, container) = await _client(
        sent: sent,
        body: jsonEncode({
          'error': {
            'user_message': 'invalid parameter',
            'message': '',
            'reason': '',
          },
        }),
      );
      addTearDown(container.dispose);
      final repo = PixivAppApiProfileEditRepository(
        client: client,
        userRepository: _FakeUserRepository(),
      );
      final outcome = await repo.submit(_request(_textPatch()));
      expect(outcome, isA<ProfileEditSubmitFailure>());
    },
  );

  test('avatar patch sends a profile_image file part', () async {
    final sent = <_RecordedMultipart>[];
    final (client, container) = await _client(sent: sent);
    addTearDown(container.dispose);
    final repo = PixivAppApiProfileEditRepository(
      client: client,
      userRepository: _FakeUserRepository(),
    );
    final file = await File(
      '${Directory.systemTemp.path}/avatar_test_${DateTime.now().microsecondsSinceEpoch}.jpg',
    ).create();
    await file.writeAsBytes(List.filled(128, 7));
    addTearDown(file.delete);

    final outcome = await repo.submit(
      _request(
        ProfilePatch(
          accountId: '100',
          userId: 42,
          textFields: const {},
          images: {
            ProfileField.avatar: ProfileImageSelection(
              path: file.path,
              mimeType: 'image/jpeg',
              sizeBytes: 128,
              width: 16,
              height: 16,
            ),
          },
        ),
      ),
    );

    expect(outcome, isA<ProfileEditConfirmed>());
    final body = utf8.decode(sent.single.body, allowMalformed: true);
    expect(
      body,
      contains('Content-Disposition: form-data; name="profile_image"'),
    );
    expect(body, contains('filename="profile_image.jpg"'));
  });
}

ProfileImageSelection _fakeSelection() => ProfileImageSelection(
  path: '/tmp/none',
  mimeType: 'image/jpeg',
  sizeBytes: 1,
  width: 1,
  height: 1,
);
