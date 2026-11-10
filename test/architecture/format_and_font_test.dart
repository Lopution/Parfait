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
final _brandPrimary = RegExp(
  r'\bFuncTokens\.(primary|lightAccent|darkAccent|'
  r'(light|dark)(On)?PrimaryContainer|(light|dark)InversePrimary)\b',
);
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

/// [src] with its comments and the text of its string literals blanked to
/// spaces, read in one pass so that a `//` in a string is not a comment
/// and a quote in a comment opens no string; offsets and lines stay.
String _code(String src) {
  final out = StringBuffer();
  void blank(int from, int to) {
    for (var j = from; j < to; j++) {
      out.write(src[j] == '\n' ? '\n' : ' ');
    }
  }

  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (src.startsWith('//', i)) {
      final end = src.indexOf('\n', i);
      final to = end < 0 ? src.length : end;
      blank(i, to);
      i = to;
    } else if (src.startsWith('/*', i)) {
      // Block comments nest.
      var to = i + 2;
      for (var depth = 1; depth > 0 && to < src.length;) {
        if (src.startsWith('/*', to)) {
          depth++;
          to += 2;
        } else if (src.startsWith('*/', to)) {
          depth--;
          to += 2;
        } else {
          to++;
        }
      }
      blank(i, to);
      i = to;
    } else if (c == "'" || c == '"') {
      final quote = src.startsWith(c * 3, i) ? c * 3 : c;
      final raw = i > 0 && src[i - 1] == 'r';
      var j = i + quote.length;
      while (j < src.length && !src.startsWith(quote, j)) {
        j += !raw && src[j] == r'\' ? 2 : 1;
      }
      final to = j < src.length ? j : src.length;
      out.write(quote);
      blank(i + quote.length, to);
      if (to < src.length) out.write(quote);
      i = to + (to < src.length ? quote.length : 0);
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// The lines in [src] of the `LabelFit.group` and `LabelFit.measureLabel`
/// calls not measured as painted ([_measuredAsPainted]).
List<int> _unpaintedFits(String src) {
  final code = _code(src);
  return [
    for (final m in _labelMeasure.allMatches(code))
      if (!_measuredAsPainted(code, m))
        code.substring(0, m.start).split('\n').length,
  ];
}

/// The top-level arguments of the call whose `(` is at [open] in [src],
/// read with its strings and comments blanked ([_code]).
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

  test('the fitted-label scan follows bindings and skips strings', () {
    bool passes(String body) => _unpaintedFits('void f() {\n$body\n}').isEmpty;

    const locale = 'final locale = Localizations.maybeLocaleOf(context);';
    const painted = 'final s = LabelFit.paintedStyle(context, base);';
    expect(
      passes(
        '$locale\n$painted\n'
        "LabelFit.measureLabel('a,(b', s, t, d, locale: locale);",
      ),
      isTrue,
    );
    // Another paintedStyle in the file does not vouch for a raw local.
    expect(
      passes(
        '$locale\n$painted\nfinal raw = base;\n'
        "LabelFit.measureLabel('a', raw, t, d, locale: locale);",
      ),
      isFalse,
    );
    expect(
      passes("$painted\nLabelFit.measureLabel('a', s, t, d, locale: null);"),
      isFalse,
    );
    // A member assignment does not rebind the local.
    expect(
      passes(
        '$locale\nfinal s = base;\n'
        'holder.s = LabelFit.paintedStyle(context, base);\n'
        "LabelFit.measureLabel('a', s, t, d, locale: locale);",
      ),
      isFalse,
    );
    // A call spelled in a string is text, not a call; a `//` in a string
    // starts no comment that would hide the code after it.
    expect(passes("final note = 'LabelFit.group(';\n"), isTrue);
    expect(passes('/* a /* nested */ LabelFit.group( */\n'), isTrue);
    expect(
      passes(
        "$locale\nfinal url = 'https://example.test';\nfinal raw = base;\n"
        "LabelFit.measureLabel('a', raw, t, d, locale: locale);",
      ),
      isFalse,
    );
  });

  test('fitted labels are measured in the style and locale they paint in', () {
    final violations = [
      for (final file in sources.keys)
        if (file != 'lib/app/widgets/fit_label.dart')
          for (final line in _unpaintedFits(File(file).readAsStringSync()))
            '  $file:$line',
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
/// [src] passes the painted locale and a style built by
/// `LabelFit.paintedStyle`, directly or through a local bound to it.
bool _measuredAsPainted(String src, Match call) {
  final args = _arguments(src, call.end - 1);
  String? named(String name) => [
    for (final a in args)
      if (a.startsWith('$name:')) a.substring(name.length + 1).trim(),
  ].firstOrNull;
  final locale = named('locale');
  final style = call[1] == 'group' ? named('style') : args.elementAtOrNull(1);
  return locale != null &&
      style != null &&
      _traces(src, locale, call.start, 'Localizations.maybeLocaleOf(') &&
      _traces(src, style, call.start, 'LabelFit.paintedStyle(');
}

/// Whether [expr], read at [at] in [src], is a call to [source], or a
/// local bound to one before [at]: by `name = ...` (not `x.name = ...`), or as the variable of
/// a `for (final name in ...)` over a collection whose every element is
/// one. Bounded to a few hops; a binding it cannot read is not traced.
bool _traces(String src, String expr, int at, String source, [int hops = 3]) {
  if (expr.startsWith(source)) return true;
  if (hops == 0) return false;
  if (expr.startsWith('{') || expr.startsWith('[')) {
    final elements = _arguments(expr, 0);
    return elements.isNotEmpty &&
        elements.every(
          (e) => _traces(src, _withoutClauses(e), at, source, hops - 1),
        );
  }
  if (!_identifier.hasMatch(expr)) return false;
  final binding = RegExp(
    '(?:(?<![\\w.])$expr\\s*=(?!=)|\\bfor\\s*\\(\\s*final\\s+$expr\\s+in\\b)\\s*',
  ).allMatches(src.substring(0, at)).lastOrNull;
  if (binding == null) return false;
  final value = src.substring(binding.end, _expressionEnd(src, binding.end));
  return _traces(src, value.trim(), binding.start, source, hops - 1);
}

final _clause = RegExp(r'^(?:for|if)\s*\(');

/// [element] past its leading collection-for and collection-if clauses.
String _withoutClauses(String element) {
  var e = element;
  for (
    var clause = _clause.firstMatch(e);
    clause != null;
    clause = _clause.firstMatch(e)
  ) {
    e = e.substring(_expressionEnd(e, clause.end) + 1).trim();
  }
  return e;
}

/// Where the expression starting at [from] in [src] ends: the first `;`,
/// `,` or unbalanced closing bracket outside brackets.
int _expressionEnd(String src, int from) {
  var depth = 0;
  for (var i = from; i < src.length; i++) {
    final c = src[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      if (depth == 0) return i;
      depth--;
    } else if (';,'.contains(c) && depth == 0) {
      return i;
    }
  }
  return src.length;
}
