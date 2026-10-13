import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_repository.dart';

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
