import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'account.dart';
import 'credential.dart';

/// Publicly observable outcomes of the account-transfer boundary.
///
/// The names intentionally describe validation and transport outcomes, not
/// cryptographic guarantees. In particular, [corrupt] does not mean that a
/// malicious clipboard writer cannot produce a new valid checksum.
enum AccountTransferErrorCode {
  corrupt,
  expired,
  replayedOnThisDevice,
  credentialInvalid,
  verificationUnavailable,
  noUsableAccount,
  credentialUnavailable,
  clipboardUnavailable,
  storageFailure,
}

/// Safe, bounded error for the clipboard transfer flow.
///
/// [cause] is retained for an owning caller that needs diagnostics, but is
/// deliberately omitted from [toString] so platform errors cannot become a
/// credential or clipboard-content log sink.
class AccountTransferException implements Exception {
  const AccountTransferException(this.code, this.publicMessage, {this.cause});

  final AccountTransferErrorCode code;
  final String publicMessage;
  final Object? cause;

  @override
  String toString() => 'AccountTransferException(${code.name})';
}

/// The minimum account information needed to bind a transfer to the server
/// identity. Display name, mail address and image URLs are intentionally not
/// trusted from the clipboard; the verifier obtains fresh metadata.
class TransferAccountPayload {
  const TransferAccountPayload({
    required this.accountId,
    required this.userId,
    required this.credential,
  });

  final String accountId;
  final int userId;
  final Credential credential;

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'userId': userId,
    'credential': {
      'accessToken': credential.accessToken,
      'refreshToken': credential.refreshToken,
      if (credential.cookie != null) 'cookie': credential.cookie,
    },
  };
}

/// Versioned, expiring account-transfer envelope.
///
/// This is an intentionally transparent transport format. The SHA-256 field
/// is an unkeyed corruption checksum: it detects accidental damage and
/// truncation, but does not provide authenticity or confidentiality. A future
/// password/pairing/public-key design must use a new version and UX.
class TransferEnvelope {
  TransferEnvelope._({
    required this.version,
    required this.payloadType,
    required this.schema,
    required this.createdAt,
    required this.expiresAt,
    required this.nonce,
    required this.payload,
  }) : checksum = _checksumFor(
         _unsignedJson(
           version: version,
           payloadType: payloadType,
           schema: schema,
           createdAt: createdAt,
           expiresAt: expiresAt,
           nonce: nonce,
           payload: payload,
         ),
       );

  static const int currentVersion = 1;
  static const String currentPayloadType = 'pixiv-account-transfer';
  static const int currentSchema = 1;
  static const int maxEncodedLength = 32 * 1024;
  static const int maxDecodedBytes = 24 * 1024;
  static const Duration defaultTtl = Duration(minutes: 5);
  static const Duration maxLifetime = Duration(minutes: 10);
  static const Duration maxClockSkew = Duration(minutes: 2);

  static const int _nonceBytes = 16;
  static final Random _random = Random.secure();

  final int version;
  final String payloadType;
  final int schema;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String nonce;
  final TransferAccountPayload payload;
  final String checksum;

  /// Creates a new export envelope. [nonce] is injectable only to make
  /// deterministic tests possible; production callers leave it null.
  factory TransferEnvelope.create({
    required Account account,
    required Credential credential,
    DateTime? now,
    Duration ttl = defaultTtl,
    String? nonce,
  }) {
    final createdAt = (now ?? DateTime.now()).toUtc();
    if (ttl <= Duration.zero || ttl > maxLifetime) {
      throw const AccountTransferException(
        AccountTransferErrorCode.corrupt,
        'transfer lifetime is invalid',
      );
    }
    final payload = TransferAccountPayload(
      accountId: account.id,
      userId: account.userId,
      credential: credential,
    );
    final envelope = TransferEnvelope._(
      version: currentVersion,
      payloadType: currentPayloadType,
      schema: currentSchema,
      createdAt: createdAt,
      expiresAt: createdAt.add(ttl),
      nonce: nonce ?? _newNonce(),
      payload: payload,
    );
    _validatePayload(payload);
    _validateNonce(envelope.nonce);
    return envelope;
  }

