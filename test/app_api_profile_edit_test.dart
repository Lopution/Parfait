import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/profile/app_api_profile_edit_repository.dart';
import 'package:parfait/core/profile/profile_edit_models.dart';
import 'package:parfait/core/user/user_repository.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/profile_world.dart';

class _RecordedMultipart {
  _RecordedMultipart(this.request, this.body);

  final http.Request request;
  final List<int> body;
}

/// The repository over [PixivApi]: profile edits are recorded in [sent]
/// and answered with [status] and [body]; the user detail it reads back is
/// [UserApi]'s.
Future<PixivAppApiProfileEditRepository> _repository({
  required List<_RecordedMultipart> sent,
  int status = 200,
  String body = '{}',
}) async {
  final api = PixivApi({
    ...UserApi().routes,
    '/v1/user/profile/edit': (request) {
      sent.add(_RecordedMultipart(request, request.bodyBytes));
      return http.Response(
        body,
        status,
        headers: {'content-type': 'application/json'},
      );
    },
  });
  final container = await signedInApiContainer(api.client);
  return PixivAppApiProfileEditRepository(
    client: container.read(pixivHttpClientProvider),
    userRepository: container.read(userRepositoryProvider),
  );
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

  test('capabilities advertise the app-api channel and fields', () async {
    final repo = await _repository(sent: []);
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
    final repo = await _repository(sent: sent);

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

  test('a patch the channel cannot send fails without a request', () async {
    // An empty patch is invalid; a background image is outside app-api.
    for (final (images, code) in [
      (const <ProfileField, Never>{}, ProfileEditFailureCode.invalid),
      (
        {ProfileField.background: _fakeSelection()},
        ProfileEditFailureCode.unavailable,
      ),
    ]) {
      final sent = <_RecordedMultipart>[];
      final repo = await _repository(sent: sent);
      final outcome = await repo.submit(
        _request(
          ProfilePatch(
            accountId: '100',
            userId: 42,
            textFields: const {},
            images: images,
          ),
        ),
      );
      expect(
        outcome,
        isA<ProfileEditSubmitFailure>().having((f) => f.code, 'code', code),
      );
      expect(sent, isEmpty);
    }
  });

  test(
    'a soft JSON error envelope on HTTP 200 surfaces as a failure',
    () async {
      final sent = <_RecordedMultipart>[];
      final repo = await _repository(
        sent: sent,
        body: jsonEncode({
          'error': {
            'user_message': 'invalid parameter',
            'message': '',
            'reason': '',
          },
        }),
      );
      final outcome = await repo.submit(_request(_textPatch()));
      expect(outcome, isA<ProfileEditSubmitFailure>());
    },
  );

  test('avatar patch sends a profile_image file part', () async {
    final sent = <_RecordedMultipart>[];
    final repo = await _repository(sent: sent);
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
