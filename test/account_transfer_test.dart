import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_transfer.dart';
import 'package:pixiv_func/core/auth/credential.dart';

Account _account() => const Account(
  id: '42',
  userId: 42,
  name: 'server name must not be trusted from clipboard',
  mailAddress: 'not-in-transfer@example.invalid',
);

Credential _credential() => const Credential(
  accessToken: 'access-token-for-test-only',
  refreshToken: 'refresh-token-for-test-only',
  cookie: 'cookie-for-test-only',
);

String _encoded(Map<String, dynamic> value) =>
    base64Encode(utf8.encode(jsonEncode(value)));

Map<String, dynamic> _decoded(TransferEnvelope envelope) =>
    jsonDecode(utf8.decode(base64Decode(envelope.encode())))
        as Map<String, dynamic>;

TransferEnvelope _envelope() =>
    TransferEnvelope.create(account: _account(), credential: _credential());

Matcher _corrupt() => throwsA(
  isA<AccountTransferException>().having(
    (error) => error.code,
    'code',
    AccountTransferErrorCode.corrupt,
  ),
);

void main() {
  test('round-trips a versioned envelope', () {
    final parsed = TransferEnvelope.parse(_envelope().encode());

    expect(parsed.version, TransferEnvelope.currentVersion);
    expect(parsed.payload.accountId, '42');
    expect(parsed.payload.userId, 42);
    expect(parsed.payload.credential.accessToken, _credential().accessToken);
    expect(parsed.payload.credential.refreshToken, _credential().refreshToken);
    expect(parsed.payload.credential.cookie, _credential().cookie);
  });

  test('an envelope without a cookie round-trips', () {
    final envelope = TransferEnvelope.create(
      account: _account(),
      credential: const Credential(accessToken: 'a', refreshToken: 'r'),
    );

    final parsed = TransferEnvelope.parse(envelope.encode());

    expect(parsed.payload.credential.cookie, isNull);
  });

  test('rejects text that is not an envelope at all', () {
    expect(() => TransferEnvelope.parse('not base64'), _corrupt());
    expect(() => TransferEnvelope.parse(''), _corrupt());
    expect(
      () => TransferEnvelope.parse('A' * (TransferEnvelope.maxEncodedLength + 1)),
      _corrupt(),
    );
    expect(
      () => TransferEnvelope.parse(base64Encode(utf8.encode('[1,2,3]'))),
      _corrupt(),
    );
  });

  test('rejects a truncated paste through the checksum', () {
    final encoded = _envelope().encode();

    expect(
      () => TransferEnvelope.parse(encoded.substring(0, encoded.length - 8)),
      _corrupt(),
    );
  });

  test('rejects a payload edited without recomputing the checksum', () {
    final value = _decoded(_envelope());
    (value['payload'] as Map<String, dynamic>)['accountId'] = '43';

    expect(() => TransferEnvelope.parse(_encoded(value)), _corrupt());
  });

  test('rejects an envelope missing required payload fields', () {
    final value = _decoded(_envelope());
    (value['payload'] as Map<String, dynamic>).remove('userId');

    expect(() => TransferEnvelope.parse(_encoded(value)), _corrupt());
  });

  test('rejects an unknown envelope version', () {
    final value = _decoded(_envelope());
    value['version'] = TransferEnvelope.currentVersion + 1;

    expect(() => TransferEnvelope.parse(_encoded(value)), _corrupt());
  });

  test('the checksum is not authentication', () {
    // Anyone who can write the clipboard can also recompute the checksum. The
    // real boundary is the server-side verifier, not this parser; the checksum
    // only catches a truncated or hand-edited paste.
    final value = _decoded(_envelope());
    final payload = value['payload'] as Map<String, dynamic>;
    payload['accountId'] = '43';
    payload['userId'] = 43;
    final unsigned = Map<String, dynamic>.from(value)..remove('checksum');
    value['checksum'] = sha256
        .convert(utf8.encode(jsonEncode(unsigned)))
        .toString();

    expect(TransferEnvelope.parse(_encoded(value)).payload.accountId, '43');
  });

  test(
    'does not expose credentials through transfer object stringification',
    () {
      final value = _envelope().toString();

      expect(value, contains('TransferEnvelope'));
      expect(value, isNot(contains(_credential().accessToken)));
      expect(value, isNot(contains(_credential().refreshToken)));
      expect(value, isNot(contains(_credential().cookie!)));
    },
  );
}
