import 'package:meta/meta.dart';

import '../network/compat/network_contracts.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_entity.dart';

/// The beta56 profile editor fields that have a stable representation in the
/// current UserEntity. New server fields must not be inferred from a UI label.
enum ProfileField { displayName, comment, webpage, avatar, background }

extension ProfileFieldContract on ProfileField {
  bool get isText => switch (this) {
    ProfileField.displayName ||
    ProfileField.comment ||
    ProfileField.webpage => true,
    ProfileField.avatar || ProfileField.background => false,
  };

  bool get isImage => !isText;

  String get wireName => switch (this) {
    ProfileField.displayName => 'name',
    ProfileField.comment => 'comment',
    ProfileField.webpage => 'webpage',
    ProfileField.avatar => 'profile_image',
    ProfileField.background => 'background_image',
  };
}

enum ProfileEditChannel { appApi, web, unavailable }

enum ProfileVerificationRequirement { none, emailConfirmation, unknown }

/// Server capability information is kept separate from the draft so the UI
/// can show an unsupported field instead of silently dropping it.
@immutable
class ProfileCapabilities {
  ProfileCapabilities({
    required Iterable<ProfileField> editableFields,
    required this.channel,
    this.requiresCurrentPassword = false,
    this.verification = ProfileVerificationRequirement.none,
    this.reason,
  }) : editableFields = Set.unmodifiable(editableFields);

  factory ProfileCapabilities.unavailable(String reason) {
    return ProfileCapabilities(
      editableFields: const {},
      channel: ProfileEditChannel.unavailable,
      reason: reason,
    );
  }

  final Set<ProfileField> editableFields;
  final ProfileEditChannel channel;
  final bool requiresCurrentPassword;
  final ProfileVerificationRequirement verification;
  final String? reason;

  bool supports(ProfileField field) => editableFields.contains(field);

  bool get isAvailable => channel != ProfileEditChannel.unavailable;

  @override
  String toString() =>
      'ProfileCapabilities(channel:${channel.name}, '
      'fields:${editableFields.map((field) => field.name).toList()})';
}

/// Text values use an empty string for an intentionally cleared optional
/// field. This makes dirty comparison deterministic and keeps null handling at
/// the UserEntity mapping boundary.
@immutable
class ProfileValues {
  const ProfileValues({
    required this.displayName,
    required this.comment,
    required this.webpage,
    this.avatarUrl,
    this.backgroundUrl,
  });

  factory ProfileValues.fromUser(UserEntity user) {
    return ProfileValues(
      displayName: user.name,
      comment: user.comment ?? '',
      webpage: user.webpage ?? '',
      avatarUrl: user.profileImageUrl,
      backgroundUrl: user.backgroundImageUrl,
    );
  }

  final String displayName;
  final String comment;
  final String webpage;
  final String? avatarUrl;
  final String? backgroundUrl;

  ProfileValues copyWith({
    String? displayName,
    String? comment,
    String? webpage,
    Object? avatarUrl = _unset,
    Object? backgroundUrl = _unset,
  }) {
    return ProfileValues(
      displayName: displayName ?? this.displayName,
      comment: comment ?? this.comment,
      webpage: webpage ?? this.webpage,
      avatarUrl: identical(avatarUrl, _unset)
          ? this.avatarUrl
          : avatarUrl as String?,
      backgroundUrl: identical(backgroundUrl, _unset)
          ? this.backgroundUrl
          : backgroundUrl as String?,
    );
  }

  String valueOf(ProfileField field) => switch (field) {
    ProfileField.displayName => displayName,
    ProfileField.comment => comment,
    ProfileField.webpage => webpage,
    ProfileField.avatar => avatarUrl ?? '',
    ProfileField.background => backgroundUrl ?? '',
  };

  UserEntity applyTo(UserEntity user) {
    return user.copyWith(
      name: displayName,
      comment: comment.isEmpty ? null : comment,
      webpage: webpage.isEmpty ? null : webpage,
      profileImageUrl: avatarUrl,
      backgroundImageUrl: backgroundUrl,
    );
  }

  @override
  String toString() => 'ProfileValues(displayName:$displayName)';
}

