// Pins the settings-page ListTile census to the design §3.3 allow-list.
//
// Asserted on the source tree (all paths repo-relative):
//   - `ListTile(` under lib/features/settings: exactly the per-file counts
//     below — every remaining hand-written row is a data/status row, not a
//     settings row (diagnostic entries, muted items, the SAF current-folder
//     display, the account summary and account list). Adding a
//     hand-written row must update this map with a reason.
//   - `SettingsSection` anywhere under lib/: zero — the widget was removed;
//     groups are rendered by SettingsGroup.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Per-file count of hand-written `ListTile(` allowed under
/// lib/features/settings. Files absent from the map must contain none.
const _listTileAllowList = <String, int>{
  // Effective-routes and third-party-reachability diagnostic rows.
  'lib/features/settings/network_settings_page.dart': 2,
  // Muted tag/user/work entries: tap opens the content, trailing unmutes.
  'lib/features/settings/pages/muted_items_page.dart': 3,
  // The picked SAF folder: read-only display, long-press copies the URI.
  'lib/features/settings/pages/download_destination_page.dart': 1,
  // AccountSummaryTile's 58dp avatar headline row, and the account list
  // rows with avatar/switch-spinner/delete affordances.
  'lib/features/settings/pages/account_settings_page.dart': 2,
  // The app identity row leads with the launcher icon, not a glyph.
  'lib/features/settings/pages/about_settings_page.dart': 1,
};

/// Recursively yields `.dart` files under [dir] as repo-relative paths.
Iterable<String> _dartFiles(String dir) sync* {
  for (final entity in Directory(dir).listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity.path;
    }
  }
}

void main() {
  test('hand-written ListTile rows match the design whitelist', () {
    final counts = <String, int>{};
    for (final file in _dartFiles('lib/features/settings')) {
      final n = RegExp(
        r'ListTile\(',
      ).allMatches(File(file).readAsStringSync()).length;
      if (n > 0) counts[file] = n;
    }
    expect(
      counts,
      _listTileAllowList,
      reason:
          'hand-written ListTile( outside the whitelist — use the shared '
          'settings row components, or pin the new row here with a reason',
    );
  });

  test('SettingsSection is gone from lib/', () {
    final hits = <String>[];
    for (final file in _dartFiles('lib')) {
      if (File(file).readAsStringSync().contains('SettingsSection')) {
        hits.add(file);
      }
    }
    expect(
      hits,
      isEmpty,
      reason: 'SettingsSection was removed — use SettingsGroup',
    );
  });
}
