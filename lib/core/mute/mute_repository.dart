import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../network/api_error.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'mute_models.dart';

/// `/v1/mute/list` payload: server-authoritative muted tags and users plus
/// the account's mute limit. Single-work mute has no official endpoint.
class MuteListResult {
  const MuteListResult({
    required this.tags,
    required this.users,
    required this.limit,
  });

  final Set<String> tags;
  final Map<int, MutedUser> users;
  final int limit;
}

/// Thin client over the official mute endpoints (shape verified against
/// pixes `network.dart`: `key[]=value` repeated form fields).
class MuteRepository {
  MuteRepository(this._client);

  final PixivHttpClient _client;

  Future<MuteListResult> fetchList({CancelToken? cancelToken}) async {
    final response = await _client.get(
      PixivClientIdentity.appApiBase.replace(path: '/v1/mute/list'),
      cancelToken: cancelToken,
    );
    _ensureSuccess(response);
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return MuteListResult(
      tags: {
        for (final tag in data['muted_tags'] as List? ?? const [])
          (tag as Map)['tag'] as String,
      },
      users: {
        for (final user in data['muted_users'] as List? ?? const [])
          ((user as Map)['user_id'] as num).toInt(): MutedUser.fromJson(
            user.cast<String, dynamic>(),
          ),
      },
      limit: (data['mute_limit_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// One edit per call — the transport body is `Map<String, String>` so a
  /// `[]`-suffixed key carries exactly one value. Batch callers (legacy
  /// migration) loop; mute edits are idempotent set writes so per-key
  /// requests stay cheap and independently retryable.
  Future<void> edit({
    String? addTag,
    int? addUserId,
    String? deleteTag,
    int? deleteUserId,
    CancelToken? cancelToken,
  }) async {
    final body = <String, String>{
      'add_tags[]': ?addTag,
      'add_user_ids[]': ?addUserId?.toString(),
      'delete_tags[]': ?deleteTag,
      'delete_user_ids[]': ?deleteUserId?.toString(),
    };
    if (body.isEmpty) return;
    if (body.isEmpty) return;
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: '/v1/mute/edit'),
      body: body,
      cancelToken: cancelToken,
      // Set edits are idempotent: a single auth-refresh replay is safe.
      allowAuthReplay: true,
    );
    _ensureSuccess(response);
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiHttpError(response.statusCode, null);
    }
  }
}

final muteRepositoryProvider = Provider<MuteRepository>(
  (ref) => MuteRepository(ref.watch(pixivHttpClientProvider)),
);
