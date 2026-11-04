import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/auth/credential_store.dart';

void main() {
  test('a corrupt credential fails without quoting the stored secret', () {
    FlutterSecureStorage.setMockInitialValues({
      'replica.credentials.v1.7': '{"v":1,"accessToken":"tok-secret',
    });

    expect(
      SecureCredentialStore().read('7'),
      throwsA(
        isA<CredentialStoreException>()
            .having((e) => e.operation, 'operation', 'read')
            .having((e) => '$e', 'text', isNot(contains('tok-secret'))),
      ),
    );
  });
}
