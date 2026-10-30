import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/settings/preference_keys.dart';
import 'package:parfait/core/updater/update_auto_check.dart';
import 'package:parfait/core/updater/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'helpers/test_preferences.dart';
import 'helpers/updater_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test(
    'first call checks once; a repeat inside the window is skipped',
    () async {
      final transport = _CountingTransport();
      final service = UpdateService(
        platform: FakeUpdatePlatform(capability: UpdateCapability.github()),
        manifestTransport: transport,
        signatureVerifier: FakeUpdateSignatureVerifier(),
      );
      var now = DateTime(2026, 9, 19, 12);
      final autoCheck = UpdateAutoCheck(
        preferences: SharedPreferencesAsync(),
        service: () async => service,
        clock: () => now,
      );

      final first = await autoCheck.checkOnce();
      expect(first, isNotNull);
      expect(first!.status, UpdateCheckStatus.noUpdate);
      expect(transport.fetches, 1);

      final second = await autoCheck.checkOnce();
      expect(second, isNull);
      expect(transport.fetches, 1);

      // Past the window the next call checks again.
      now = now.add(const Duration(hours: 25));
      final third = await autoCheck.checkOnce();
      expect(third, isNotNull);
      expect(transport.fetches, 2);
    },
  );

  test('store-managed capability skips the check entirely', () async {
    final transport = _CountingTransport();
    final service = UpdateService(
      platform: FakeUpdatePlatform(capability: UpdateCapability.fdroid()),
      manifestTransport: transport,
      signatureVerifier: FakeUpdateSignatureVerifier(),
    );
    final result = await UpdateAutoCheck(
      preferences: SharedPreferencesAsync(),
      service: () async => service,
    ).checkOnce();

    expect(result, isNull);
    expect(transport.fetches, 0);
  });

  test('a check that fails before its request stays silent', () async {
    // A full disk fails the throttle stamp.
    SharedPreferencesAsyncPlatform.instance = IntWriteFailingPreferences();
    final stampFails = UpdateAutoCheck(
      preferences: SharedPreferencesAsync(),
      service: () async => throw StateError('unreachable'),
    );
    expect(await stampFails.checkOnce(), isNull);

    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final lookupFails = UpdateAutoCheck(
      preferences: SharedPreferencesAsync(),
      service: () async => throw StateError('no service'),
    );
    expect(await lookupFails.checkOnce(), isNull);
    expect(
      await SharedPreferencesAsync().getInt(PreferenceKeys.updateAutoCheckAt),
      isNull,
      reason: 'no request went out: the next launch tries again',
    );
  });
}

class _CountingTransport implements UpdateManifestTransport {
  int fetches = 0;

  @override
  Future<UpdateHttpResponse> fetch(Uri uri) async {
    fetches += 1;
    return UpdateHttpResponse(statusCode: 404, body: const []);
  }
}