/// A temporary, validated image reference. It carries metadata and an opaque
/// app-private path only in memory; it never serializes image bytes or a path.
class ProfileImageSelection {
  ProfileImageSelection({
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
    required this.width,
    required this.height,
    this.cleanup,
  });

  final String path;
  final String mimeType;
  final int sizeBytes;
  final int width;
  final int height;
  final Future<void> Function()? cleanup;

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final callback = cleanup;
    if (callback != null) await callback();
  }

  @override
  String toString() =>
      'ProfileImageSelection(mime:$mimeType, size:$sizeBytes, '
      'dimensions:${width}x$height)';
}

@immutable
class ProfileDraft {
  ProfileDraft({
    required this.accountId,
    required this.userId,
    required this.credentialRevision,
    required this.base,
    required this.values,
    required this.capabilities,
    this.avatar,
    this.background,
    Map<ProfileField, String> serverFieldErrors = const {},
  }) : serverFieldErrors = Map.unmodifiable(serverFieldErrors);

  factory ProfileDraft.fromUser({
    required String accountId,
    required int credentialRevision,
    required UserEntity user,
    required ProfileCapabilities capabilities,
  }) {
    final values = ProfileValues.fromUser(user);
    return ProfileDraft(
      accountId: accountId,
      userId: user.id,
      credentialRevision: credentialRevision,
      base: values,
      values: values,
      capabilities: capabilities,
    );
  }

  final String accountId;
  final int userId;
  final int credentialRevision;
  final ProfileValues base;
  final ProfileValues values;
  final ProfileCapabilities capabilities;
  final ProfileImageSelection? avatar;
  final ProfileImageSelection? background;
  final Map<ProfileField, String> serverFieldErrors;

  Set<ProfileField> get dirtyFields {
    final fields = <ProfileField>{};
    for (final field in ProfileField.values) {
      if (field.isText && base.valueOf(field) != values.valueOf(field)) {
        fields.add(field);
      }
    }
    if (avatar != null) fields.add(ProfileField.avatar);
    if (background != null) fields.add(ProfileField.background);
    return Set.unmodifiable(fields);
  }

  bool get hasChanges => dirtyFields.isNotEmpty;

  ProfilePatch buildPatch() {
    final textFields = <ProfileField, String?>{};
    for (final field in dirtyFields.where((field) => field.isText)) {
      textFields[field] = values.valueOf(field);
    }
    final images = <ProfileField, ProfileImageSelection>{};
    if (avatar case final image?) images[ProfileField.avatar] = image;
    if (background case final image?) {
      images[ProfileField.background] = image;
    }
    return ProfilePatch(
      accountId: accountId,
      userId: userId,
      credentialRevision: credentialRevision,
      textFields: textFields,
      images: images,
    );
  }

  ProfileDraft copyWith({
    ProfileValues? values,
    Object? avatar = _unset,
    Object? background = _unset,
    Map<ProfileField, String>? serverFieldErrors,
  }) {
    return ProfileDraft(
      accountId: accountId,
      userId: userId,
      credentialRevision: credentialRevision,
      base: base,
      values: values ?? this.values,
      capabilities: capabilities,
      avatar: identical(avatar, _unset)
          ? this.avatar
          : avatar as ProfileImageSelection?,
      background: identical(background, _unset)
          ? this.background
          : background as ProfileImageSelection?,
      serverFieldErrors: serverFieldErrors ?? this.serverFieldErrors,
    );
  }

  @override
  String toString() =>
      'ProfileDraft(account:$accountId, user:$userId, '
      'dirty:${dirtyFields.map((field) => field.name).toList()})';
}

@immutable
class ProfilePatch {
  ProfilePatch({
    required this.accountId,
    required this.userId,
    required this.credentialRevision,
    required Map<ProfileField, String?> textFields,
    required Map<ProfileField, ProfileImageSelection> images,
  }) : textFields = Map.unmodifiable(textFields),
       images = Map.unmodifiable(images);

  final String accountId;
  final int userId;
  final int credentialRevision;
  final Map<ProfileField, String?> textFields;
  final Map<ProfileField, ProfileImageSelection> images;

  Set<ProfileField> get fields =>
      Set.unmodifiable({...textFields.keys, ...images.keys});

  bool get isEmpty => textFields.isEmpty && images.isEmpty;

