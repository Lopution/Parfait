import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/settings/settings_repository.dart';

/// Settings that load as the defaults with the local filter switches given.
Override filterSettings({bool blockR18 = false, bool hideMuted = false}) =>
    settingsRepositoryProvider.overrideWithValue(
      FakeSettingsRepository(
        AppSettings.defaults().copyWith(
          enableLocalBlockR18: blockR18,
          hideMuted: hideMuted,
        ),
      ),
    );

/// In-memory settings persistence: [value] is what `load` returns and the
/// last saved settings; [saved] records every save.
class FakeSettingsRepository implements SettingsRepository {
  FakeSettingsRepository(this.value, {this.failLoad = false});

  AppSettings value;
  bool failLoad;
  bool failWrites = false;
  final saved = <AppSettings>[];
  Duration writeDelay = Duration.zero;

  @override
  Future<AppSettings> load() async {
    if (failLoad) throw StateError('settings unavailable');
    return value;
  }

  @override
  Future<void> save(AppSettings settings) async {
    if (writeDelay != Duration.zero) await Future<void>.delayed(writeDelay);
    if (failWrites) throw StateError('settings disk full');
    value = settings;
    saved.add(settings);
  }
}
