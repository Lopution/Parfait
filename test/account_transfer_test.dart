import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_transfer.dart';
import 'package:pixiv_func/core/auth/credential.dart';

final _createdAt = DateTime.utc(2026, 8, 28, 1);
const _nonce = 'AAECAwQFBgcICQoLDA0ODw';

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

TransferEnvelope _envelope({Duration ttl = const Duration(minutes: 5)}) =>
    TransferEnvelope.create(
      account: _account(),
      credential: _credential(),
      now: _createdAt,
      ttl: ttl,
      nonce: _nonce,
    );

void main() {
  test('round-trips a bounded versioned envelope', () {
    final original = _envelope();

    final parsed = TransferEnvelope.parse(
      original.encode(),
      now: _createdAt.add(const Duration(seconds: 1)),
    );

    expect(parsed.version, TransferEnvelope.currentVersion);
    expect(parsed.payload.accountId, '42');
    expect(parsed.payload.userId, 42);
    expect(parsed.payload.credential.accessToken, _credential().accessToken);
    expect(parsed.payload.credential.refreshToken, _credential().refreshToken);
    expect(parsed.payload.credential.cookie, _credential().cookie);
    expect(parsed.nonce, _nonce);
    expect(parsed.expiresAt, _createdAt.add(const Duration(minutes: 5)));
  });

  test('rejects malformed base64 and oversized input as corrupt', () {
    expect(
      () => TransferEnvelope.parse('not base64'),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.corrupt,
        ),
      ),
    );
    expect(
      () =>
          TransferEnvelope.parse('A' * (TransferEnvelope.maxEncodedLength + 1)),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.corrupt,
        ),
      ),
    );
    final encoded = _envelope().encode();
    expect(
      () => TransferEnvelope.parse(
        encoded.substring(0, encoded.length - 4),
        now: _createdAt,
      ),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.corrupt,
        ),
      ),
    );
  });

  test('rejects unknown fields before accepting a checksum', () {
    final value =
        jsonDecode(utf8.decode(base64Decode(_envelope().encode())))
            as Map<String, dynamic>;
    value['unexpected'] = true;

    expect(
      () => TransferEnvelope.parse(_encoded(value), now: _createdAt),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.corrupt,
        ),
      ),
    );
  });

  test('detects accidental payload tampering through the unkeyed checksum', () {
    final value =
        jsonDecode(utf8.decode(base64Decode(_envelope().encode())))
            as Map<String, dynamic>;
    final payload = value['payload'] as Map<String, dynamic>;
    payload['accountId'] = '43';

    expect(
      () => TransferEnvelope.parse(_encoded(value), now: _createdAt),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.corrupt,
        ),
      ),
    );
    // The checksum is deliberately unkeyed. An attacker who can rewrite the
    // clipboard can recompute it; this test only covers accidental damage,
    // not authenticity or confidentiality.
  });

  test(
    'documents that a malicious clipboard writer can recompute the checksum',
    () {
      final value =
          jsonDecode(utf8.decode(base64Decode(_envelope().encode())))
              as Map<String, dynamic>;
      final payload = value['payload'] as Map<String, dynamic>;
      payload['accountId'] = '43';
      payload['userId'] = 43;
      final unsigned = Map<String, dynamic>.from(value)..remove('checksum');
      value['checksum'] = sha256
          .convert(utf8.encode(jsonEncode(unsigned)))
          .toString();

      final parsed = TransferEnvelope.parse(_encoded(value), now: _createdAt);

      expect(parsed.payload.accountId, '43');
      // This is intentional: the checksum detects accidental corruption only;
      // it is not sender authentication and does not resist clipboard writers.
    },
  );

  test(
    'rejects an unknown envelope version even with otherwise valid fields',
    () {
      final value =
          jsonDecode(utf8.decode(base64Decode(_envelope().encode())))
              as Map<String, dynamic>;
      value['version'] = TransferEnvelope.currentVersion + 1;

      expect(
        () => TransferEnvelope.parse(_encoded(value), now: _createdAt),
        throwsA(
          isA<AccountTransferException>().having(
            (error) => error.code,
            'code',
            AccountTransferErrorCode.corrupt,
          ),
        ),
      );
    },
  );

  test('distinguishes expiry from malformed timestamps', () {
    expect(
      () => TransferEnvelope.parse(
        _envelope(ttl: const Duration(minutes: 1)).encode(),
        now: _createdAt.add(const Duration(minutes: 1)),
      ),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.expired,
        ),
      ),
    );

    final expiredTamper =
        jsonDecode(utf8.decode(base64Decode(_envelope().encode())))
            as Map<String, dynamic>;
    expiredTamper['createdAt'] = '2026-08-27T23:50:00.000Z';
    expiredTamper['expiresAt'] = '2026-08-27T23:55:00.000Z';
    expect(
      () => TransferEnvelope.parse(_encoded(expiredTamper), now: _createdAt),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.corrupt,
        ),
      ),
    );

    final value =
        jsonDecode(utf8.decode(base64Decode(_envelope().encode())))
            as Map<String, dynamic>;
    value['createdAt'] = '2026-08-28T01:00:00+08:00';
    expect(
      () => TransferEnvelope.parse(_encoded(value), now: _createdAt),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.corrupt,
        ),
      ),
    );
  });

  test('rejects a future-issued envelope outside the clock-skew window', () {
    expect(
      () => TransferEnvelope.parse(
        _envelope().encode(),
        now: _createdAt.subtract(const Duration(minutes: 3)),
      ),
      throwsA(
        isA<AccountTransferException>().having(
          (error) => error.code,
          'code',
          AccountTransferErrorCode.corrupt,
        ),
      ),
    );
  });

  test(
    'claims a nonce once and only keeps the digest in the replay store',
    () async {
      final store = InMemoryTransferReplayStore(now: () => _createdAt);
      final expiry = _createdAt.add(const Duration(minutes: 5));

      expect(await store.claim(_nonce, expiry), isTrue);
      expect(await store.claim(_nonce, expiry), isFalse);
      expect(store.debugEntries, hasLength(1));
      expect(
        store.debugEntries.single.keys,
        containsAll(<String>['digest', 'expiresAt']),
      );
      expect(store.debugEntries.single.keys, isNot(contains('nonce')));
    },
  );

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
