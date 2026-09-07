import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../network/api_error.dart';
import '../network/compat/network_contracts.dart';
import '../network/compat/network_policy.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_entity.dart';
import '../user/user_repository.dart';
import 'profile_edit_models.dart';
import 'web_profile_session.dart';

/// In-app profile editor backed by the authenticated pixiv.net API session.
///
/// This is a transport adapter only: the user edits in [ProfileEditPage] and
/// no web page or WebView is opened for the profile flow. The existing login
/// WebView supplies the same-origin session cookie, while all profile reads
/// and writes are issued by this repository through the shared no-proxy
/// network policy.
///
/// The current Pixiv settings page is a SPA. It loads the profile through
/// `/ajax/my_profile` and saves a complete profile object through the
/// multipart `/ajax/my_profile/update` endpoint. It is important that this
/// adapter uses those endpoints instead of treating the visible settings
/// page as an old HTML form: the latter times out or silently drops fields on
/// current Pixiv deployments.
class PixivWebProfileEditRepository implements ProfileEditRepository {
  PixivWebProfileEditRepository({
    required this.userRepository,
    WebProfileSession? session,
    NetworkAccessPolicy? policy,
    http.Client? httpClient,
  }) : _session = session ?? const MethodChannelWebProfileSession(),
       _policy = policy,
       _httpClient = httpClient;

  static const settingsUrl = 'https://www.pixiv.net/settings/profile';
  static const profileUrl = 'https://www.pixiv.net/ajax/my_profile';
  static const profileUpdateUrl =
      'https://www.pixiv.net/ajax/my_profile/update';

  final UserRepository userRepository;
  final WebProfileSession _session;
  final NetworkAccessPolicy? _policy;
  final http.Client? _httpClient;
  UserEntity? _lastDraft;

  http.Client _newClient() {
    final injected = _httpClient;
    if (injected != null) return injected;
    final policy = _policy ?? NetworkAccessPolicy();
    return _WebUserAgentClient(
      PixivPolicyHttpClient(
        policy: policy,
        purpose: PixivDestinationPurpose.pixivWeb,
      ),
    );
  }

  static const _editableTextFields = {
    ProfileField.displayName,
    ProfileField.comment,
    ProfileField.webpage,
  };

