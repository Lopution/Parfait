import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Raised when the platform secure storage cannot fulfil a translation
/// credential operation. Credentials are never rendered as strings in
/// exception messages.
class TranslationCredentialsStoreException implements Exception {
  TranslationCredentialsStoreException(this.operation, this.cause);

  final String operation;
  final Object cause;

  @override
  String toString() =>
      'TranslationCredentialsStoreException(operation: $operation, cause: $cause)';
}

@immutable
class BaiduTranslationCredentials {
  const BaiduTranslationCredentials({
    required this.appId,
    required this.secret,
  });

  final String appId;
  final String secret;

  @override
  bool operator ==(Object other) =>
      other is BaiduTranslationCredentials &&
      other.appId == appId &&
      other.secret == secret;

  @override
  int get hashCode => Object.hash(appId, secret);

  @override
  String toString() => 'BaiduTranslationCredentials(appId: $appId)';
}

@immutable
class LlmTranslationCredentials {
  const LlmTranslationCredentials({
    required this.baseUrl,
    required this.apiKey,
    this.model,
  });

  /// HTTPS only; the transport rejects plain HTTP endpoints.
  final String baseUrl;
  final String apiKey;
  final String? model;

  @override
  bool operator ==(Object other) =>
      other is LlmTranslationCredentials &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.model == model;

  @override
  int get hashCode => Object.hash(baseUrl, apiKey, model);

  @override
  String toString() => 'LlmTranslationCredentials(baseUrl: $baseUrl)';
}

/// A doubao.com web login captured from the in-app login WebView.
@immutable
class DoubaoWebSession {
  const DoubaoWebSession({required this.cookie, required this.teaUuid});

  /// Raw `Cookie` header value for www.doubao.com.
  final String cookie;

  /// 18-digit device id generated once per login; Doubao's web client sends
  /// it as both `tea_uuid` and `web_id`.
  final String teaUuid;

  @override
  bool operator ==(Object other) =>
      other is DoubaoWebSession &&
      other.cookie == cookie &&
      other.teaUuid == teaUuid;

  @override
  int get hashCode => Object.hash(cookie, teaUuid);

  @override
  String toString() => 'DoubaoWebSession(teaUuid: $teaUuid)';
}

/// Isolated read/write/delete access to translation credentials.
///
/// Deliberately separate from the Pixiv account [CredentialStore] and from
/// [AppSettings]: these secrets are never serialized into the settings JSON,
/// the account-transfer clipboard, logs or crash fields (D2). A distinct
/// fixed key namespace guarantees no key collision with account data.
abstract class TranslationCredentialStore {
  Future<BaiduTranslationCredentials?> readBaidu();
  Future<void> writeBaidu(BaiduTranslationCredentials credentials);
  Future<LlmTranslationCredentials?> readLlm();
  Future<void> writeLlm(LlmTranslationCredentials credentials);
  Future<DoubaoWebSession?> readDoubao();
  Future<void> writeDoubao(DoubaoWebSession session);

  /// Key-existence probes for summary UI (D8): they answer "configured?"
  /// without loading secret values, so summaries never render secrets.
  Future<bool> hasBaidu();
  Future<bool> hasLlm();
  Future<bool> hasDoubao();

  Future<void> deleteBaidu();
  Future<void> deleteLlm();
  Future<void> deleteDoubao();
  Future<void> deleteAll();
}

/// Android Keystore backed implementation with an isolated key namespace.
class SecureTranslationCredentialStore implements TranslationCredentialStore {
  SecureTranslationCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _keyNamespace = 'replica.translation.v1.';
  static const _baiduAppIdKey = '${_keyNamespace}baidu.app_id';
  static const _baiduSecretKey = '${_keyNamespace}baidu.secret';
  static const _llmBaseUrlKey = '${_keyNamespace}llm.base_url';
  static const _llmApiKeyKey = '${_keyNamespace}llm.api_key';
  static const _llmModelKey = '${_keyNamespace}llm.model';
  static const _doubaoCookieKey = '${_keyNamespace}doubao.cookie';
  static const _doubaoTeaUuidKey = '${_keyNamespace}doubao.tea_uuid';

