import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/compat/network_policy.dart';
import '../network/compat/network_providers.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_entity.dart';
import '../user/user_repository.dart';
import 'app_api_profile_edit_repository.dart';
import 'profile_edit_models.dart';
import 'web_profile_repository.dart';
import 'web_profile_session.dart';

/// Selects the in-app transport based on the session created by the ordinary
/// Pixiv login flow. A pixiv.net web session signed in as the edited user
/// activates the same-origin adapter (the only channel that also edits the
/// background image); otherwise the official App API
/// `v1/user/profile/edit` covers name/comment/webpage/avatar through the
/// same OAuth transport every other request uses — the editor is never left
/// without a working channel.
final profileEditRepositoryProvider = Provider<ProfileEditRepository>((ref) {
  // Resolve the session once per editor load. The request itself stays inside
  // the shared compatibility policy (pixivWeb ECH tier), so the form does not
  // need a second browser surface or a proxy-specific code path.
  return _SelectingProfileEditRepository(
    userRepository: ref.watch(userRepositoryProvider),
    session: const MethodChannelWebProfileSession(),
    policy: ref.watch(networkAccessPolicyProvider),
    client: ref.watch(pixivHttpClientProvider),
  );
});

/// Lazily resolves the concrete adapter on first use (capabilities load),
/// which happens inside [ProfileEditController.load] after login.
class _SelectingProfileEditRepository implements ProfileEditRepository {
  _SelectingProfileEditRepository({
    required this.userRepository,
    required this.session,
    required this.policy,
    required this.client,
  });

  final UserRepository userRepository;
  final WebProfileSession session;
  final NetworkAccessPolicy policy;
  final PixivHttpClient client;
  PixivWebProfileEditRepository? _web;
  PixivAppApiProfileEditRepository? _appApi;

  @override
  Future<ProfileCapabilities> loadCapabilities({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async {
    final resolved = await _resolved(userId);
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
    final resolved = await _resolved(userId);
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
    final resolved = await _resolved(request.patch.userId);
    return resolved.submit(request, cancelToken: cancelToken);
  }

  /// The web channel only for a WebView session signed in as [userId]:
  /// the jar is shared and outlives account switches, and the web save
  /// rewrites whichever profile the session owns.
  Future<ProfileEditRepository> _resolved(int userId) async {
    final cookie = await session.readSessionCookie();
    if (webSessionUserId(cookie) == userId) {
      // Reuse the same adapter so loadDraft's local snapshot is still
      // available if the App API refresh fails after a successful web save.
      return _web ??= PixivWebProfileEditRepository(
        userRepository: userRepository,
        session: session,
        policy: policy,
      );
    }
    // No web session for this user — the OAuth WebView login does not
    // always plant one, and another account's must not be used. The App
    // API channel edits name/comment/webpage/avatar through the same
    // authenticated transport as every other request.
    return _appApi ??= PixivAppApiProfileEditRepository(
      client: client,
      userRepository: userRepository,
    );
  }
}
