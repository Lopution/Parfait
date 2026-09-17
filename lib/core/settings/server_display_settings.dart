import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/api_error.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';

/// Server-authoritative display preferences of the current Pixiv account.
/// These flags shape what the API returns; the local R18/AI block filters
/// are a separate client-side layer and deliberately not coupled to them.
class ServerDisplaySettings {
  const ServerDisplaySettings({
    required this.showAi,
    required this.restrictedMode,
  });

  /// `show_ai` — whether the server may return AI-generated works.
  final bool showAi;

  /// `is_restricted_mode_enabled` — server-side restricted browsing mode.
  final bool restrictedMode;

  ServerDisplaySettings copyWith({bool? showAi, bool? restrictedMode}) =>
      ServerDisplaySettings(
        showAi: showAi ?? this.showAi,
        restrictedMode: restrictedMode ?? this.restrictedMode,
      );
}

/// `/v1/user/ai-show-settings`(+edit) and `/v1/user/restricted-mode-settings`.
///
/// Wire contract verified against PixEz (`api_client.dart` +
/// `show_ai_response.dart`) and pixivpy: GETs answer a top-level
/// `{show_ai}` / `{is_restricted_mode_enabled}` boolean; edits are
/// form-encoded POSTs carrying the same field and echo the stored flag.
class ServerDisplaySettingsRepository {
  ServerDisplaySettingsRepository(this._client);

  final PixivHttpClient _client;

  Future<ServerDisplaySettings> fetch({CancelToken? cancelToken}) async {
    final results = await Future.wait([
      fetchAiShow(cancelToken: cancelToken),
      fetchRestrictedMode(cancelToken: cancelToken),
    ]);
    return ServerDisplaySettings(
      showAi: results[0],
      restrictedMode: results[1],
    );
  }

  Future<bool> fetchAiShow({CancelToken? cancelToken}) async {
    final data = await _client.getJson(
      PixivClientIdentity.appApiBase.replace(path: '/v1/user/ai-show-settings'),
      cancelToken: cancelToken,
    );
    return _requireBool(data, 'show_ai');
  }

  Future<bool> fetchRestrictedMode({CancelToken? cancelToken}) async {
    final data = await _client.getJson(
      PixivClientIdentity.appApiBase.replace(
        path: '/v1/user/restricted-mode-settings',
      ),
      cancelToken: cancelToken,
    );
    return _requireBool(data, 'is_restricted_mode_enabled');
  }

  Future<bool> editAiShow(bool value, {CancelToken? cancelToken}) {
    return _edit(
      '/v1/user/ai-show-settings/edit',
      'show_ai',
      value,
      cancelToken,
    );
  }

  Future<bool> editRestrictedMode(bool value, {CancelToken? cancelToken}) {
    return _edit(
      '/v1/user/restricted-mode-settings',
      'is_restricted_mode_enabled',
      value,
      cancelToken,
    );
  }

  Future<bool> _edit(
    String path,
    String field,
    bool value,
    CancelToken? cancelToken,
  ) async {
    final response = await _client.post(
      PixivClientIdentity.appApiBase.replace(path: path),
      body: {field: value ? 'true' : 'false'},
      cancelToken: cancelToken,
      // Idempotent set-write: a single auth-refresh replay is safe.
      allowAuthReplay: true,
    );
    // The edit endpoint echoes the stored flag; when the body carries no
    // parseable field the requested value stands (the POST was 2xx).
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic> && decoded[field] is bool) {
        return decoded[field] as bool;
      }
    } on FormatException {
      // Non-JSON acknowledgement — the write itself already succeeded.
    }
    return value;
  }

  static bool _requireBool(Map<String, dynamic> data, String field) {
    final value = data[field];
    if (value is bool) return value;
    throw ApiParseError(FormatException('missing bool field "$field"'));
  }
}

/// Account-scoped read/write of [ServerDisplaySettings]. The build refetches
/// whenever the usable current account changes; writes are optimistic and
/// roll the visible state back (and rethrow) when the server edit fails.
class ServerDisplaySettingsController
    extends AsyncNotifier<ServerDisplaySettings> {
  @override
  Future<ServerDisplaySettings> build() async {
    final accountId = ref.watch(
      accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
    );
    if (accountId == null) {
      throw const ApiUnauthorized('no signed-in account');
    }
    return ref.watch(serverDisplaySettingsRepositoryProvider).fetch();
  }

  Future<void> setShowAi(bool value) => _mutate(
    value,
    (v) => ref.read(serverDisplaySettingsRepositoryProvider).editAiShow(v),
    (settings, v) => settings.copyWith(showAi: v),
  );

  Future<void> setRestrictedMode(bool value) => _mutate(
    value,
    (v) =>
        ref.read(serverDisplaySettingsRepositoryProvider).editRestrictedMode(v),
    (settings, v) => settings.copyWith(restrictedMode: v),
  );

  /// Optimistic write: the toggle reflects the requested value immediately,
  /// is confirmed (or corrected) by the server's echoed flag, and snaps back
  /// to [before] on failure so the UI never claims an unwritten value.
  Future<void> _mutate(
    bool value,
    Future<bool> Function(bool) write,
    ServerDisplaySettings Function(ServerDisplaySettings, bool) apply,
  ) async {
    final before = state.value;
    if (before == null) return;
    state = AsyncData(apply(before, value));
    try {
      final confirmed = await write(value);
      final latest = state.value;
      if (latest != null) state = AsyncData(apply(latest, confirmed));
    } on Object {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final serverDisplaySettingsRepositoryProvider =
    Provider<ServerDisplaySettingsRepository>(
      (ref) =>
          ServerDisplaySettingsRepository(ref.watch(pixivHttpClientProvider)),
    );

final serverDisplaySettingsProvider =
    AsyncNotifierProvider<
      ServerDisplaySettingsController,
      ServerDisplaySettings
    >(ServerDisplaySettingsController.new);
