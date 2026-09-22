import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixiv_func/core/network/compat/network_providers.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'helpers/test_preferences.dart';

void main() {
  // Regression: the auto winner flip used to rebuild pixivNetworkFactory-
  // Provider, whose dispose() also disposed the *shared* NetworkAccessPolicy
  // owned by networkAccessPolicyProvider — every later request then threw
  // 'network policy is disposed' (auto mode killed the whole network stack
  // seconds after the first race completed).
  test(
    'auto winner flip keeps factory stable and shared policy alive',
    () async {
      installMemoryPreferences();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final policy = container.read(networkAccessPolicyProvider);
      final f1 = container.read(pixivNetworkFactoryProvider);
      container.read(autoImageSourceWinnerProvider.notifier).set('i.pixiv.re');
      final f2 = container.read(pixivNetworkFactoryProvider);
      expect(
        identical(f1, f2),
        isTrue,
        reason: 'winner flips must not rebuild the factory/image cache',
      );
      // Let any async dispose chain drain, then the shared policy must still
      // hand out clients. Headless runs reach the rhttp bridge before a real
      // client exists — any failure other than 'disposed' proves liveness.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        policy.clientFor(
          PixivDestinationPurpose.image,
          NetworkRoute.direct(policy.revision),
          'i.pixiv.re',
        );
      } on StateError catch (e) {
        expect(e.message, isNot(contains('disposed')));
      }
    },
  );

  test('mirror rewrite applies the winner lazily per request', () async {
    installMemoryPreferences();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final factory = container.read(pixivNetworkFactoryProvider);
    container.read(autoImageSourceWinnerProvider.notifier).set('i.pixiv.re');
    // Default source is auto → mirror rewrites i.pximg.net to the winner.
    final rewritten = factory.imageUrlRewriter!(
      Uri.parse('https://i.pximg.net/img-original/img/1_p0.jpg'),
    );
    expect(rewritten.host, 'i.pixiv.re');
  });
}
