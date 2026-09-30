// Spacing and corner-radius literals must go through the shared tokens
// (C8/D3, design §4). Padding and gaps resolve to FuncSpacing; component
// radii resolve to FuncShape. The token definitions themselves live in
// lib/app/theme/, which is out of scope.
//
// Heuristic scan, not a proof: a violation is an
// `EdgeInsets.(all|symmetric|only|fromLTRB)(` or `Radius.circular(` call
// whose argument span carries a numeric literal other than 0 (all-zero
// insets are written EdgeInsets.zero; a 0 slot inside a mixed inset is
// fine). Comments are stripped before scanning. False positives are fixed
// by rephrasing the code or allow-listing the file with a reason; the
// intent is to block regressions of the §4.1 migration.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _call = RegExp(
  r'(?<!\w)(?:EdgeInsets\.(?:all|symmetric|only|fromLTRB)|Radius\.circular)\(',
);
final _number = RegExp(r'(?<![\w.])(\d+\.?\d*)(?![\w.])');
final _comment = RegExp(r'//[^\n]*|/\*.*?\*/', dotAll: true);

/// Files whose remaining literals are intentional. Each entry is a file
/// path plus the number of tolerated call sites; the reason belongs in a
/// comment on that line's entry.
const _allowList = <String, int>{};

/// Scan the argument span of one call — from `(` to its match — for a
/// non-zero numeric literal.
bool _violates(String src, int openParen) {
  var depth = 1;
  var i = openParen;
  while (i < src.length && depth > 0) {
    final c = src[i];
    if (c == '(') depth++;
    if (c == ')') depth--;
    i++;
  }
  final args = src.substring(openParen, i - 1);
  return _number.allMatches(args).any((m) => double.parse(m[0]!) != 0);
}

void main() {
  test('spacing and radius literals use FuncSpacing/FuncShape', () {
    final violations = <String>[];
    for (final root in ['lib/app', 'lib/features']) {
      for (final entity in Directory(
        root,
      ).listSync(recursive: true).whereType<File>()) {
        final file = entity.path;
        if (!file.endsWith('.dart') || file.startsWith('lib/app/theme/')) {
          continue;
        }
        final src = File(file).readAsStringSync().replaceAll(_comment, '');
        var hits = 0;
        for (final m in _call.allMatches(src)) {
          if (_violates(src, m.end)) {
            hits++;
            final line = src.substring(0, m.start).split('\n').length;
            violations.add('  $file:$line');
          }
        }
        final allowed = _allowList[file] ?? 0;
        if (hits <= allowed) {
          violations.removeRange(violations.length - hits, violations.length);
        } else if (allowed > 0) {
          violations.add('  $file: $hits sites exceed allow-list $allowed');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'spacing/radius literals must resolve to FuncSpacing/FuncShape '
          '(design §4.1); file-specific exceptions go in _allowList with a '
          'reason:\n${violations.join('\n')}',
    );
  });
}
