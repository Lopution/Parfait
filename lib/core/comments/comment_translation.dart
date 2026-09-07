import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../settings/app_settings.dart';
import '../settings/settings_controller.dart';
import 'translation_credentials.dart';

/// Failure classification surfaced to the comment overlay. The overlay never
/// falls back to a different provider on its own; a failure stays visible.
enum CommentTranslationFailureKind {
  disabled,
  notConfigured,
  invalidCredentials,
  rateLimited,
  network,
  malformed,
  unsupportedLanguage,
  other,
}

class CommentTranslationUnavailable implements Exception {
  const CommentTranslationUnavailable(this.kind);

  final CommentTranslationFailureKind kind;

  @override
  String toString() => 'CommentTranslationUnavailable($kind)';
}

class CommentTranslationError implements Exception {
  const CommentTranslationError(
    this.reason, [
    this.kind = CommentTranslationFailureKind.other,
  ]);

  final String reason;
  final CommentTranslationFailureKind kind;

  @override
  String toString() => 'CommentTranslationError($reason)';
}

abstract interface class CommentTranslationService {
  Future<String> translate(String text, {required String targetLanguage});
}

/// Resolved at request scope from secure storage: a cleared credential is
/// observed immediately on the next tap, never reused from a cached state.
abstract interface class CommentTranslationTransport {
  Future<String> translate(String text, {required String targetLanguage});
}

/// Google gtx compatibility path. Retained for users who explicitly saved
/// Google before (D2); there is no automatic provider fallback.
class GoogleCommentTranslationService implements CommentTranslationTransport {
  GoogleCommentTranslationService(this._client);

  static const _host = 'translate.googleapis.com';
  static const _timeout = Duration(seconds: 15);

