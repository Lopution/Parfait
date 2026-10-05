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

void main() {
  test('no segmented buttons', () {
    final hits = {
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            _segmented.hasMatch(entity.readAsStringSync()))
          entity.path,
    };
    expect(
      hits,
      isEmpty,
      reason: 'use tabs, SettingsMenuTile, a switch or buttons instead',
    );
  });
}
