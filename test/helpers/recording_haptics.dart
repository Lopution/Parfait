import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/haptics/app_haptics.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/core/settings/app_settings.dart';

/// Records what [AppHaptics] hands to the platform boundary.
class RecordingHapticsDriver implements HapticsDriver {
  RecordingHapticsDriver({this.capabilityResult = HapticsCapability.none});

  final played = <(HapticRole, HapticStrength)>[];
  HapticsCapability capabilityResult;
  Object? capabilityError;

  List<HapticRole> get roles => [for (final p in played) p.$1];

  @override
  void play(HapticRole role, HapticStrength strength) =>
      played.add((role, strength));

  @override
  Future<HapticsCapability> capability() async {
    final error = capabilityError;
    if (error != null) throw error;
    return capabilityResult;
  }
}

/// Configures [AppHaptics] with a recording driver for one test and resets
/// it afterwards.
RecordingHapticsDriver recordHaptics({
  HapticStrength strength = HapticStrength.standard,
}) {
  final driver = RecordingHapticsDriver();
  AppHaptics.debugReset();
  AppHaptics.configure(strength: () => strength, driver: driver);
  addTearDown(AppHaptics.debugReset);
  return driver;
}