  final http.Client _client;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const CommentTranslationError('empty source text');
    }
    final target = targetLanguage.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(target)) {
      throw const CommentTranslationError(
        'invalid target language',
        CommentTranslationFailureKind.unsupportedLanguage,
      );
    }
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.https(_host, '/translate_a/single', {
              'client': 'gtx',
              'dt': 't',
              'sl': 'auto',
              'tl': target,
              'q': source,
            }),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const CommentTranslationError(
        'translation timed out',
        CommentTranslationFailureKind.network,
      );
    } on SocketException {
      throw const CommentTranslationError(
        'translation network failure',
        CommentTranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const CommentTranslationError(
        'translation network failure',
        CommentTranslationFailureKind.network,
      );
    }
    if (response.statusCode == 429) {
      throw const CommentTranslationError(
        'translation rate limited',
        CommentTranslationFailureKind.rateLimited,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const CommentTranslationError(
        'translation http failure',
        CommentTranslationFailureKind.network,
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const CommentTranslationError(
        'malformed response',
        CommentTranslationFailureKind.malformed,
      );
    }
    if (decoded is! List || decoded.isEmpty || decoded.first is! List) {
      throw const CommentTranslationError(
        'malformed response',
        CommentTranslationFailureKind.malformed,
      );
    }
    final translations = decoded.first as List;
    final parts = <String>[];
    for (final item in translations) {
      if (item is List && item.isNotEmpty && item.first is String) {
        parts.add(item.first as String);
      }
    }
    final result = parts.join();
    if (result.trim().isEmpty) {
      throw const CommentTranslationError(
        'empty translation',
        CommentTranslationFailureKind.malformed,
      );
    }
    return result;
  }
}

/// Baidu general translation (D2): AppID + secret from the isolated secure
/// store, standard MD5 signature, HTTPS form post. AppID/secret only exist
/// inside this request scope.
class BaiduCommentTranslationService implements CommentTranslationTransport {
  BaiduCommentTranslationService(this._client, this._now, this._store);

  static const _host = 'https://fanyi-api.baidu.com/api/trans/vip/translate';
  static const _timeout = Duration(seconds: 15);

  /// Free tier (verified 2026-09-03): 50k characters/month, QPS 1 for
  /// personal-certified users. Constants are not displayed anywhere; the
  /// settings page carries the verified number in its own copy.
  static const int _maxBodyBytes = 512 * 1024;

  final http.Client _client;
  final DateTime Function() _now;
  final TranslationCredentialStore _store;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const CommentTranslationError('empty source text');
    }
    if (utf8.encode(source).length > _maxBodyBytes) {
      throw const CommentTranslationError('source text is too long');
    }
    final target = _targetCode(targetLanguage);
    final credentials = await _store.readBaidu();
    if (credentials == null) {
      throw const CommentTranslationUnavailable(
        CommentTranslationFailureKind.notConfigured,
      );
    }
    final salt = _now().millisecondsSinceEpoch.toString();
    final sign = md5
        .convert(
          utf8.encode('${credentials.appId}$source$salt${credentials.secret}'),
        )
        .toString();

    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(_host),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
              'User-Agent': 'pixiv-func/1.0',
            },
            body: {
              'q': source,
              'from': 'auto',
              'to': target,
              'appid': credentials.appId,
              'salt': salt,
              'sign': sign,
            },
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const CommentTranslationError(
        'translation timed out',
        CommentTranslationFailureKind.network,
      );
    } on SocketException {
      throw const CommentTranslationError(
        'translation network failure',
        CommentTranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const CommentTranslationError(
        'translation network failure',
        CommentTranslationFailureKind.network,
      );
    }
    if (response.statusCode == 429) {
      throw const CommentTranslationError(
        'baidu rate limited',
        CommentTranslationFailureKind.rateLimited,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const CommentTranslationError(
        'baidu http failure',
        CommentTranslationFailureKind.network,
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const CommentTranslationError(
        'malformed response',
        CommentTranslationFailureKind.malformed,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CommentTranslationError(
        'malformed response',
        CommentTranslationFailureKind.malformed,
      );
    }
    final errorCode = decoded['error_code'];
    if (errorCode != null) {
      throw _mapBaiduError(errorCode);
    }
    final results = decoded['trans_result'];
    if (results is! List || results.isEmpty) {
      throw const CommentTranslationError(
        'empty translation',
        CommentTranslationFailureKind.malformed,
      );
    }
    final parts = <String>[];
    for (final entry in results) {
      if (entry is! Map<String, dynamic>) continue;
      final dst = entry['dst'];
      if (dst is String && dst.trim().isNotEmpty) parts.add(dst);
    }
    final result = parts.join('\n').trim();
    if (result.isEmpty) {
      throw const CommentTranslationError(
        'empty translation',
        CommentTranslationFailureKind.malformed,
      );
    }
    return result;
  }

  CommentTranslationError _mapBaiduError(Object errorCode) {
    switch (errorCode.toString()) {
      case '52003':
      case '54001':
      case '54002':
      case '90107':
        return const CommentTranslationError(
          'baidu credentials invalid',
          CommentTranslationFailureKind.invalidCredentials,
        );
      case '54003':
      case '54005':
        return const CommentTranslationError(
          'baidu rate limited',
          CommentTranslationFailureKind.rateLimited,
        );
      case '54000':
      case '54004':
        return const CommentTranslationError(
          'baidu quota exhausted',
          CommentTranslationFailureKind.rateLimited,
        );
      case '58002':
        return const CommentTranslationError(
          'baidu service closed',
          CommentTranslationFailureKind.other,
        );
      default:
        return CommentTranslationError(
          'baidu error $errorCode',
          CommentTranslationFailureKind.other,
        );
    }
  }

  static String _targetCode(String targetLanguage) {
    // The map is closed: unsupported targets are visible, not silently
    // translated into a wrong language.
    switch (targetLanguage.trim().toLowerCase()) {
      case 'zh':
      case 'zh-cn':
      case 'zh-tw':
        return 'zh';
      case 'en':
        return 'en';
      case 'ja':
      case 'ja-jp':
        return 'jp';
      case 'ko':
        return 'kor';
      case 'fr':
        return 'fra';
      case 'es':
        return 'spa';
      case 'it':
        return 'it';
      case 'de':
        return 'de';
      case 'pt':
        return 'pt';
      case 'ru':
        return 'ru';
      case 'nl':
        return 'nl';
      case 'pl':
        return 'pl';
      case 'tr':
        return 'tr';
      case 'ar':
        return 'ara';
      case 'vi':
        return 'vie';
      case 'th':
        return 'th';
      case 'id':
        return 'id';
      default:
        throw const CommentTranslationError(
          'unsupported target language',
          CommentTranslationFailureKind.unsupportedLanguage,
        );
    }
  }
}

/// OpenAI-compatible chat completions transport (D2): HTTPS only, fixed
/// system prompt, zero configurable prompt/model advanced parameters.
class LlmCommentTranslationService implements CommentTranslationTransport {
  LlmCommentTranslationService(this._client, this._store);

  static const _timeout = Duration(seconds: 40);
  static const _maxResponseBytes = 256 * 1024;
  static const _prompt =
      'You are a translation engine for Pixiv comments. Translate the user '
      'text into the requested language. Return only the translation with no '
      'quotes, no notes, no explanation. Preserve emoticons, line breaks, '
      'emoji and punctuation.';

  final http.Client _client;
  final TranslationCredentialStore _store;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const CommentTranslationError('empty source text');
    }
    final target = targetLanguage.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(target)) {
      throw const CommentTranslationError(
        'invalid target language',
        CommentTranslationFailureKind.unsupportedLanguage,
      );
    }
    final credentials = await _store.readLlm();
    if (credentials == null) {
      throw const CommentTranslationUnavailable(
        CommentTranslationFailureKind.notConfigured,
      );
    }
    final base = credentials.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final endpoint = Uri.tryParse('$base/chat/completions');
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty) {
      throw const CommentTranslationError(
        'LLM endpoint is not HTTPS',
        CommentTranslationFailureKind.invalidCredentials,
      );
    }
    final request = http.Request('POST', endpoint)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Authorization'] = 'Bearer ${credentials.apiKey}'
      ..headers['User-Agent'] = 'pixiv-func/1.0'
      ..body = jsonEncode({
        'model': (credentials.model?.isEmpty ?? true)
            ? 'gpt-4o-mini'
            : credentials.model,
        'temperature': 0.2,
        'messages': [
          {'role': 'system', 'content': _prompt},
          {'role': 'user', 'content': 'Translate into $target:\n$source'},
        ],
      });
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(_timeout),
      ).timeout(_timeout);
    } on TimeoutException {
      throw const CommentTranslationError(
        'translation timed out',
        CommentTranslationFailureKind.network,
      );
    } on SocketException {
      throw const CommentTranslationError(
        'translation network failure',
        CommentTranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const CommentTranslationError(
        'translation network failure',
        CommentTranslationFailureKind.network,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const CommentTranslationError(
        'LLM credentials invalid',
        CommentTranslationFailureKind.invalidCredentials,
      );
    }
    if (response.statusCode == 429) {
      throw const CommentTranslationError(
        'LLM rate limited',
        CommentTranslationFailureKind.rateLimited,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const CommentTranslationError(
        'LLM http failure',
        CommentTranslationFailureKind.network,
      );
    }
    if (response.bodyBytes.length > _maxResponseBytes) {
      throw const CommentTranslationError(
        'LLM response too large',
        CommentTranslationFailureKind.malformed,
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const CommentTranslationError(
        'malformed response',
        CommentTranslationFailureKind.malformed,
      );
    }
    final content = _extractContent(decoded);
    if (content == null) {
      throw const CommentTranslationError(
        'malformed response',
        CommentTranslationFailureKind.malformed,
      );
    }
    return content;
  }

  static String? _extractContent(Object? decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, dynamic>) return null;
    final message = first['message'];
    if (message is! Map<String, dynamic>) return null;
    final content = message['content'];
    if (content is! String) return null;
    final trimmed = content.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class DisabledCommentTranslationService implements CommentTranslationService {
  const DisabledCommentTranslationService();

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    throw const CommentTranslationUnavailable(
      CommentTranslationFailureKind.disabled,
    );
  }
}

final commentTranslationServiceProvider = Provider<CommentTranslationService>((
  ref,
) {
  final client = http.Client();
  ref.onDispose(client.close);
  final store = ref.watch(translationCredentialStoreProvider);
  return ConfiguredCommentTranslationService(
    resolveProvider: () => ref.read(translationSelectionProvider),
    store: store,
    google: GoogleCommentTranslationService(client),
    baidu: BaiduCommentTranslationService(client, DateTime.now, store),
    llm: LlmCommentTranslationService(client, store),
  );
});

/// Isolated secure storage for translation credentials (D2). A single
/// instance shared by the settings UI and the transports.
final translationCredentialStoreProvider = Provider<TranslationCredentialStore>(
  (ref) => SecureTranslationCredentialStore(),
);

/// Live translation provider selection (non-secret). A cleared credential is
/// observed on the next tap because selection and credentials are read per
/// request.
final translationSelectionProvider = Provider<TranslationProvider>((ref) {
  return ref.watch(settingsProvider).value?.translationProvider ??
      TranslationProvider.disabled;
});

class ConfiguredCommentTranslationService implements CommentTranslationService {
  ConfiguredCommentTranslationService({
    required this.resolveProvider,
    required this.store,
    required this.google,
    required this.baidu,
    required this.llm,
  });

  final TranslationProvider Function() resolveProvider;
  final TranslationCredentialStore store;
  final CommentTranslationTransport google;
  final CommentTranslationTransport baidu;
  final CommentTranslationTransport llm;

  @override
  Future<String> translate(String text, {required String targetLanguage}) {
    final provider = resolveProvider();
    switch (provider) {
      case TranslationProvider.disabled:
        return const DisabledCommentTranslationService().translate(
          text,
          targetLanguage: targetLanguage,
        );
      case TranslationProvider.google:
        return google.translate(text, targetLanguage: targetLanguage);
      case TranslationProvider.baidu:
        return baidu.translate(text, targetLanguage: targetLanguage);
      case TranslationProvider.translationLlm:
        return llm.translate(text, targetLanguage: targetLanguage);
    }
  }
}
