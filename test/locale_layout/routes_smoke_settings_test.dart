import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

import '../helpers/route_smoke.dart';

void main() {
  // LicensePage's narrow layout makes a master route, with its restoration
  // scope notifier, on every build and hands only the first to its
  // Navigator (material_ui 1.8 still does).
  LeakTesting.settings = LeakTesting.settings.withIgnored(
    notDisposed: {
      'MaterialPageRoute<dynamic>': null,
      'ValueNotifier<String?>': null,
    },
  );
  smokeMatrix(SmokeGroup.settings);
}
