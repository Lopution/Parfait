// The app has no pill-shaped segmented buttons (D3): peer views use tabs,
// settings use SettingsMenuTile, two-way properties use a switch and
// choices of action use buttons. Asserted on lib/ (repo-relative paths).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The segmented family: the framework control, the app wrapper and the
/// type switch built on it, and the theme entry that styles them.
final _segmented = RegExp(
  r'(?<![A-Za-z])(?:SegmentedButton|AppSegmentedButton|AppSegment|'
  r'AppTypeSwitch|SliverAppTypeSwitch|segmentedButtonTheme)(?![A-Za-z])',
);

/// The profile work-type row is the last user; it becomes tabs with the
/// profile rework, which deletes these files and empties this list.
const _remaining = <String>{
  'lib/app/widgets/app_segmented_button.dart',
  'lib/app/widgets/app_type_switch.dart',
  'lib/app/theme/replica_theme.dart',
  'lib/features/profile/profile_work_type_switch.dart',
  'lib/features/profile/user_page.dart',
};

void main() {
  test('no segmented buttons outside the profile work-type row', () {
    final hits = {
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            _segmented.hasMatch(entity.readAsStringSync()))
          entity.path,
    };
    expect(
      hits.difference(_remaining),
      isEmpty,
      reason: 'use tabs, SettingsMenuTile, a switch or buttons instead',
    );
    // A list that only shrinks: a file that dropped the control leaves it.
    expect(_remaining.difference(hits), isEmpty);
  });
}
