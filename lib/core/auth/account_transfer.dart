import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'account.dart';
import 'credential.dart';

/// Publicly observable outcomes of the account-transfer boundary.
enum AccountTransferErrorCode {
  corrupt,
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

/// Versioned account-transfer envelope.
///
/// This is a transparent transport format: it carries the credential in the
/// clear and offers no authenticity or confidentiality. The SHA-256 field only
/// detects a truncated or edited paste. Anything that arrives here is proven
/// or rejected by the server-side verifier, never by this parser.
class TransferEnvelope {
  TransferEnvelope._({
    required this.version,
    required this.payloadType,
    required this.payload,
  }) : checksum = _checksumFor(
         _unsignedJson(
           version: version,
           payloadType: payloadType,
           payload: payload,
         ),
       );

  static const int currentVersion = 2;
  static const String currentPayloadType = 'pixiv-account-transfer';
  static const int maxEncodedLength = 32 * 1024;

  final int version;
  final String payloadType;
  final TransferAccountPayload payload;
  final String checksum;

  factory TransferEnvelope.create({
    required Account account,
    required Credential credential,
  }) {
    return TransferEnvelope._(
      version: currentVersion,
      payloadType: currentPayloadType,
      payload: TransferAccountPayload(
        accountId: account.id,
        userId: account.userId,
        credential: credential,
      ),
    );
  }

  /// Parses the base64 representation copied to the clipboard. Every failure
  /// is the same user-visible outcome: this text is not a usable transfer.
  factory TransferEnvelope.parse(String encoded) {
    if (encoded.isEmpty || encoded.length > maxEncodedLength) throw _corrupt();

    final Map<String, Object?> root;
    try {
      root = jsonDecode(utf8.decode(base64Decode(encoded))) as Map<String, Object?>;
    } on Object catch (error) {
      throw AccountTransferException(
        AccountTransferErrorCode.corrupt,
        'clipboard data is not a transfer envelope',
        cause: error,
      );
    }

    if (root['version'] != currentVersion ||
        root['payloadType'] != currentPayloadType) {
      throw _corrupt();
    }

    final payloadMap = root['payload'];
    final credentialMap = payloadMap is Map ? payloadMap['credential'] : null;
    if (payloadMap is! Map || credentialMap is! Map) throw _corrupt();

    final accountId = payloadMap['accountId'];
    final userId = payloadMap['userId'];
    final accessToken = credentialMap['accessToken'];
    final refreshToken = credentialMap['refreshToken'];
    final cookie = credentialMap['cookie'];
    if (accountId is! String ||
        userId is! int ||
        accessToken is! String ||
        refreshToken is! String ||
        (cookie != null && cookie is! String) ||
        accountId.isEmpty ||
        accessToken.isEmpty ||
        refreshToken.isEmpty) {
      throw _corrupt();
    }

    final envelope = TransferEnvelope._(
      version: currentVersion,
      payloadType: currentPayloadType,
      payload: TransferAccountPayload(
        accountId: accountId,
        userId: userId,
        credential: Credential(
          accessToken: accessToken,
          refreshToken: refreshToken,
          cookie: cookie as String?,
        ),
      ),
    );
    // A half-copied or hand-edited paste would otherwise reach the network as
    // a credential that cannot possibly work.
    if (root['checksum'] != envelope.checksum) throw _corrupt();
    return envelope;
  }

  String encode() => base64Encode(utf8.encode(jsonEncode(toJson())));

  Map<String, Object?> toJson() => {
    ..._unsignedJson(
      version: version,
      payloadType: payloadType,
      payload: payload,
    ),
    'checksum': checksum,
  };

  @override
  String toString() =>
      'TransferEnvelope(version: $version, type: $payloadType)';

  static Map<String, Object?> _unsignedJson({
    required int version,
    required String payloadType,
    required TransferAccountPayload payload,
  }) => {
    'version': version,
    'payloadType': payloadType,
    'payload': payload.toJson(),
  };

  static String _checksumFor(Map<String, Object?> value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static AccountTransferException _corrupt() => const AccountTransferException(
    AccountTransferErrorCode.corrupt,
    'clipboard data is not a transfer envelope',
  );
}
