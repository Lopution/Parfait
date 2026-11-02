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

/// Builds the formats Material and Cupertino widgets use, exactly as
/// Flutter's own localization delegates build them.
const _frameworkFormats = 'lib/l10n/app_localizations_delegates.dart';

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
final _brandPrimary = RegExp(r'\bFuncTokens\.(primary|lightAccent)\b');
final _labelMeasure = RegExp(r'\bLabelFit\.(group|measureLabel)\(');
final _identifier = RegExp(r'^[A-Za-z_]\w*$');

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

/// The top-level arguments of the call whose `(` is at [open] in [src].
List<String> _arguments(String src, int open) {
  final args = <String>[];
  var depth = 0;
  var start = open + 1;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
      if (depth == 0) {
        args.add(src.substring(start, i).trim());
        break;
      }
    } else if (c == ',' && depth == 1) {
      args.add(src.substring(start, i).trim());
      start = i + 1;
    }
  }
  return [
    for (final a in args)
      if (a.isNotEmpty) a,
  ];
}

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
    expect(
      mentions,
      isEmpty,
      reason: 'THEME-02 Montserrat is gone — use the platform font:\n$mentions',
    );
  });

  test('user-facing dates go through AppFormat', () {
    final allowed = {_appFormat, _frameworkFormats, ..._dataDateFormats};
    final violations = [
      ..._hits(sources, _dateFormat, allowed: allowed),
      ..._hits(sources, _dateInterpolation, allowed: allowed),
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'LAYOUT-06 format dates with AppFormat.date/relative; data '
          'formats go in '
          '_dataDateFormats with a reason:\n${violations.join('\n')}',
    );
  });

  test('counts go through AppFormat', () {
    final violations = _hits(
      sources,
      _numberFormat,
      allowed: {_appFormat, _frameworkFormats},
    );
    expect(
      violations,
      isEmpty,
      reason:
          'LAYOUT-06 format counts with AppFormat.count:\n'
          '${violations.join('\n')}',
    );
  });

  test('the accent comes from the theme, not the brand constant', () {
    final violations = _hits(sources, _brandPrimary, allowed: _primaryOwners);
    expect(
      violations,
      isEmpty,
      reason:
          'THEME-04 read Theme.of(context).colorScheme.primary so system '
          'colors '
          'apply:\n${violations.join('\n')}',
    );
  });

  test('fitted labels are measured in the style and locale they paint in', () {
    final violations = [
      for (final MapEntry(key: file, value: src) in sources.entries)
        if (file != 'lib/app/widgets/fit_label.dart')
          for (final m in _labelMeasure.allMatches(src))
            if (!_measuredAsPainted(src, m))
              '  $file:${src.substring(0, m.start).split('\n').length}',
    ];
    expect(
      violations,
      isEmpty,
      reason:
          'LAYOUT-04 measure with LabelFit.paintedStyle and the painted '
          'locale (Localizations.maybeLocaleOf):\n${violations.join('\n')}',
    );
  });
}

/// Whether the [call] to `LabelFit.group` or `LabelFit.measureLabel` in
/// [src] passes a locale, and a style that is `LabelFit.paintedStyle(...)`
/// or a local in a file that builds its styles with it.
bool _measuredAsPainted(String src, Match call) {
  final args = _arguments(src, call.end - 1);
  if (!args.any((a) => a.startsWith('locale:'))) return false;
  final style = call[1] == 'group'
      ? args.firstWhere((a) => a.startsWith('style:')).substring(6).trim()
      : args[1];
  return style.startsWith('LabelFit.paintedStyle(') ||
      (_identifier.hasMatch(style) && src.contains('LabelFit.paintedStyle('));
}