  /// Parses the canonical standard-base64 representation copied to the
  /// clipboard. No whitespace, URL-safe alphabet or unknown JSON field is
  /// accepted.
  factory TransferEnvelope.parse(String encoded, {DateTime? now}) {
    if (encoded.isEmpty || encoded.length > maxEncodedLength) {
      throw _corrupt();
    }
    if (!_strictBase64.hasMatch(encoded) || encoded.length % 4 != 0) {
      throw _corrupt();
    }

    late final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
      if (base64Encode(bytes) != encoded || bytes.length > maxDecodedBytes) {
        throw _corrupt();
      }
    } on AccountTransferException {
      rethrow;
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.corrupt,
        'clipboard data is not valid base64',
        cause: error,
      );
    }

    late final String raw;
    try {
      raw = utf8.decode(bytes);
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.corrupt,
        'clipboard data is not valid UTF-8',
        cause: error,
      );
    }

    late final Map<String, Object?> root;
    try {
      root = _object(jsonDecode(raw));
    } on AccountTransferException {
      rethrow;
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.corrupt,
        'clipboard data is not valid JSON',
        cause: error,
      );
    }
    _requireKeys(root, const {
      'version',
      'payloadType',
      'schema',
      'createdAt',
      'expiresAt',
      'nonce',
      'payload',
      'checksum',
    });

    final version = _int(root, 'version');
    final payloadType = _string(root, 'payloadType', maxLength: 80);
    final schema = _int(root, 'schema');
    if (version != currentVersion ||
        payloadType != currentPayloadType ||
        schema != currentSchema) {
      throw _corrupt();
    }

    final createdAt = _instant(root, 'createdAt');
    final expiresAt = _instant(root, 'expiresAt');
    if (!expiresAt.isAfter(createdAt) ||
        expiresAt.difference(createdAt) > maxLifetime) {
      throw _corrupt();
    }

    final nonce = _string(root, 'nonce', maxLength: 64);
    _validateNonce(nonce);
    final payloadMap = _object(root['payload']);
    _requireKeys(payloadMap, const {'accountId', 'userId', 'credential'});
    final accountId = _string(payloadMap, 'accountId', maxLength: 32);
    final userId = _int(payloadMap, 'userId');
    final credentialMap = _object(payloadMap['credential']);
    final credentialKeys = credentialMap.keys.toSet();
    if (!(setEquals(credentialKeys, const {'accessToken', 'refreshToken'}) ||
        setEquals(credentialKeys, const {
          'accessToken',
          'refreshToken',
          'cookie',
        }))) {
      throw _corrupt();
    }
    final credential = Credential(
      accessToken: _secret(credentialMap, 'accessToken', maxLength: 8192),
      refreshToken: _secret(credentialMap, 'refreshToken', maxLength: 8192),
      cookie: credentialMap.containsKey('cookie')
          ? _secret(credentialMap, 'cookie', maxLength: 16384)
          : null,
    );
    final payload = TransferAccountPayload(
      accountId: accountId,
      userId: userId,
      credential: credential,
    );
    _validatePayload(payload);

    final checksum = _string(root, 'checksum', maxLength: 64);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      throw _corrupt();
    }
    final expected = _checksumFor(
      _unsignedJson(
        version: version,
        payloadType: payloadType,
        schema: schema,
        createdAt: createdAt,
        expiresAt: expiresAt,
        nonce: nonce,
        payload: payload,
      ),
    );
    if (checksum != expected) {
      throw _corrupt();
    }

    final result = TransferEnvelope._(
      version: version,
      payloadType: payloadType,
      schema: schema,
      createdAt: createdAt,
      expiresAt: expiresAt,
      nonce: nonce,
      payload: payload,
    );
    // The private constructor recalculates the checksum from canonical data;
    // this equality also protects against a future constructor drift.
    if (result.checksum != checksum) throw _corrupt();

    // Integrity is checked before semantic time outcomes. A clipboard value
    // with a rewritten timestamp must be classified as corrupt, even when the
    // rewritten value would otherwise look expired or future-issued.
    final current = (now ?? DateTime.now()).toUtc();
    if (!expiresAt.isAfter(current)) {
      throw const AccountTransferException(
        AccountTransferErrorCode.expired,
        'clipboard transfer has expired',
      );
    }
    if (createdAt.isAfter(current.add(maxClockSkew))) {
      throw _corrupt();
    }
    return result;
  }

  static final RegExp _strictBase64 = RegExp(
    r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
  );

  String encode() => base64Encode(utf8.encode(jsonEncode(toJson())));

  Map<String, Object?> toJson() => {
    ..._unsignedJson(
      version: version,
      payloadType: payloadType,
      schema: schema,
      createdAt: createdAt,
      expiresAt: expiresAt,
      nonce: nonce,
      payload: payload,
    ),
    'checksum': checksum,
  };

  @override
  String toString() =>
      'TransferEnvelope(version: $version, type: $payloadType, '
      'createdAt: $createdAt, expiresAt: $expiresAt, nonce: redacted)';

  static String _newNonce() => base64UrlEncode(
    List<int>.generate(_nonceBytes, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');

  static Map<String, Object?> _unsignedJson({
    required int version,
    required String payloadType,
    required int schema,
    required DateTime createdAt,
    required DateTime expiresAt,
    required String nonce,
    required TransferAccountPayload payload,
  }) => {
    'version': version,
    'payloadType': payloadType,
    'schema': schema,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'nonce': nonce,
    'payload': payload.toJson(),
  };

  static String _checksumFor(Map<String, Object?> value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static void _validatePayload(TransferAccountPayload payload) {
    if (payload.userId <= 0 ||
        payload.accountId != '${payload.userId}' ||
        !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(payload.accountId)) {
      throw _corrupt();
    }
    _validateSecretValue(payload.credential.accessToken, 8192);
    _validateSecretValue(payload.credential.refreshToken, 8192);
    final cookie = payload.credential.cookie;
    if (cookie != null) _validateSecretValue(cookie, 16384);
  }

  static void _validateNonce(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(value)) throw _corrupt();
    try {
      final decoded = base64Url.decode('$value==');
      if (decoded.length != _nonceBytes ||
          base64UrlEncode(decoded).replaceAll('=', '') != value) {
        throw _corrupt();
      }
    } on AccountTransferException {
      rethrow;
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.corrupt,
        'transfer nonce is malformed',
        cause: error,
      );
    }
  }

  static void _validateSecretValue(String value, int maxLength) {
    if (value.isEmpty ||
        value.length > maxLength ||
        value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw _corrupt();
    }
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map) throw _corrupt();
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) throw _corrupt();
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static void _requireKeys(Map<String, Object?> value, Set<String> expected) {
    if (!setEquals(value.keys.toSet(), expected)) throw _corrupt();
  }

  static int _int(Map<String, Object?> value, String key) {
    final result = value[key];
    if (result is! int) throw _corrupt();
    return result;
  }

  static String _string(
    Map<String, Object?> value,
    String key, {
    required int maxLength,
  }) {
    final result = value[key];
    if (result is! String ||
        result.isEmpty ||
        result.length > maxLength ||
        result.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw _corrupt();
    }
    return result;
  }

  static String _secret(
    Map<String, Object?> value,
    String key, {
    required int maxLength,
  }) => _string(value, key, maxLength: maxLength);

  static DateTime _instant(Map<String, Object?> value, String key) {
    final raw = _string(value, key, maxLength: 40);
    if (!RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$',
    ).hasMatch(raw)) {
      throw _corrupt();
    }
    final result = DateTime.tryParse(raw);
    if (result == null || !result.isUtc) throw _corrupt();
    return result;
  }

  static AccountTransferException _corrupt() => const AccountTransferException(
    AccountTransferErrorCode.corrupt,
    'clipboard data is corrupt',
  );
}