  final FlutterSecureStorage _storage;

  @override
  Future<BaiduTranslationCredentials?> readBaidu() async {
    final appId = await _read(_baiduAppIdKey);
    final secret = await _read(_baiduSecretKey);
    if (appId == null || secret == null) return null;
    return BaiduTranslationCredentials(appId: appId, secret: secret);
  }

  @override
  Future<void> writeBaidu(BaiduTranslationCredentials credentials) async {
    await _write(_baiduAppIdKey, credentials.appId);
    await _write(_baiduSecretKey, credentials.secret);
  }

  @override
  Future<LlmTranslationCredentials?> readLlm() async {
    final baseUrl = await _read(_llmBaseUrlKey);
    final apiKey = await _read(_llmApiKeyKey);
    if (baseUrl == null || apiKey == null) return null;
    return LlmTranslationCredentials(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: await _read(_llmModelKey),
    );
  }

  @override
  Future<void> writeLlm(LlmTranslationCredentials credentials) async {
    await _write(_llmBaseUrlKey, credentials.baseUrl);
    await _write(_llmApiKeyKey, credentials.apiKey);
    final model = credentials.model;
    if (model == null || model.isEmpty) {
      await _storage.delete(key: _llmModelKey);
    } else {
      await _write(_llmModelKey, model);
    }
  }

  @override
  Future<DoubaoWebSession?> readDoubao() async {
    final cookie = await _read(_doubaoCookieKey);
    final teaUuid = await _read(_doubaoTeaUuidKey);
    if (cookie == null || teaUuid == null) return null;
    return DoubaoWebSession(cookie: cookie, teaUuid: teaUuid);
  }

  @override
  Future<void> writeDoubao(DoubaoWebSession session) async {
    await _write(_doubaoCookieKey, session.cookie);
    await _write(_doubaoTeaUuidKey, session.teaUuid);
  }

  @override
  Future<bool> hasBaidu() => _hasKeys(const [_baiduAppIdKey, _baiduSecretKey]);

  @override
  Future<bool> hasLlm() => _hasKeys(const [_llmBaseUrlKey, _llmApiKeyKey]);

  @override
  Future<bool> hasDoubao() =>
      _hasKeys(const [_doubaoCookieKey, _doubaoTeaUuidKey]);

  Future<bool> _hasKeys(List<String> keys) async {
    try {
      for (final key in keys) {
        if (!await _storage.containsKey(key: key)) return false;
      }
      return true;
    } catch (error) {
      throw TranslationCredentialsStoreException('read', error);
    }
  }

  @override
  Future<void> deleteBaidu() => _deleteKeys([_baiduAppIdKey, _baiduSecretKey]);

  @override
  Future<void> deleteLlm() =>
      _deleteKeys([_llmBaseUrlKey, _llmApiKeyKey, _llmModelKey]);

  @override
  Future<void> deleteDoubao() =>
      _deleteKeys([_doubaoCookieKey, _doubaoTeaUuidKey]);

  @override
  Future<void> deleteAll() => _deleteKeys([
    _baiduAppIdKey,
    _baiduSecretKey,
    _llmBaseUrlKey,
    _llmApiKeyKey,
    _llmModelKey,
    _doubaoCookieKey,
    _doubaoTeaUuidKey,
  ]);

  Future<void> _deleteKeys(List<String> keys) async {
    try {
      for (final key in keys) {
        await _storage.delete(key: key);
      }
    } catch (error) {
      throw TranslationCredentialsStoreException('delete', error);
    }
  }

  Future<String?> _read(String key) async {
    try {
      final value = await _storage.read(key: key);
      return (value == null || value.isEmpty) ? null : value;
    } catch (error) {
      throw TranslationCredentialsStoreException('read', error);
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (error) {
      throw TranslationCredentialsStoreException('write', error);
    }
  }
}
