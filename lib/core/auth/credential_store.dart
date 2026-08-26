import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential.dart';

/// Raised when the platform secure storage cannot fulfil an operation.
///
/// Callers translate this into an observable re-auth flow instead of assuming
/// the account does not exist.
class CredentialStoreException implements Exception {
  CredentialStoreException(this.operation, this.accountId, this.cause);

  final String operation;
  final String accountId;
  final Object cause;

  @override
  String toString() =>
      'CredentialStoreException(operation: $operation, accountId: $accountId, cause: $cause)';
}

/// Isolated access to per-account secrets on platform secure storage.
abstract class CredentialStore {
  Future<Credential?> read(String accountId);
  Future<void> write(String accountId, Credential credential);
  Future<void> delete(String accountId);
}

/// Android Keystore backed implementation with a versioned key namespace.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const int schemaVersion = 1;
  static const String _keyPrefix = 'replica.credentials.v1.';

  final FlutterSecureStorage _storage;

  String _key(String accountId) => '$_keyPrefix$accountId';

  @override
  Future<Credential?> read(String accountId) async {
    String? raw;
    try {
      raw = await _storage.read(key: _key(accountId));
    } catch (error) {
      throw CredentialStoreException('read', accountId, error);
    }
    if (raw == null) return null;
    try {
      return _decode(raw);
    } on FormatException catch (error) {
      throw CredentialStoreException('read', accountId, error);
    }
  }

  @override
  Future<void> write(String accountId, Credential credential) async {
    final raw = jsonEncode({
      'v': schemaVersion,
      'accessToken': credential.accessToken,
      'refreshToken': credential.refreshToken,
      if (credential.cookie != null) 'cookie': credential.cookie,
    });
    try {
      await _storage.write(key: _key(accountId), value: raw);
    } catch (error) {
      throw CredentialStoreException('write', accountId, error);
    }
  }

  @override
  Future<void> delete(String accountId) async {
    try {
      await _storage.delete(key: _key(accountId));
    } catch (error) {
      throw CredentialStoreException('delete', accountId, error);
    }
  }

  Credential _decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    if (json['v'] != schemaVersion) {
      throw const FormatException('unsupported credential schema version');
    }
    final accessToken = json['accessToken'];
    final refreshToken = json['refreshToken'];
    if (accessToken is! String || refreshToken is! String) {
      throw const FormatException('credential payload is incomplete');
    }
    return Credential(
      accessToken: accessToken,
      refreshToken: refreshToken,
      cookie: json['cookie'] as String?,
    );
  }
}
