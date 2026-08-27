import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'follow_models.dart';

/// Pixiv follow mutation contract. Keeping the interface separate makes the
/// store/action protocol testable without a live account or network.
abstract interface class FollowRepository {
  Future<void> add(
    int userId, {
    FollowRestrict restrict = FollowRestrict.public,
    CancelToken? cancelToken,
  });

  Future<void> delete(int userId, {CancelToken? cancelToken});
}

/// Pixiv follow mutations. The shared HTTP client owns authentication,
/// timeout, retry and safe error classification.
class PixivFollowRepository implements FollowRepository {
  PixivFollowRepository(this._client);

  final PixivHttpClient _client;

  @override
  Future<void> add(
    int userId, {
    FollowRestrict restrict = FollowRestrict.public,
    CancelToken? cancelToken,
  }) async {
    await _client.post(
      PixivClientIdentity.appApiBase.replace(path: '/v1/user/follow/add'),
      body: {'user_id': '$userId', 'restrict': followRestrictWire(restrict)},
      cancelToken: cancelToken,
      allowAuthReplay: false,
    );
  }

  @override
  Future<void> delete(int userId, {CancelToken? cancelToken}) async {
    await _client.post(
      PixivClientIdentity.appApiBase.replace(path: '/v1/user/follow/delete'),
      body: {'user_id': '$userId'},
      cancelToken: cancelToken,
      allowAuthReplay: false,
    );
  }
}

final followRepositoryProvider = Provider<FollowRepository>((ref) {
  return PixivFollowRepository(ref.watch(pixivHttpClientProvider));
});
