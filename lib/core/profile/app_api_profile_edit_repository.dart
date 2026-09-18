import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../network/api_error.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_entity.dart';
import '../user/user_repository.dart';
import 'profile_edit_models.dart';

/// Profile editor over the official App API — `POST v1/user/profile/edit`
/// (multipart) — the same OAuth transport every other request uses. This is
/// the channel PixShaft uses; it does not depend on a same-origin
/// www.pixiv.net cookie, which the OAuth WebView login does not reliably
/// leave behind and which made the editor permanently unavailable.
///
/// The endpoint edits display name, comment, webpage and the profile image.
/// It has no background-image field, so [ProfileField.background] stays
/// web-channel only.
class PixivAppApiProfileEditRepository implements ProfileEditRepository {
  PixivAppApiProfileEditRepository({
    required PixivHttpClient client,
    required UserRepository userRepository,
  }) : _client = client,
       _userRepository = userRepository;

  static const editableFields = <ProfileField>{
    ProfileField.displayName,
    ProfileField.comment,
    ProfileField.webpage,
    ProfileField.avatar,
  };

  /// App API wire names per the proven client contract (PixShaft's
  /// `FragmentEditFile` sends these exact multipart part names).
  static const _textWireNames = {
    ProfileField.displayName: 'user_name',
    ProfileField.comment: 'comment',
    ProfileField.webpage: 'webpage',
  };

  static const _editPath = '/v1/user/profile/edit';

  /// Shaft rejects avatars past 5 MB before upload; the server enforces a
  /// similar ceiling, so the same guard applies here.
  static const _maxAvatarBytes = 5 * 1024 * 1024;

  final PixivHttpClient _client;
  final UserRepository _userRepository;
  UserEntity? _lastDraft;

  @override
  Future<ProfileCapabilities> loadCapabilities({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async {
    return ProfileCapabilities(
      editableFields: editableFields,
      channel: ProfileEditChannel.appApi,
    );
  }

  @override
  Future<UserEntity> loadDraft({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async {
    final user = await _userRepository.fetchDetail(
      userId,
      cancelToken: cancelToken,
    );
    _lastDraft = user;
    return user;
  }

  @override
  Future<ProfileEditOutcome> submit(
    ProfileSubmitRequest request, {
    CancelToken? cancelToken,
  }) async {
    try {
      final patch = request.patch;
      if (patch.isEmpty) {
        return const ProfileEditSubmitFailure(
          ProfileEditFailureCode.invalid,
          'There are no profile changes to save',
        );
      }
      final unsupported = patch.fields.difference(editableFields);
      if (unsupported.isNotEmpty) {
        return ProfileEditSubmitFailure(
          ProfileEditFailureCode.unavailable,
          'The App API profile channel cannot edit '
          '${unsupported.map((field) => field.name).join(', ')}',
        );
      }

      final fields = <String, String>{
        for (final entry in patch.textFields.entries)
          _textWireNames[entry.key]!: entry.value ?? '',
      };
      final files = <PixivMultipartFile>[];
      final avatar = patch.images[ProfileField.avatar];
      if (avatar != null) {
        if (avatar.sizeBytes > _maxAvatarBytes) {
          return const ProfileEditSubmitFailure(
            ProfileEditFailureCode.invalid,
            'The selected profile image is larger than 5 MB',
          );
        }
        files.add(
          PixivMultipartFile(
            name: 'profile_image',
            filename: 'profile_image.${_extensionFor(avatar.mimeType)}',
            bytes: await File(avatar.path).readAsBytes(),
            contentType: avatar.mimeType,
          ),
        );
      }

      final response = await _client.postMultipart(
        PixivClientIdentity.appApiBase.replace(path: _editPath),
        fields: fields,
        files: files,
        cancelToken: cancelToken,
        // Same contract as bookmark writes: a 401/invalid_grant refreshes
        // the credential and replays this mutation at most once.
        allowAuthReplay: true,
      );
      _ensureSuccess(response);

      final confirmed = await _refreshConfirmedUser(
        patch,
        cancelToken: cancelToken,
      );
      return ProfileEditConfirmed(confirmed);
    } on ApiCancelled {
      rethrow;
    } on ApiUnauthorized {
      return const ProfileEditSubmitFailure(
        ProfileEditFailureCode.unavailable,
        'The Pixiv session expired; sign in again before saving',
        retryable: true,
      );
    } on ApiRateLimited {
      return const ProfileEditSubmitFailure(
        ProfileEditFailureCode.repository,
        'Pixiv rate-limited the profile update; try again shortly',
        retryable: true,
      );
    } on Object catch (error) {
      return ProfileEditSubmitFailure(
        ProfileEditFailureCode.repository,
        'Profile update failed: $error',
        retryable: true,
      );
    } finally {
      request.clearSecret();
    }
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiHttpError(response.statusCode, null);
    }
    // The endpoint answers a small JSON envelope on success; a present
    // "error" payload means a soft rejection with HTTP 200.
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic> && decoded['error'] != null) {
        throw ApiHttpError(400, '${decoded['error']}');
      }
    } on FormatException {
      // An empty body is a valid success (NullResponse contract).
    }
  }

  Future<UserEntity> _refreshConfirmedUser(
    ProfilePatch patch, {
    CancelToken? cancelToken,
  }) async {
    try {
      final fresh = await _userRepository.fetchDetail(
        patch.userId,
        cancelToken: cancelToken,
      );
      _lastDraft = fresh;
      return fresh;
    } on Object {
      // The mutation already succeeded; if the refresh is temporarily
      // unavailable keep the confirmed local draft instead of claiming an
      // unconfirmed save.
      final cached = _lastDraft;
      if (cached == null || cached.id != patch.userId) rethrow;
      final updated = _applyPatchToUser(cached, patch);
      _lastDraft = updated;
      return updated;
    }
  }

  UserEntity _applyPatchToUser(UserEntity user, ProfilePatch patch) {
    var result = user;
    for (final entry in patch.textFields.entries) {
      final value = entry.value ?? '';
      switch (entry.key) {
        case ProfileField.displayName:
          result = result.copyWith(name: value);
        case ProfileField.comment:
          result = result.copyWith(comment: value.isEmpty ? null : value);
        case ProfileField.webpage:
          result = result.copyWith(webpage: value.isEmpty ? null : value);
        case ProfileField.avatar:
        case ProfileField.background:
          break;
      }
    }
    return result;
  }

  static String _extensionFor(String mimeType) {
    return switch (mimeType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      _ => 'jpg',
    };
  }
}