  @override
  Future<ProfileCapabilities> loadCapabilities({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async {
    final cookie = await _session.readSessionCookie();
    if (!hasWebProfileSession(cookie)) {
      return ProfileCapabilities(
        editableFields: const {},
        channel: ProfileEditChannel.unavailable,
        reason:
            'In-app Pixiv session is unavailable; sign in again before saving.',
      );
    }
    return ProfileCapabilities(
      editableFields: {
        ..._editableTextFields,
        ProfileField.avatar,
        ProfileField.background,
      },
      channel: ProfileEditChannel.web,
    );
  }

  @override
  Future<UserEntity> loadDraft({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async {
    final user = await userRepository.fetchDetail(
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
    http.Client? ownedClient;
    try {
      final cookie = await _session.readSessionCookie();
      if (!hasWebProfileSession(cookie)) {
        return const ProfileEditSubmitFailure(
          ProfileEditFailureCode.unavailable,
          'The in-app Pixiv session has expired; sign in again before saving',
          retryable: true,
        );
      }
      final patch = request.patch;
      if (patch.isEmpty) {
        return const ProfileEditSubmitFailure(
          ProfileEditFailureCode.invalid,
          'There are no profile changes to save',
        );
      }

      final injected = _httpClient;
      ownedClient = injected == null ? _newClient() : null;
      final client = injected ?? ownedClient!;
      final webCookie = cookie!;

      // The page contains the current SPA CSRF token. The token is also sent
      // as a header on the JSON and multipart requests below.
      final settings = await _fetchSettingsPage(
        client,
        webCookie,
        cancelToken: cancelToken,
      );
      if (!_isSuccessStatus(settings.status)) {
        return _failureForResponse(
          settings,
          fallback:
              'The in-app Pixiv session has expired; sign in again before saving',
        );
      }
      final csrf = extractWebCsrfToken(settings.body);
      if (csrf == null || csrf.isEmpty) {
        return const ProfileEditSubmitFailure(
          ProfileEditFailureCode.unavailable,
          'Could not obtain the in-app profile session token; sign in again and retry',
          retryable: true,
        );
      }

      // Always round-trip the complete profile object. Sending only the
      // visible text fields can clear privacy and external-service settings.
      final currentResponse = await _fetchMyProfile(
        client,
        cookie: webCookie,
        csrf: csrf,
        cancelToken: cancelToken,
      );
      final currentProfile = _profileBody(currentResponse);
      if (currentProfile == null) {
        return _failureForResponse(
          currentResponse,
          fallback:
              'Could not read the current in-app profile; try again later',
        );
      }
      final profile = _mergeProfile(currentProfile, patch);

      final boundary = '----pixivfunc${DateTime.now().microsecondsSinceEpoch}';
      final body = await _buildMultipartBody(
        boundary: boundary,
        profile: profile,
        patch: patch,
      );
      final update = await _postProfileUpdate(
        client,
        cookie: webCookie,
        csrf: csrf,
        boundary: boundary,
        body: body,
        cancelToken: cancelToken,
      );
      if (!_isSuccessfulApiResponse(update)) {
        return _failureForResponse(
          update,
          fallback: 'Pixiv rejected the in-app profile update',
        );
      }

      final confirmed = await _refreshConfirmedUser(
        patch,
        cancelToken: cancelToken,
      );
      return ProfileEditConfirmed(confirmed);
    } on ApiCancelled {
      rethrow;
    } on http.RequestAbortedException {
      throw const ApiCancelled();
    } on Object catch (error) {
      return ProfileEditSubmitFailure(
        ProfileEditFailureCode.repository,
        'In-app profile update failed: $error',
        retryable: true,
      );
    } finally {
      ownedClient?.close();
      request.clearSecret();
    }
  }

  Future<UserEntity> _refreshConfirmedUser(
    ProfilePatch patch, {
    CancelToken? cancelToken,
  }) async {
    try {
      final fresh = await userRepository.fetchDetail(
        patch.userId,
        cancelToken: cancelToken,
      );
      _lastDraft = fresh;
      return fresh;
    } on Object {
      // The web mutation already succeeded. If the App API refresh is
      // temporarily unavailable, keep the confirmed local draft visible
      // instead of showing stale values or claiming an unconfirmed save.
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

  Map<String, dynamic> _mergeProfile(
    Map<String, dynamic> current,
    ProfilePatch patch,
  ) {
    final profile = <String, dynamic>{...current};
    for (final entry in patch.textFields.entries) {
      final value = entry.value ?? '';
      switch (entry.key) {
        case ProfileField.displayName:
          profile['name'] = value;
        case ProfileField.comment:
          profile['comment'] = value;
        case ProfileField.webpage:
          profile['webpage'] = value;
        case ProfileField.avatar:
        case ProfileField.background:
          break;
      }
    }
    // The SPA explicitly nulls image URL fields in the JSON object when a
    // replacement file is present. Otherwise the server can retain the old
    // URL even though the multipart file was accepted.
    if (patch.images.containsKey(ProfileField.avatar)) {
      profile['profileImage'] = null;
    }
    if (patch.images.containsKey(ProfileField.background)) {
      profile['coverImage'] = null;
    }
    return profile;
  }

  Future<List<int>> _buildMultipartBody({
    required String boundary,
    required Map<String, dynamic> profile,
    required ProfilePatch patch,
  }) async {
    final buffer = BytesBuilder();

    void addField(String name, String value) {
      buffer.add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="$name"\r\n\r\n'
          '$value\r\n',
        ),
      );
    }

    addField('profile', jsonEncode(profile));

    // The current SPA sends image fields separately and clears the matching
    // JSON fields so the server does not retain the old URL when a new file
    // is uploaded. Keep the complete profile object for all untouched
    // privacy/external-service fields.

    final images = <String, ProfileImageSelection>{
      'profile_image': ?patch.images[ProfileField.avatar],
      'cover_image': ?patch.images[ProfileField.background],
    };
    for (final entry in images.entries) {
      final selection = entry.value;
      final bytes = await File(selection.path).readAsBytes();
      final extension = _extensionFor(selection.mimeType);
      buffer.add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="${entry.key}"; '
          'filename="profile_${entry.key}.$extension"\r\n'
          'Content-Type: ${selection.mimeType}\r\n\r\n',
        ),
      );
      buffer.add(bytes);
      buffer.add(utf8.encode('\r\n'));
    }
    buffer.add(utf8.encode('--$boundary--\r\n'));
    return buffer.takeBytes();
  }

  Future<_WebResponse> _fetchSettingsPage(
    http.Client client,
    String cookie, {
    CancelToken? cancelToken,
  }) async {
    final request = http.AbortableRequest(
      'GET',
      Uri.parse(settingsUrl),
      abortTrigger: cancelToken?.whenCancel,
    )..headers.addAll(_commonHeaders(cookie: cookie, acceptJson: false));
    return _send(client, request, cancelToken: cancelToken);
  }

  Future<_WebResponse> _fetchMyProfile(
    http.Client client, {
    required String cookie,
    required String csrf,
    CancelToken? cancelToken,
  }) async {
    final uri = Uri.parse(
      profileUrl,
    ).replace(queryParameters: const {'lang': 'zh'});
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: cancelToken?.whenCancel)
          ..headers.addAll(
            _commonHeaders(cookie: cookie, csrf: csrf, acceptJson: true),
          );
    return _send(client, request, cancelToken: cancelToken);
  }

  Future<_WebResponse> _postProfileUpdate(
    http.Client client, {
    required String cookie,
    required String csrf,
    required String boundary,
    required List<int> body,
    CancelToken? cancelToken,
  }) async {
    final request =
        http.AbortableRequest(
            'POST',
            Uri.parse(profileUpdateUrl),
            abortTrigger: cancelToken?.whenCancel,
          )
          ..headers.addAll(
            _commonHeaders(cookie: cookie, csrf: csrf, acceptJson: true),
          )
          ..headers['content-type'] = 'multipart/form-data; boundary=$boundary'
          ..bodyBytes = body;
    return _send(client, request, cancelToken: cancelToken);
  }

  Future<_WebResponse> _send(
    http.Client client,
    http.BaseRequest request, {
    CancelToken? cancelToken,
  }) async {
    try {
      if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
      final streamed = await client.send(request);
      final body = await streamed.stream.transform(utf8.decoder).join();
      if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
      return _WebResponse(
        status: streamed.statusCode,
        location: streamed.headers['location'],
        headers: streamed.headers,
        body: body,
      );
    } on ApiCancelled {
      rethrow;
    } on http.RequestAbortedException {
      throw const ApiCancelled();
    }
  }

  Map<String, String> _commonHeaders({
    required String cookie,
    required bool acceptJson,
    String? csrf,
  }) => {
    'cookie': cookie,
    'user-agent': _WebUserAgentClient.mobileUserAgent,
    'accept-language': 'zh-CN,zh;q=0.9,ja;q=0.8',
    'referer': settingsUrl,
    'origin': 'https://www.pixiv.net',
    'x-requested-with': 'XMLHttpRequest',
    if (acceptJson) 'accept': 'application/json',
    'x-csrf-token': ?csrf,
  };

  Map<String, dynamic>? _profileBody(_WebResponse response) {
    if (!_isSuccessStatus(response.status)) return null;
    final decoded = _decodeApiResponse(response);
    if (decoded.error) return null;
    final body = decoded.body;
    if (body is! Map) return null;
    final profile = body['profile'];
    final source = profile is Map ? profile : body;
    return <String, dynamic>{
      for (final entry in source.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  _DecodedApiResponse _decodeApiResponse(_WebResponse response) {
    if (response.body.trim().isEmpty) {
      return const _DecodedApiResponse(error: false, body: null);
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> &&
          (decoded.containsKey('error') || decoded.containsKey('body'))) {
        return _DecodedApiResponse(
          error: decoded['error'] == true,
          message: decoded['message']?.toString(),
          body: decoded['body'],
        );
      }
      if (decoded is Map) {
        return _DecodedApiResponse(
          error: false,
          body: <String, dynamic>{
            for (final entry in decoded.entries)
              if (entry.key is String) entry.key as String: entry.value,
          },
        );
      }
    } on Object {
      // The caller turns malformed successful responses into visible errors.
    }
    return const _DecodedApiResponse(error: true, body: null);
  }

  bool _isSuccessfulApiResponse(_WebResponse response) {
    if (!_isSuccessStatus(response.status)) return false;
    return !_decodeApiResponse(response).error;
  }

  ProfileEditSubmitFailure _failureForResponse(
    _WebResponse response, {
    required String fallback,
  }) {
    final decoded = _decodeApiResponse(response);
    final message = decoded.message;
    final authFailure = response.status == 401 || response.status == 403;
    final suffix = _errorSnippet(response.body);
    final detail = message == null ? suffix : '\n$message';
    return ProfileEditSubmitFailure(
      authFailure
          ? ProfileEditFailureCode.unavailable
          : ProfileEditFailureCode.repository,
      authFailure
          ? 'The in-app Pixiv session has expired; sign in again before saving'
          : '$fallback（${response.status}）$detail',
      retryable: true,
    );
  }

  static bool _isSuccessStatus(int status) => status >= 200 && status < 300;
}

class _WebResponse {
  const _WebResponse({
    required this.status,
    required this.body,
    required this.headers,
    this.location,
  });

  final int status;
  final String body;
  final Map<String, String> headers;
  final String? location;
}

class _DecodedApiResponse {
  const _DecodedApiResponse({
    required this.error,
    required this.body,
    this.message,
  });

  final bool error;
  final Object? body;
  final String? message;
}

/// Extracts the token used by Pixiv's same-origin web API.
///
/// Pixiv has emitted this value in a meta tag, hidden input, and escaped
/// `serverSerializedPreloadedState` at different times, so parsing accepts
/// all three forms without assuming one particular page renderer.
String? extractWebCsrfToken(String html) {
  final meta = RegExp(
    r'''<meta[^>]+(?:name|property)=["'](?:csrf-token|csrf_token)["'][^>]+content=["']([^"']+)''',
    caseSensitive: false,
  ).firstMatch(html);
  if (meta != null) return _htmlDecode(meta.group(1)!);

  final hidden = RegExp(
    r'''<input[^>]+name=["'](?:ct|tt|csrf-token|csrf_token)["'][^>]+value=["']([^"']+)''',
    caseSensitive: false,
  ).firstMatch(html);
  if (hidden != null) return _htmlDecode(hidden.group(1)!);

  // The serialized state is JSON nested in HTML, so quote escapes must be
  // normalized before matching the api.token object.
  final serializedState = _htmlDecode(html).replaceAll(r'\"', '"');
  final stateToken = RegExp(
    r'"api"\s*:\s*\{[^{}]{0,400}?"token"\s*:\s*"([^"\\]+)',
    caseSensitive: false,
  ).firstMatch(serializedState);
  return stateToken == null ? null : _htmlDecode(stateToken.group(1)!);
}

/// Retained for compatibility with the original adapter's parser tests and
/// for diagnosing older Pixiv HTML responses. Current saves use
/// `/ajax/my_profile` instead of these guessed form names.
Map<String, String> extractWebCurrentValues(String html) {
  final values = <String, String>{};
  final inputPattern = RegExp(
    r'''<input[^>]+name=["']([^"']+)["'][^>]*value=["']([^"']*)''',
    caseSensitive: false,
  );
  for (final match in inputPattern.allMatches(html)) {
    values[match.group(1)!] = _htmlDecode(match.group(2)!);
  }
  final textareaPattern = RegExp(
    r'''<textarea[^>]+name=["']([^"']+)["'][^>]*>([\s\S]*?)</textarea>''',
    caseSensitive: false,
  );
  for (final match in textareaPattern.allMatches(html)) {
    values[match.group(1)!] = _htmlDecode(match.group(2)!);
  }
  return values;
}

String _htmlDecode(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(r'\u0026', '&')
      .replaceAll(r'\u0022', '"')
      .trim();
}

String _errorSnippet(String body) {
  final sanitized = body.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim();
  if (sanitized.isEmpty) return '';
  return sanitized.length <= 160
      ? '：$sanitized'
      : '：${sanitized.substring(0, 160)}…';
}

String _extensionFor(String mimeType) {
  final normalized = mimeType.toLowerCase().split(';').first.trim();
  return switch (normalized) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/avif' => 'avif',
    _ => 'jpg',
  };
}

/// Adds a browser-compatible User-Agent while leaving route selection and
/// cookie handling in [PixivPolicyHttpClient].
class _WebUserAgentClient extends http.BaseClient {
  _WebUserAgentClient(this._inner);

  static const mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Mobile) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Mobile Safari/537.36';

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.putIfAbsent('user-agent', () => mobileUserAgent);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
