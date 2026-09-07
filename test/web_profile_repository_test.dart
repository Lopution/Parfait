import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/profile/profile_edit_models.dart';
import 'package:pixiv_func/core/profile/web_profile_repository.dart';
import 'package:pixiv_func/core/profile/web_profile_session.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/core/user/user_repository.dart';

class _FakeSession implements WebProfileSession {
  _FakeSession(this.cookie);

  String? cookie;

  @override
  Future<String?> readSessionCookie() async => cookie;

  @override
  Future<bool> clearSession() async {
    cookie = null;
    return true;
  }
}

void main() {
  group('hasWebProfileSession', () {
    test('empty/null cookie is not a session', () {
      expect(hasWebProfileSession(null), isFalse);
      expect(hasWebProfileSession(''), isFalse);
      expect(hasWebProfileSession('device_token=abc'), isFalse);
    });

    test('PHPSESSID cookie is a session', () {
      expect(
        hasWebProfileSession(
          'PHPSESSID=0123456789abcdef0123456789abcdef01234567; '
          'device_token=xyz',
        ),
        isTrue,
      );
    });

    test('does not use unrelated or empty cookie values as a session', () {
      expect(hasWebProfileSession('PHPSESSID='), isFalse);
      expect(hasWebProfileSession('PHPSESSID ; device_token=abc'), isFalse);
      expect(hasWebProfileSession('device_token=abc; foo=bar'), isFalse);
    });
  });

  group('PixivWebProfileEditRepository capabilities', () {
    test('no session -> unavailable with in-app session guidance', () async {
      final repo = PixivWebProfileEditRepository(
        userRepository: _StubUserRepository(),
        session: _FakeSession(null),
      );
      final capabilities = await repo.loadCapabilities(
        accountId: 'a',
        userId: 1,
      );
      expect(capabilities.channel, ProfileEditChannel.unavailable);
      expect(capabilities.editableFields, isEmpty);
      expect(capabilities.reason, contains('In-app'));
    });

    test('with a session -> web channel with the five fields', () async {
      final repo = PixivWebProfileEditRepository(
        userRepository: _StubUserRepository(),
        session: _FakeSession(
          'PHPSESSID=0123456789abcdef0123456789abcdef01234567',
        ),
      );
      final capabilities = await repo.loadCapabilities(
        accountId: 'a',
        userId: 1,
      );
      expect(capabilities.channel, ProfileEditChannel.web);
      expect(capabilities.supports(ProfileField.displayName), isTrue);
      expect(capabilities.supports(ProfileField.comment), isTrue);
      expect(capabilities.supports(ProfileField.webpage), isTrue);
      expect(capabilities.supports(ProfileField.avatar), isTrue);
      expect(capabilities.supports(ProfileField.background), isTrue);
    });
  });

  group('submit without session', () {
    test('fails as unavailable instead of touching the network', () async {
      final repo = PixivWebProfileEditRepository(
        userRepository: _StubUserRepository(),
        session: _FakeSession(null),
      );
      final outcome = await repo.submit(
        ProfileSubmitRequest(
          patch: ProfilePatch(
            accountId: 'a',
            userId: 1,
            textFields: {ProfileField.displayName: 'NewName'},
            images: const {},
          ),
        ),
      );
      expect(outcome, isA<ProfileEditSubmitFailure>());
      final failure = outcome as ProfileEditSubmitFailure;
      expect(failure.code, ProfileEditFailureCode.unavailable);
      expect(failure.retryable, isTrue);
    });
  });

  group('current Pixiv web profile protocol', () {
    test('round-trips the profile and posts multipart update', () async {
      const cookie =
          'PHPSESSID=0123456789abcdef0123456789abcdef01234567; '
          'device_token=xyz';
      final client = _RecordingWebClient([
        const _QueuedWebResponse(
          200,
          '<script>window.__NEXT_DATA__={'
          '"serverSerializedPreloadedState":'
          '"{\\"api\\":{\\"token\\":\\"csrf-42\\"}}"}'
          '</script>',
        ),
        const _QueuedWebResponse(
          200,
          '{"error":false,"body":{'
          '"name":"OldName","comment":"Old comment",'
          '"webpage":"https://old.example",'
          '"gender":"","birthYear":"",'
          '"externalServiceList":[]}}',
        ),
        const _QueuedWebResponse(200, '{"error":false,"body":{}}'),
      ]);
      final userRepository = _StubUserRepository();
      final repository = PixivWebProfileEditRepository(
        userRepository: userRepository,
        session: _FakeSession(cookie),
        httpClient: client,
      );
      await repository.loadDraft(accountId: 'a', userId: 1);

      final outcome = await repository.submit(
        ProfileSubmitRequest(
          patch: ProfilePatch(
            accountId: 'a',
            userId: 1,
            textFields: {
              ProfileField.displayName: 'NewName',
              ProfileField.comment: 'New comment',
            },
            images: const {},
          ),
        ),
      );

      expect(outcome, isA<ProfileEditConfirmed>());
      expect(client.requests, hasLength(3));
      expect(
        client.requests[0].url.toString(),
        PixivWebProfileEditRepository.settingsUrl,
      );
      expect(client.requests[1].url.path, '/ajax/my_profile');
      expect(client.requests[1].url.queryParameters['lang'], 'zh');
      expect(client.requests[2].url.path, '/ajax/my_profile/update');
      expect(client.requests[2].method, 'POST');
      expect(client.requests[2].headers['cookie'], cookie);
      expect(client.requests[2].headers['x-csrf-token'], 'csrf-42');
      expect(
        client.requests[2].headers['content-type'],
        startsWith('multipart/form-data; boundary='),
      );
      final body = utf8.decode(client.requests[2].bodyBytes);
      expect(body, isNot(contains('name="tt"')));
      expect(client.requests[1].headers['x-csrf-token'], 'csrf-42');
      expect(body, contains('name="profile"'));
      expect(body, contains('"name":"NewName"'));
      expect(body, contains('"comment":"New comment"'));
      expect(body, contains('"gender":""'));
      expect(body, isNot(contains('nickname')));
    });

    test('uploads selected images and clears matching JSON image URLs', () async {
      final directory = await Directory.systemTemp.createTemp(
        'pixiv-profile-image-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final avatarFile = File('${directory.path}/avatar.png');
      await avatarFile.writeAsBytes(const [0x41, 0x42, 0x43]);
      final coverFile = File('${directory.path}/cover.jpg');
      await coverFile.writeAsBytes(const [0x44, 0x45, 0x46]);

      final client = _RecordingWebClient([
        const _QueuedWebResponse(
          200,
          '<meta name="csrf-token" content="csrf-images">',
        ),
        const _QueuedWebResponse(
          200,
          '{"error":false,"body":{'
          '"name":"OldName","profileImage":"old-avatar",'
          '"coverImage":"old-cover","comment":""}}',
        ),
        const _QueuedWebResponse(200, '{"error":false,"body":null}'),
      ]);
      final repository = PixivWebProfileEditRepository(
        userRepository: _StubUserRepository(),
        session: _FakeSession(
          'PHPSESSID=0123456789abcdef0123456789abcdef01234567',
        ),
        httpClient: client,
      );

      final outcome = await repository.submit(
        ProfileSubmitRequest(
          patch: ProfilePatch(
            accountId: 'a',
            userId: 1,
            textFields: const {},
            images: {
              ProfileField.avatar: ProfileImageSelection(
                path: avatarFile.path,
                mimeType: 'image/png',
                sizeBytes: 3,
                width: 1,
                height: 1,
              ),
              ProfileField.background: ProfileImageSelection(
                path: coverFile.path,
                mimeType: 'image/jpeg',
                sizeBytes: 3,
                width: 1,
                height: 1,
              ),
            },
          ),
        ),
      );

      expect(outcome, isA<ProfileEditConfirmed>());
      final body = utf8.decode(client.requests[2].bodyBytes);
      expect(body, contains('name="profile_image"'));
      expect(body, contains('name="cover_image"'));
      expect(body, contains('filename="profile_profile_image.png"'));
      expect(body, contains('filename="profile_cover_image.jpg"'));
      expect(body, contains('"profileImage":null'));
      expect(body, contains('"coverImage":null'));
      expect(body, contains('ABC'));
      expect(body, contains('DEF'));
    });

    test(
      'does not report success when update envelope contains an error',
      () async {
        final client = _RecordingWebClient([
          const _QueuedWebResponse(
            200,
            '<meta name="csrf-token" content="csrf-42">',
          ),
          const _QueuedWebResponse(
            200,
            '{"error":false,"body":{"name":"OldName"}}',
          ),
          const _QueuedWebResponse(
            200,
            '{"error":true,"message":"invalid profile"}',
          ),
        ]);
        final repository = PixivWebProfileEditRepository(
          userRepository: _StubUserRepository(),
          session: _FakeSession(
            'PHPSESSID=0123456789abcdef0123456789abcdef01234567',
          ),
          httpClient: client,
        );

        final outcome = await repository.submit(
          ProfileSubmitRequest(
            patch: ProfilePatch(
              accountId: 'a',
              userId: 1,
              textFields: {ProfileField.displayName: 'NewName'},
              images: const {},
            ),
          ),
        );

        expect(outcome, isA<ProfileEditSubmitFailure>());
        expect(
          (outcome as ProfileEditSubmitFailure).message,
          contains('invalid profile'),
        );
      },
    );

    test('keeps the local draft when App API refresh fails after save', () async {
      const cookie =
          'PHPSESSID=0123456789abcdef0123456789abcdef01234567';
      final client = _RecordingWebClient([
        const _QueuedWebResponse(
          200,
          '<meta name="csrf-token" content="csrf-42">',
        ),
        const _QueuedWebResponse(
          200,
          '{"error":false,"body":{"name":"OldName","comment":""}}',
        ),
        const _QueuedWebResponse(200, '{"error":false,"body":{}}'),
      ]);
      final users = _StubUserRepository(
        user: const UserEntity(
          id: 1,
          name: 'OldName',
          account: 'test',
          comment: 'kept bio',
          webpage: 'https://old.example',
          hasDetail: true,
        ),
        failFetchAfter: 1,
      );
      final repository = PixivWebProfileEditRepository(
        userRepository: users,
        session: _FakeSession(cookie),
        httpClient: client,
      );
      await repository.loadDraft(accountId: 'a', userId: 1);

      final outcome = await repository.submit(
        ProfileSubmitRequest(
          patch: ProfilePatch(
            accountId: 'a',
            userId: 1,
            textFields: {ProfileField.displayName: 'NewName'},
            images: const {},
          ),
        ),
      );

      expect(outcome, isA<ProfileEditConfirmed>());
      final confirmed = outcome as ProfileEditConfirmed;
      expect(confirmed.user.name, 'NewName');
      expect(confirmed.user.comment, 'kept bio');
      expect(confirmed.user.webpage, 'https://old.example');
      expect(users.fetchCount, 2);
    });
  });

  group('cancellation', () {
    test('pre-cancelled token is rethrown as ApiCancelled', () async {
      final token = CancelToken()..cancel();
      final repository = PixivWebProfileEditRepository(
        userRepository: _StubUserRepository(),
        session: _FakeSession(
          'PHPSESSID=0123456789abcdef0123456789abcdef01234567',
        ),
        httpClient: _RecordingWebClient(const []),
      );

      await expectLater(
        repository.submit(
          ProfileSubmitRequest(
            patch: ProfilePatch(
              accountId: 'a',
              userId: 1,
              textFields: {ProfileField.displayName: 'NewName'},
              images: const {},
            ),
          ),
          cancelToken: token,
        ),
        throwsA(isA<ApiCancelled>()),
      );
    });

    test('request abort is rethrown as ApiCancelled', () async {
      final repository = PixivWebProfileEditRepository(
        userRepository: _StubUserRepository(),
        session: _FakeSession(
          'PHPSESSID=0123456789abcdef0123456789abcdef01234567',
        ),
        httpClient: _AbortingWebClient(),
      );

      await expectLater(
        repository.submit(
          ProfileSubmitRequest(
            patch: ProfilePatch(
              accountId: 'a',
              userId: 1,
              textFields: {ProfileField.displayName: 'NewName'},
              images: const {},
            ),
          ),
        ),
        throwsA(isA<ApiCancelled>()),
      );
    });
  });

  group('web settings page parsing', () {
    test('csrf token from meta tag', () {
      final token = extractWebCsrfToken(
        '<html><head><meta name="csrf-token" content="T0KEN123">'
        '</head></html>',
      );
      expect(token, 'T0KEN123');
    });

    test('csrf token from hidden input', () {
      final token = extractWebCsrfToken(
        '<form><input type="hidden" name="ct" value="CSRF-42"></form>',
      );
      expect(token, 'CSRF-42');
    });

    test('csrf token from escaped serialized SPA state', () {
      final token = extractWebCsrfToken(
        '"serverSerializedPreloadedState":'
        '"{\\"api\\":{\\"token\\":\\"SPA-TOKEN\\"}}"',
      );
      expect(token, 'SPA-TOKEN');
    });

    test('current values from inputs and textarea', () {
      final values = extractWebCurrentValues(
        '<input name="nickname" value="OldName">'
        '<textarea name="comment">Hello &amp; bye</textarea>',
      );
      expect(values['nickname'], 'OldName');
      expect(values['comment'], 'Hello & bye');
    });

    test('malformed html does not throw', () {
      expect(extractWebCsrfToken('<html no form'), isNull);
      expect(extractWebCurrentValues('<html no form'), isEmpty);
    });
  });
}

class _QueuedWebResponse {
  const _QueuedWebResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

class _CapturedWebRequest {
  const _CapturedWebRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.bodyBytes,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int> bodyBytes;
}

class _RecordingWebClient extends http.BaseClient {
  _RecordingWebClient(List<_QueuedWebResponse> responses)
    : _responses = List.of(responses);

  final List<_QueuedWebResponse> _responses;
  final List<_CapturedWebRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_responses.isEmpty) throw StateError('unexpected web request');
    final bodyBytes = request is http.Request
        ? List<int>.from(request.bodyBytes)
        : <int>[];
    requests.add(
      _CapturedWebRequest(
        method: request.method,
        url: request.url,
        headers: Map<String, String>.from(request.headers),
        bodyBytes: bodyBytes,
      ),
    );
    final response = _responses.removeAt(0);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.statusCode,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _AbortingWebClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw http.RequestAbortedException(request.url);
  }
}

class _StubUserRepository implements UserRepository {
  _StubUserRepository({this.user, this.failFetchAfter});

  final UserEntity? user;
  final int? failFetchAfter;
  int fetchCount = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #fetchDetail) {
      fetchCount++;
      if (failFetchAfter != null && fetchCount > failFetchAfter!) {
        return Future<UserEntity>.error(Exception('app api down'));
      }
      return Future.value(
        user ??
            const UserEntity(
              id: 1,
              name: 'Test',
              account: 'test',
              totalFollowUsers: 0,
              totalMyPixivUsers: 0,
              totalIllusts: 0,
              totalManga: 0,
              totalNovels: 0,
              totalIllustBookmarksPublic: 0,
              totalIllustSeries: 0,
              totalNovelSeries: 0,
              visible: true,
              hasDetail: false,
            ),
      );
    }
    throw UnimplementedError('${invocation.memberName}');
  }
}
