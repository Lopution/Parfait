import 'dart:async';

import 'package:flutter/foundation.dart';

import '../network/api_error.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_entity.dart';
import 'profile_edit_models.dart';

enum ProfileEditStatus {
  loading,
  ready,
  submitting,
  confirmed,
  verificationPending,
  canceled,
  failure,
}

@immutable
class ProfileEditFailure {
  const ProfileEditFailure({
    required this.code,
    required this.message,
    this.retryable = false,
  });

  final ProfileEditFailureCode code;
  final String message;
  final bool retryable;
}

@immutable
class ProfileEditState {
  const ProfileEditState({
    required this.status,
    this.draft,
    this.fieldErrors = const {},
    this.currentPasswordError,
    this.failure,
    this.verificationMessage,
  });

  const ProfileEditState.loading()
    : status = ProfileEditStatus.loading,
      draft = null,
      fieldErrors = const {},
      currentPasswordError = null,
      failure = null,
      verificationMessage = null;

  final ProfileEditStatus status;
  final ProfileDraft? draft;
  final Map<ProfileField, String> fieldErrors;
  final String? currentPasswordError;
  final ProfileEditFailure? failure;
  final String? verificationMessage;

  bool get hasUnsavedChanges => draft?.hasChanges ?? false;
}

/// Account/revision-fenced profile editor. It owns only the in-memory draft;
/// persistent stores are changed through [onConfirmed] after the response has
/// passed the ownership check.
class ProfileEditController extends ChangeNotifier {
  ProfileEditController({
    required this.repository,
    required ProfileEditOwner owner,
    required this.readOwner,
    required this.initialUser,
    required this.onConfirmed,
  }) : _owner = owner;

  final ProfileEditRepository repository;
  final ProfileEditOwner Function() readOwner;
  final UserEntity initialUser;
  final Future<void> Function(UserEntity user) onConfirmed;

  ProfileEditOwner _owner;
  ProfileEditState _state = const ProfileEditState.loading();
  CancelToken? _cancelToken;
  int _generation = 0;
  bool _closed = false;

  ProfileEditState get state => _state;

