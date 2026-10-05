// Fonts, dates, counts and the theme color each have one owner (U1 design
// §7): the platform font (no bundled family), AppFormat for user-facing dates
// and counts, and the theme's colorScheme for the accent.
//
// Heuristic scan, not a proof. Comments are stripped before scanning. A raw
// integer interpolated into text cannot be told apart from a count
// statically; the call-site widget tests and the spec review checklist cover
// that case.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _appFormat = 'lib/app/format/app_format.dart';

/// Files that build dates for data, never for display. Each entry carries
/// its reason.
const _dataDateFormats = <String>{
  // Route query parameters (`yyyy-MM-dd`) must round-trip exactly.
  'lib/app/navigation/routes.dart',
  // Download file names follow the user's naming template.
  'lib/core/download/naming_rule.dart',
  // The backup file name is a sortable timestamp, not prose.
  'lib/core/backup/backup_envelope.dart',
};

/// Files allowed to name the brand pink directly: its definition and the
/// theme that seeds the color scheme from it.
const _primaryOwners = <String>{
  'lib/app/theme/func_tokens.dart',
  'lib/app/theme/replica_theme.dart',
};

final _comment = RegExp(r'//[^\n]*|/\*.*?\*/', dotAll: true);
final _dateFormat = RegExp(r'\bDateFormat\b');
final _dateInterpolation = RegExp(r'\$\{[^}]*\.(?:year|month|day)\}');
final _numberFormat = RegExp(r'\bNumberFormat\b');
final _brandPrimary = RegExp(r'\bFuncTokens\.primary\b');

/// Every Dart source under lib/ with its comments stripped.
Map<String, String> _sources() => {
  for (final file in Directory(
    'lib',
  ).listSync(recursive: true).whereType<File>())
    if (file.path.endsWith('.dart'))
      file.path: file.readAsStringSync().replaceAll(_comment, ''),
};

/// `file:line` for every match of [pattern] in files not in [allowed].
List<String> _hits(
  Map<String, String> sources,
  RegExp pattern, {
  Set<String> allowed = const {},
}) => [
  for (final MapEntry(key: file, value: src) in sources.entries)
    if (!allowed.contains(file))
      for (final m in pattern.allMatches(src))
        '  $file:${src.substring(0, m.start).split('\n').length}',
];

void main() {
  final sources = _sources();

  test('no bundled Montserrat: text uses the platform font', () {
    final mentions = [
      for (final MapEntry(key: file, value: src) in {
        ...sources,
        'pubspec.yaml': File('pubspec.yaml').readAsStringSync(),
      }.entries)
        if (src.toLowerCase().contains('montserrat')) '  $file',
    ];
    expect(mentions, isEmpty, reason: 'Montserrat is gone:\n$mentions');
  });

  test('user-facing dates go through AppFormat', () {
    final allowed = {_appFormat, ..._dataDateFormats};
    final violations = [
      ..._hits(sources, _dateFormat, allowed: allowed),
      ..._hits(sources, _dateInterpolation, allowed: allowed),
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'format dates with AppFormat.date/relative; data formats go in '
          '_dataDateFormats with a reason:\n${violations.join('\n')}',
    );
  });

  test('counts go through AppFormat', () {
    final violations = _hits(sources, _numberFormat, allowed: {_appFormat});
    expect(
      violations,
      isEmpty,
      reason: 'format counts with AppFormat.count:\n${violations.join('\n')}',
    );
  });

  test('the accent comes from the theme, not the brand constant', () {
    final violations = _hits(sources, _brandPrimary, allowed: _primaryOwners);
    expect(
      violations,
      isEmpty,
      reason:
          'read Theme.of(context).colorScheme.primary so system colors '
          'apply:\n${violations.join('\n')}',
    );
  });
}
