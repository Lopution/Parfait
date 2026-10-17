// THEME-16: icons are outlined; the filled twin of an outlined icon marks
// a state. THEME-17: every IconButton names its action in a tooltip.
//
// Heuristic scans over lib/ with comments stripped, like the motion
// census: a call's arguments are read by matching brackets.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _comment = RegExp(r'//[^\n]*|/\*.*?\*/', dotAll: true);
final _icon = RegExp(r'Icons\.([a-z0-9_]+)');
final _iconButton = RegExp(
  r'(?<![\w.])IconButton(?:\.(?:filled|filledTonal|outlined))?\(',
);

/// Filled icons whose outlined twin the app also uses, per file: each
/// marks a state.
const _filledStates = <String, Set<String>>{
  // A task's or a group's status.
  'lib/features/settings/pages/download_task_presentation.dart': {
    'block',
    'downloading',
  },
  // A tag chip's muted mark.
  'lib/app/widgets/tag_chips.dart': {'block'},
  // Card actions that are on: the work or its author muted.
  'lib/app/widgets/card_actions/illust_card_actions.dart': {
    'person_off',
    'visibility_off',
  },
};

/// Icon buttons without a tooltip, per file.
const _untitledButtons = <String, int>{
  // The heart labels itself through Semantics: a tooltip would take the
  // long press that opens the tag picker.
  'lib/app/widgets/bookmark_switch_button.dart': 1,
};

Map<String, String> _sources() => {
  for (final file in Directory('lib').listSync(recursive: true))
    if (file is File && file.path.endsWith('.dart'))
      file.path: file.readAsStringSync().replaceAll(_comment, ''),
};

/// The argument text of the call opened at [start], without what its
/// nested brackets hold.
String _topLevelArguments(String src, int start) {
  final out = StringBuffer();
  var depth = 0;
  for (var i = start; i < src.length; i++) {
    final char = src[i];
    if (')]}'.contains(char)) {
      if (depth == 0) break;
      depth--;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (depth == 0) {
      out.write(char);
    }
  }
  return out.toString();
}

void main() {
  test('a filled icon with an outlined twin marks a state', () {
    final sources = _sources();
    final used = {
      for (final src in sources.values)
        for (final match in _icon.allMatches(src)) match[1]!,
    };
    final filled = <String, Set<String>>{};
    sources.forEach((file, src) {
      for (final match in _icon.allMatches(src)) {
        final name = match[1]!;
        if (used.contains('${name}_outlined')) {
          (filled[file] ??= {}).add(name);
        }
      }
    });
    expect(
      filled,
      _filledStates,
      reason:
          'THEME-16 an action uses the outlined icon — the filled one '
          'marks a state; pin a new state here with what it marks',
    );
  });

  test('every icon button has a tooltip', () {
    final untitled = <String, int>{};
    _sources().forEach((file, src) {
      for (final match in _iconButton.allMatches(src)) {
        if (!_topLevelArguments(src, match.end).contains('tooltip:')) {
          untitled[file] = (untitled[file] ?? 0) + 1;
        }
      }
    });
    expect(
      untitled,
      _untitledButtons,
      reason:
          'THEME-17 an icon button names its action in a localized '
          'tooltip; pin one that labels itself through Semantics',
    );
  });
}
