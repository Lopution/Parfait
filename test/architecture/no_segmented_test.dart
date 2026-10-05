// The app has no pill-shaped segmented buttons (D3): peer views use tabs,
// settings use SettingsMenuTile, two-way properties use a switch, choices
// of action use buttons and list filters use FilterMenuButton.
// Asserted on lib/ (repo-relative paths).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The segmented family: the framework control and its theme entry, plus
/// the removed wrappers — the app button, the type switch built on it and
/// the profile work-type row (now tabs) — so none comes back.
final _segmented = RegExp(
  r'(?<![A-Za-z])(?:SegmentedButton|AppSegmentedButton|AppSegment|'
  r'AppTypeSwitch|SliverAppTypeSwitch|ProfileWorkTypeSwitch|'
  r'segmentedButtonTheme)(?![A-Za-z])',
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