/// A target-local replay boundary. Implementations may persist only a
/// one-way nonce digest and expiry; they must never persist the payload or
/// credential.
abstract interface class TransferReplayStore {
  Future<bool> claim(String nonce, DateTime expiresAt);
}

/// Deterministic replay store for tests and short-lived platforms.
class InMemoryTransferReplayStore implements TransferReplayStore {
  InMemoryTransferReplayStore({DateTime Function()? now})
    : _now = now ?? _utcNow;

  final DateTime Function() _now;
  final List<_ReplayEntry> _entries = [];

  /// Test-only metadata proves that the raw nonce is never retained.
  List<Map<String, Object>> get debugEntries => [
    for (final entry in _entries)
      Map.unmodifiable(<String, Object>{
        'digest': entry.digest,
        'expiresAt': entry.expiresAt.toIso8601String(),
      }),
  ];

  @override
  Future<bool> claim(String nonce, DateTime expiresAt) async {
    _prune();
    final digest = _nonceDigest(nonce);
    if (_entries.any((entry) => entry.digest == digest)) return false;
    _entries.add(_ReplayEntry(digest, expiresAt.toUtc()));
    return true;
  }

  void _prune() {
    final current = _now().toUtc();
    _entries.removeWhere((entry) => !entry.expiresAt.isAfter(current));
  }
}