  Future<void> load() async {
    if (_closed) return;
    final generation = ++_generation;
    _cancelToken?.cancel();
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    _setState(const ProfileEditState.loading());

    if (!_ownsCurrentAccount()) {
      _setFailure(
        const ProfileEditFailure(
          code: ProfileEditFailureCode.staleOwner,
          message: 'profile editor belongs to another account',
        ),
      );
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
      return;
    }

    try {
      final capabilities = await repository.loadCapabilities(
        accountId: _owner.accountId,
        userId: initialUser.id,
        cancelToken: cancelToken,
      );
      if (!_isActive(generation, cancelToken)) return;
      final loaded = await repository.loadDraft(
        accountId: _owner.accountId,
        userId: initialUser.id,
        cancelToken: cancelToken,
      );
      if (!_isActive(generation, cancelToken)) return;
      if (loaded.id != initialUser.id || !_ownsCurrentAccount()) {
        _setFailure(
          const ProfileEditFailure(
            code: ProfileEditFailureCode.staleOwner,
            message: 'profile response belongs to another account',
          ),
        );
        return;
      }
      _setState(
        ProfileEditState(
          status: ProfileEditStatus.ready,
          draft: ProfileDraft.fromUser(
            accountId: _owner.accountId,
            credentialRevision: _owner.credentialRevision,
            user: loaded,
            capabilities: capabilities,
          ),
        ),
      );
    } on ApiCancelled {
      if (_isActive(generation, cancelToken)) {
        _setState(const ProfileEditState(status: ProfileEditStatus.canceled));
      }
    } on Object {
      if (_isActive(generation, cancelToken)) {
        _setFailure(
          const ProfileEditFailure(
            code: ProfileEditFailureCode.repository,
            message: 'profile data could not be loaded',
            retryable: true,
          ),
        );
      }
    } finally {
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
  }

  void updateText(ProfileField field, String value) {
    final draft = _state.draft;
    if (_closed || draft == null || !field.isText) return;
    final nextValues = switch (field) {
      ProfileField.displayName => draft.values.copyWith(displayName: value),
      ProfileField.comment => draft.values.copyWith(comment: value),
      ProfileField.webpage => draft.values.copyWith(webpage: value),
      ProfileField.avatar || ProfileField.background => draft.values,
    };
    final errors = Map<ProfileField, String>.of(_state.fieldErrors)
      ..remove(field);
    final serverErrors = Map<ProfileField, String>.of(draft.serverFieldErrors)
      ..remove(field);
    _setState(
      ProfileEditState(
        status: ProfileEditStatus.ready,
        draft: draft.copyWith(
          values: nextValues,
          serverFieldErrors: serverErrors,
        ),
        fieldErrors: errors,
      ),
    );
  }

  Future<void> selectImage(
    ProfileField field,
    ProfileImageSelection selection,
  ) async {
    final draft = _state.draft;
    if (_closed || draft == null || !field.isImage) {
      await selection.dispose();
      return;
    }
    final old = field == ProfileField.avatar ? draft.avatar : draft.background;
    if (field == ProfileField.avatar) {
      _setState(
        ProfileEditState(
          status: ProfileEditStatus.ready,
          draft: draft.copyWith(avatar: selection),
          fieldErrors: _withoutError(field),
        ),
      );
    } else {
      _setState(
        ProfileEditState(
          status: ProfileEditStatus.ready,
          draft: draft.copyWith(background: selection),
          fieldErrors: _withoutError(field),
        ),
      );
    }
    if (old != null && !identical(old, selection)) {
      try {
        await old.dispose();
      } on Object {
        _setFailure(
          const ProfileEditFailure(
            code: ProfileEditFailureCode.cleanupFailed,
            message: 'previous profile image cleanup failed',
          ),
        );
      }
    }
  }

  Future<void> submit({String? currentPassword}) async {
    final draft = _state.draft;
    if (_closed ||
        draft == null ||
        _state.status == ProfileEditStatus.submitting) {
      return;
    }
    if (!_ownsCurrentAccount()) {
      _setFailure(_staleFailure);
      await _releaseImagesAndClear(draft);
      return;
    }
    if (!draft.capabilities.isAvailable) {
      _setFailure(
        ProfileEditFailure(
          code: ProfileEditFailureCode.unavailable,
          message:
              draft.capabilities.reason ??
              'profile editing is unavailable through the approved route',
        ),
      );
      await _releaseImagesAndClear(draft);
      return;
    }

    final errors = ProfileTextValidator.validate(draft.values);
    for (final field in draft.dirtyFields) {
      if (!draft.capabilities.supports(field)) {
        errors[field] = 'this profile field is not supported';
      }
    }
    final password = currentPassword?.trim();
    final passwordError =
        draft.capabilities.requiresCurrentPassword &&
            (password == null || password.isEmpty)
        ? 'current password is required'
        : null;
    if (errors.isNotEmpty || passwordError != null) {
      _setState(
        ProfileEditState(
          status: ProfileEditStatus.ready,
          draft: draft,
          fieldErrors: errors,
          currentPasswordError: passwordError,
        ),
      );
      return;
    }
    if (!draft.hasChanges) {
      _setFailure(
        const ProfileEditFailure(
          code: ProfileEditFailureCode.noChanges,
          message: 'no profile changes to submit',
        ),
      );
      return;
    }

    final generation = ++_generation;
    _cancelToken?.cancel();
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    final request = ProfileSubmitRequest(
      patch: draft.buildPatch(),
      currentPassword: password,
    );
    _setState(
      ProfileEditState(status: ProfileEditStatus.submitting, draft: draft),
    );

    try {
      final outcome = await repository.submit(
        request,
        cancelToken: cancelToken,
      );
      if (!_isActive(generation, cancelToken)) return;
      if (!_ownsCurrentAccount()) {
        _setFailure(_staleFailure);
        await _releaseImagesAndClear(draft);
        return;
      }
      switch (outcome) {
        case ProfileEditConfirmed(:final user):
          if (user.id != initialUser.id) {
            _setFailure(_staleFailure);
            await _releaseImagesAndClear(draft);
            return;
          }
          try {
            await onConfirmed(user);
          } on Object {
            _setFailure(
              const ProfileEditFailure(
                code: ProfileEditFailureCode.repository,
                message: 'confirmed profile could not be stored',
                retryable: true,
              ),
            );
            await _releaseImagesAndClear(draft);
            return;
          }
          await _releaseImagesAndClear(draft);
          _owner = readOwner();
          final confirmedDraft = ProfileDraft.fromUser(
            accountId: _owner.accountId,
            credentialRevision: _owner.credentialRevision,
            user: user,
            capabilities: draft.capabilities,
          );
          _setState(
            ProfileEditState(
              status: ProfileEditStatus.confirmed,
              draft: confirmedDraft,
            ),
          );
        case ProfileEditVerificationPending(:final message):
          await _releaseImagesAndClear(draft);
          _setState(
            ProfileEditState(
              status: ProfileEditStatus.verificationPending,
              draft: draft.copyWith(avatar: null, background: null),
              verificationMessage: message,
            ),
          );
        case ProfileEditFieldErrors(:final errors):
          final erroredDraft = draft.copyWith(serverFieldErrors: errors);
          _setState(
            ProfileEditState(
              status: ProfileEditStatus.ready,
              draft: erroredDraft,
              fieldErrors: errors,
            ),
          );
        case ProfileEditSubmitFailure(
          :final code,
          :final message,
          :final retryable,
        ):
          await _releaseImagesAndClear(draft);
          _setFailure(
            ProfileEditFailure(
              code: code,
              message: message,
              retryable: retryable,
            ),
          );
      }
    } on ApiCancelled {
      await _releaseImagesAndClear(draft);
      if (_isActive(generation, cancelToken)) {
        _setState(const ProfileEditState(status: ProfileEditStatus.canceled));
      }
    } on Object {
      await _releaseImagesAndClear(draft);
      if (_isActive(generation, cancelToken)) {
        _setFailure(
          const ProfileEditFailure(
            code: ProfileEditFailureCode.repository,
            message: 'profile changes could not be submitted',
            retryable: true,
          ),
        );
      }
    } finally {
      request.clearSecret();
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
  }

  /// Called by the page's account-store listener. It turns a switch or
  /// credential/network revision change into a visible stale-owner failure and
  /// prevents a late response from writing the next account.
  void checkOwner() {
    if (_closed || _ownsCurrentAccount()) return;
    ++_generation;
    _cancelToken?.cancel();
    final draft = _state.draft;
    _setFailure(_staleFailure);
    if (draft != null) unawaited(_releaseImagesAndClear(draft));
  }

  Future<void> cancel() async {
    if (_closed) return;
    ++_generation;
    _cancelToken?.cancel();
    final draft = _state.draft;
    Object? cleanupError;
    if (draft != null) {
      cleanupError = await _releaseImagesAndClear(draft);
    }
    if (_closed) return;
    if (cleanupError != null) {
      _setFailure(
        const ProfileEditFailure(
          code: ProfileEditFailureCode.cleanupFailed,
          message: 'profile image cleanup failed',
        ),
      );
    } else {
      _setState(const ProfileEditState(status: ProfileEditStatus.canceled));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _cancelToken?.cancel();
    final draft = _state.draft;
    if (draft != null) await _releaseImagesAndClear(draft);
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  Map<ProfileField, String> _withoutError(ProfileField field) {
    return Map<ProfileField, String>.of(_state.fieldErrors)..remove(field);
  }

  bool _ownsCurrentAccount() {
    try {
      return _owner.matches(readOwner());
    } on Object {
      return false;
    }
  }

  bool _isActive(int generation, CancelToken token) {
    return !_closed && generation == _generation && !token.isCancelled;
  }

  void _setState(ProfileEditState next) {
    if (_closed) return;
    _state = next;
    notifyListeners();
  }

  void _setFailure(ProfileEditFailure failure) {
    if (_closed) return;
    _state = ProfileEditState(
      status: ProfileEditStatus.failure,
      draft: _state.draft,
      failure: failure,
      fieldErrors: _state.fieldErrors,
    );
    notifyListeners();
  }

  Future<Object?> _releaseImages(ProfileDraft draft) async {
    Object? firstError;
    for (final image in [draft.avatar, draft.background]) {
      if (image == null) continue;
      try {
        await image.dispose();
      } on Object catch (error) {
        firstError ??= error;
      }
    }
    return firstError;
  }

  Future<Object?> _releaseImagesAndClear(ProfileDraft draft) async {
    final error = await _releaseImages(draft);
    _clearImageReferences(draft);
    return error;
  }

  void _clearImageReferences(ProfileDraft draft) {
    if (!identical(_state.draft, draft)) return;
    _state = ProfileEditState(
      status: _state.status,
      draft: draft.copyWith(avatar: null, background: null),
      fieldErrors: _state.fieldErrors,
      currentPasswordError: _state.currentPasswordError,
      failure: _state.failure,
      verificationMessage: _state.verificationMessage,
    );
  }

  static const _staleFailure = ProfileEditFailure(
    code: ProfileEditFailureCode.staleOwner,
    message: 'profile editor belongs to another account',
  );
}