  /// Only text fields have a form encoding. Image streams are deliberately
  /// kept out of ordinary maps and must be consumed by an approved adapter.
  Map<String, String> toWireFields() {
    return {
      for (final entry in textFields.entries)
        entry.key.wireName: entry.value ?? '',
    };
  }

  @override
  String toString() =>
      'ProfilePatch(account:$accountId, user:$userId, '
      'fields:${fields.map((field) => field.name).toList()})';
}

/// A submit request owns the password only until the repository future
/// finishes. It cannot be serialized and its diagnostic representation is
/// always redacted.
class ProfileSubmitRequest {
  ProfileSubmitRequest({required this.patch, String? currentPassword})
    : _secret = _EphemeralSecret(currentPassword);

  final ProfilePatch patch;
  final _EphemeralSecret _secret;

  String? get currentPassword => _secret.value;

  void clearSecret() => _secret.clear();

  @override
  String toString() =>
      'ProfileSubmitRequest(patch:$patch, currentPassword:[redacted])';
}

class _EphemeralSecret {
  _EphemeralSecret(this.value);

  String? value;

  void clear() => value = null;
}

sealed class ProfileEditOutcome {
  const ProfileEditOutcome();
}

class ProfileEditConfirmed extends ProfileEditOutcome {
  const ProfileEditConfirmed(this.user);

  final UserEntity user;
}

class ProfileEditVerificationPending extends ProfileEditOutcome {
  const ProfileEditVerificationPending({required this.fields, this.message});

  final Set<ProfileField> fields;
  final String? message;
}

class ProfileEditFieldErrors extends ProfileEditOutcome {
  ProfileEditFieldErrors(Map<ProfileField, String> errors)
    : errors = Map.unmodifiable(errors);

  final Map<ProfileField, String> errors;
}

class ProfileEditSubmitFailure extends ProfileEditOutcome {
  const ProfileEditSubmitFailure(
    this.code,
    this.message, {
    this.retryable = false,
  });

  final ProfileEditFailureCode code;
  final String message;
  final bool retryable;
}

abstract interface class ProfileEditRepository {
  Future<ProfileCapabilities> loadCapabilities({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  });

  Future<UserEntity> loadDraft({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  });

  Future<ProfileEditOutcome> submit(
    ProfileSubmitRequest request, {
    CancelToken? cancelToken,
  });
}

@immutable
class ProfileEditOwner {
  const ProfileEditOwner({
    required this.accountId,
    required this.credentialRevision,
    required this.networkRevision,
  });

  final String accountId;
  final int credentialRevision;
  final NetworkRevision networkRevision;

  bool matches(ProfileEditOwner other) =>
      accountId == other.accountId &&
      credentialRevision == other.credentialRevision &&
      networkRevision.value == other.networkRevision.value &&
      networkRevision.networkIdentity == other.networkRevision.networkIdentity;
}

enum ProfileEditFailureCode {
  staleOwner,
  unavailable,
  noChanges,
  invalid,
  cancelled,
  cleanupFailed,
  repository,
}

abstract final class ProfileTextLimits {
  static const maxDisplayNameLength = 30;
  static const maxCommentLength = 140;
  static const maxWebpageLength = 2000;
}

abstract final class ProfileTextValidator {
  static Map<ProfileField, String> validate(ProfileValues values) {
    final errors = <ProfileField, String>{};
    final nameLength = values.displayName.trim().runes.length;
    if (nameLength == 0) {
      errors[ProfileField.displayName] = 'display name is required';
    } else if (nameLength > ProfileTextLimits.maxDisplayNameLength) {
      errors[ProfileField.displayName] = 'display name is too long';
    }

    if (values.comment.runes.length > ProfileTextLimits.maxCommentLength) {
      errors[ProfileField.comment] = 'comment is too long';
    }

    final webpage = values.webpage.trim();
    if (webpage.runes.length > ProfileTextLimits.maxWebpageLength) {
      errors[ProfileField.webpage] = 'web page is too long';
    } else if (webpage.isNotEmpty) {
      final uri = Uri.tryParse(webpage);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        errors[ProfileField.webpage] = 'web page must be an http(s) URL';
      }
    }
    return errors;
  }
}

const _unset = Object();
