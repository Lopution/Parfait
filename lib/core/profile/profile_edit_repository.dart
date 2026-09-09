import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/compat/network_policy.dart';
import '../network/compat/network_providers.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_entity.dart';
import '../user/user_repository.dart';
import 'profile_edit_models.dart';
import 'web_profile_repository.dart';
import 'web_profile_session.dart';

/// Explicit unavailable fallback used when the app cannot access the
/// same-origin Pixiv session needed by the in-app update adapter. It never
/// pretends that a local-only change was saved.
class _PixivProfileEditRepository implements ProfileEditRepository {
  _PixivProfileEditRepository(this._userRepository);

  static const unavailableReason =
      'No in-app Pixiv session is available; profile updates cannot be submitted.';

  final UserRepository _userRepository;

  @override
  Future<ProfileCapabilities> loadCapabilities({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async {
    return ProfileCapabilities.unavailable(unavailableReason);
  }

  @override
  Future<UserEntity> loadDraft({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) => _userRepository.fetchDetail(userId, cancelToken: cancelToken);

  @override
  Future<ProfileEditOutcome> submit(
    ProfileSubmitRequest request, {
    CancelToken? cancelToken,
  }) async {
    return const ProfileEditSubmitFailure(
      ProfileEditFailureCode.unavailable,
      unavailableReason,
    );
  }
}

/// Selects the in-app transport based on the session created by the ordinary
/// Pixiv login flow. A logged-in pixiv.net session activates the official
/// same-origin profile API adapter (nickname/comment/webpage/avatar/
/// background); otherwise the form remains visible but cannot submit.
final profileEditRepositoryProvider = Provider<ProfileEditRepository>((ref) {
  // Resolve the session once per editor load. The request itself stays inside
  // the shared compatibility policy (pixivWeb ECH tier), so the form does not
  // need a second browser surface or a proxy-specific code path.
  return _SelectingProfileEditRepository(
    userRepository: ref.watch(userRepositoryProvider),
    session: const MethodChannelWebProfileSession(),
    policy: ref.watch(networkAccessPolicyProvider),
  );
});

/// Lazily resolves the concrete adapter on first use (capabilities load),
/// which happens inside [ProfileEditController.load] after login.
class _SelectingProfileEditRepository implements ProfileEditRepository {
  _SelectingProfileEditRepository({
    required this.userRepository,
    required this.session,
    required this.policy,
  });

  final UserRepository userRepository;
  final WebProfileSession session;
  final NetworkAccessPolicy policy;
  PixivWebProfileEditRepository? _web;

  @override
  Future<ProfileCapabilities> loadCapabilities({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async {
    final resolved = await _resolved();
    return resolved.loadCapabilities(
      accountId: accountId,
      userId: userId,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<UserEntity> loadDraft({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async {
    final resolved = await _resolved();
    return resolved.loadDraft(
      accountId: accountId,
      userId: userId,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<ProfileEditOutcome> submit(
    ProfileSubmitRequest request, {
    CancelToken? cancelToken,
  }) async {
    final resolved = await _resolved();
    return resolved.submit(request, cancelToken: cancelToken);
  }

  Future<ProfileEditRepository> _resolved() async {
    final cookie = await session.readSessionCookie();
    if (hasWebProfileSession(cookie)) {
      // Reuse the same adapter so loadDraft's local snapshot is still
      // available if the App API refresh fails after a successful web save.
      return _web ??= PixivWebProfileEditRepository(
        userRepository: userRepository,
        session: session,
        policy: policy,
      );
    }
    return _PixivProfileEditRepository(userRepository);
  }
}
