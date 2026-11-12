import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/theme/system_colors.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a platform without a dynamic colour plugin has no system colours',
    () async {
      // The test host has no dynamic_color plugin registered, the same state
      // as iOS: the channel throws MissingPluginException and the provider
      // must read it as "no palette" rather than an error.
      final container = ProviderContainer.test();
      expect(await container.read(systemColorSchemesProvider.future), isNull);
    },
  );
}
