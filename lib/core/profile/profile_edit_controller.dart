import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Per-session dependencies of the profile editor (C7a). Identity equality:
/// a new editing session is a new session object.
class ProfileEditSession {
  ProfileEditSession({
    required this.repository,
    required this.owner,
    required this.readOwner,
    required this.initialUser,
    required this.onConfirmed,
  });

  final ProfileEditRepository repository;
  final ProfileEditOwner owner;
  final ProfileEditOwner Function() readOwner;
  final UserEntity initialUser;
  final Future<void> Function(UserEntity user) onConfirmed;
}

/// Riverpod handle for the per-session profile editor.
final profileEditControllerProvider =
    NotifierProvider.autoDispose.family<
      ProfileEditController,
      ProfileEditState,
      ProfileEditSession
    >(ProfileEditController.new);

/// Account/revision-fenced profile editor. It owns only the in-memory draft;
/// persistent stores are changed through [onConfirmed] after the response has
/// passed the ownership check.
class ProfileEditController extends Notifier<ProfileEditState> {
  ProfileEditController(this.session);

  final ProfileEditSession session;

  ProfileEditRepository get repository => session.repository;
  ProfileEditOwner Function() get readOwner => session.readOwner;
  UserEntity get initialUser => session.initialUser;
  Future<void> Function(UserEntity user) get onConfirmed =>
      session.onConfirmed;

  @override
  ProfileEditState build() {
    _owner = session.owner;
    ref.onDispose(() {
      unawaited(close());
    });
    return const ProfileEditState.loading();
  }


  ProfileEditOwner _owner = ProfileEditOwner(accountId: '');
  CancelToken? _cancelToken;
  int _generation = 0;
  bool _closed = false;

  /// Plain-field mirror of the active draft so [close] can release images
  /// during provider disposal, where Riverpod forbids touching `state`.
  ProfileDraft? _activeDraft;

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
    final draft = state.draft;
    if (_closed || draft == null || !field.isText) return;
    final nextValues = switch (field) {
      ProfileField.displayName => draft.values.copyWith(displayName: value),
      ProfileField.comment => draft.values.copyWith(comment: value),
      ProfileField.webpage => draft.values.copyWith(webpage: value),
      ProfileField.avatar || ProfileField.background => draft.values,
    };
    final errors = Map<ProfileField, String>.of(state.fieldErrors)
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
    final draft = state.draft;
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
    final draft = state.draft;
    if (_closed ||
        draft == null ||
        state.status == ProfileEditStatus.submitting) {
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

    final validation = _validateDraft(draft, currentPassword);
    if (validation.fieldErrors.isNotEmpty ||
        validation.currentPasswordError != null) {
      _setState(
        ProfileEditState(
          status: ProfileEditStatus.ready,
          draft: draft,
          fieldErrors: validation.fieldErrors,
          currentPasswordError: validation.currentPasswordError,
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
      currentPassword: validation.password,
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
      await _applySubmitOutcome(draft, outcome);
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

  ({
    Map<ProfileField, String> fieldErrors,
    String? currentPasswordError,
    String? password,
  }) _validateDraft(ProfileDraft draft, String? currentPassword) {
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
    return (
      fieldErrors: errors,
      currentPasswordError: passwordError,
      password: password,
    );
  }

  Future<void> _applySubmitOutcome(
    ProfileDraft draft,
    ProfileEditOutcome outcome,
  ) async {
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
  }

  /// Called by the page's account-store listener. It turns a switch or
  /// credential/network revision change into a visible stale-owner failure and
  /// prevents a late response from writing the next account.
  void checkOwner() {
    if (_closed || _ownsCurrentAccount()) return;
    ++_generation;
    _cancelToken?.cancel();
    final draft = state.draft;
    _setFailure(_staleFailure);
    if (draft != null) unawaited(_releaseImagesAndClear(draft));
  }

  Future<void> cancel() async {
    if (_closed) return;
    ++_generation;
    _cancelToken?.cancel();
    final draft = state.draft;
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
    final draft = _activeDraft;
    if (draft != null) await _releaseImagesAndClear(draft);
  }

  Map<ProfileField, String> _withoutError(ProfileField field) {
    return Map<ProfileField, String>.of(state.fieldErrors)..remove(field);
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
    _activeDraft = next.draft;
    if (_closed) return;
    state = next;
  }

  void _setFailure(ProfileEditFailure failure) {
    if (_closed) return;
    _activeDraft = state.draft;
    state = ProfileEditState(
      status: ProfileEditStatus.failure,
      draft: state.draft,
      failure: failure,
      fieldErrors: state.fieldErrors,
    );
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
    _activeDraft = draft.copyWith(avatar: null, background: null);
    // During provider disposal Riverpod forbids state writes; the images are
    // still released, only the visual clear is skipped.
    if (_closed) return;
    if (!identical(state.draft, draft)) return;
    state = ProfileEditState(
      status: state.status,
      draft: draft.copyWith(avatar: null, background: null),
      fieldErrors: state.fieldErrors,
      currentPasswordError: state.currentPasswordError,
      failure: state.failure,
      verificationMessage: state.verificationMessage,
    );
  }

  static const _staleFailure = ProfileEditFailure(
    code: ProfileEditFailureCode.staleOwner,
    message: 'profile editor belongs to another account',
  );
}
