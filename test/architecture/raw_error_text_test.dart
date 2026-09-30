// Raw error text must never reach a user-facing surface (C8/D1, design
// §2.5). Error surfaces show a localized category or action sentence; the
// original exception stays behind ErrorDetails or in CrashLog.
//
// Heuristic scan, not a proof: a violation is a line — or a short
// multi-line expression — that combines a user-facing text entry
// (`Text(`, `SelectableText(`, `showAppSnackBar(`, `subtitle:`, `detail:`,
// `title:`, an l10n lookup) with a raw-error interpolation or toString
// (`$error`, `${error`, `$_error`, `$e`, `$err`, `$next`, `$exception`,
// `error.toString()`, `e.toString()`, `error.runtimeType.toString()`).
// False positives are fixed by rephrasing the code or allow-listing the
// file with a reason; the intent is to block regressions of the §2.4
// migration.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// User-facing text entry points. An l10n lookup counts because the old
/// violations all went through `l10n.someKey(raw)`.
final _textEntry = RegExp(
  r'\bText\('
  r'|\bSelectableText\('
  r'|\bshowAppSnackBar\('
  r'|\bsubtitle\s*:'
  r'|\bdetail\s*:'
  r'|\btitle\s*:'
  r'|\bl10n\.\w+',
);

/// Raw error value interpolated into a string, or stringified inline.
/// The interpolation branch keys on error-named identifiers — `$error`,
/// `${error}`, `$_error`, `$_submitError`, `$err`, `$exception`,
/// `$nextError` — plus the whole-word `$e` and `$next` (the store-listener
/// name). The second branch catches `*.toString()` on the same names so
/// `error.toString()` / `error.runtimeType.toString()` inline in a text
/// call counts too.
final _rawError = RegExp(
  r'\$\{?_*\w*(?:error|Error|err|Err|exception|Exception)\b'
  r'|\$\{?_?(?:e|next)\b'
  r'|\b_?\w*(?:error|Error|err|Err|exception|Exception|next)\w*\b(?:\.\w+)*\.toString\(\)'
  r'|\be\.toString\(\)',
);

/// Files whose raw-error text is intentional:
/// - the network diagnostics page prints probe output verbatim;
/// - ErrorDetails is the disclosure widget that legitimately renders
///   `error.toString()`.
const _allowList = <String>{
  'lib/features/settings/network_probe_page.dart',
  'lib/app/widgets/errors/error_details.dart',
};

/// How far a text-entry line and a raw-error line may sit apart inside one
/// expression and still count as a violation (multi-line calls/strings).
const _adjacentLines = 3;

void main() {
  test('no raw error text reaches user-facing surfaces', () {
    final violations = <String>[];
    for (final root in ['lib/app', 'lib/features']) {
      for (final entity in Directory(
        root,
      ).listSync(recursive: true).whereType<File>()) {
        final file = entity.path;
        if (!file.endsWith('.dart') || _allowList.contains(file)) continue;
        final lines = File(file).readAsLinesSync();
        final textLines = <int>[
          for (var i = 0; i < lines.length; i++)
            if (_textEntry.hasMatch(lines[i])) i,
        ];
        final rawLines = <int>[
          for (var i = 0; i < lines.length; i++)
            if (_rawError.hasMatch(lines[i])) i,
        ];
        if (textLines.isEmpty || rawLines.isEmpty) continue;
        for (final t in textLines) {
          final hit = rawLines.where((e) => (e - t).abs() <= _adjacentLines);
          if (hit.isNotEmpty) {
            violations.add(
              '$file:${t + 1} (raw error near line ${hit.first + 1})',
            );
          }
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'raw error values near user-facing text — show a localized '
          'category via errorCategoryText/showErrorSnackBar and keep the '
          'original behind ErrorDetails or CrashLog:\n'
          '${violations.join('\n')}',
    );
  });
}
