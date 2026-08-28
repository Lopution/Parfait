import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/pixiv_http_client.dart';
import '../user/user_entity.dart';
import '../user/user_repository.dart';
import 'profile_edit_models.dart';

/// Read-only profile editor adapter used until Pixiv exposes a supported
/// update route. Loading still uses the authenticated official App API; the
/// submit capability is explicit and never pretends to have saved anything.
class PixivProfileEditRepository implements ProfileEditRepository {
  PixivProfileEditRepository(this._userRepository);

  static const unavailableReason =
      'Pixiv profile editing has no approved App API or Web adapter in this build';

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

final profileEditRepositoryProvider = Provider<ProfileEditRepository>((ref) {
  return PixivProfileEditRepository(ref.watch(userRepositoryProvider));
});