/// Secure-storage-backed replay store. Only nonce digests and expiry are
/// stored, never the original nonce, account data or credential.
class SecureTransferReplayStore implements TransferReplayStore {
  SecureTransferReplayStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _storageKey = 'replica.transfer.replay.v1';

  final FlutterSecureStorage _storage;
  Future<void> _tail = Future<void>.value();

  @override
  Future<bool> claim(String nonce, DateTime expiresAt) => _exclusive(() async {
    final current = DateTime.now().toUtc();
    final entries = await _read();
    final active = entries
        .where((entry) => entry.expiresAt.isAfter(current))
        .toList();
    final digest = _nonceDigest(nonce);
    if (active.any((entry) => entry.digest == digest)) {
      if (active.length != entries.length) await _write(active);
      return false;
    }
    active.add(_ReplayEntry(digest, expiresAt.toUtc()));
    await _write(active);
    return true;
  });

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return next;
  }

  Future<List<_ReplayEntry>> _read() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('replay store is not a list');
      }
      final entries = <_ReplayEntry>[];
      for (final item in decoded) {
        final map = TransferEnvelope._object(item);
        TransferEnvelope._requireKeys(map, const {'digest', 'expiresAt'});
        final digest = TransferEnvelope._string(map, 'digest', maxLength: 64);
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
          throw const FormatException('replay digest is malformed');
        }
        final expiresAt = TransferEnvelope._instant(map, 'expiresAt');
        entries.add(_ReplayEntry(digest, expiresAt));
      }
      return entries;
    } on AccountTransferException catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.storageFailure,
        'transfer replay storage is corrupt',
        cause: error,
      );
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.storageFailure,
        'transfer replay storage is unavailable',
        cause: error,
      );
    }
  }

  Future<void> _write(List<_ReplayEntry> entries) async {
    try {
      await _storage.write(
        key: _storageKey,
        value: jsonEncode([
          for (final entry in entries)
            {
              'digest': entry.digest,
              'expiresAt': entry.expiresAt.toUtc().toIso8601String(),
            },
        ]),
      );
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.storageFailure,
        'transfer replay storage is unavailable',
        cause: error,
      );
    }
  }
}

class _ReplayEntry {
  const _ReplayEntry(this.digest, this.expiresAt);

  final String digest;
  final DateTime expiresAt;
}

String _nonceDigest(String nonce) =>
    sha256.convert(utf8.encode(nonce)).toString();

DateTime _utcNow() => DateTime.now().toUtc();

bool setEquals(Set<Object?> left, Set<Object?> right) =>
    left.length == right.length && left.containsAll(right);
