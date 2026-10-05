// Localization contract for user-facing errors (C8/D1 follow-up).
//
// Two rules on the arb files under lib/l10n:
//   R1  No arb file defines the same key twice. jsonDecode keeps the last
//       value silently, so a duplicate replaces the earlier copy without any
//       generator warning.
//   R2  Every key with a text placeholder (String/Object) is listed below
//       with the reason its argument is user-meaningful. A placeholder is the
//       one path raw diagnostics can take past raw_error_text_test.dart
//       (`l10n.someKey(error.message)` names no error variable), so a new
//       `{error}`-style key must fail here and be redesigned: localized copy
//       up front, the original behind ErrorDetails or in CrashLog.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _arbFiles = [
  'lib/l10n/app_zh.arb',
  'lib/l10n/app_en.arb',
  'lib/l10n/app_ja.arb',
  'lib/l10n/app_ru.arb',
];

/// The template arb (l10n.yaml `template-arb-file`) declares the
/// placeholder types for every locale.
const _templateArb = 'lib/l10n/app_zh.arb';

/// Keys whose text placeholders are allowed, with the reason the argument
/// never carries diagnostic text.
const _textPlaceholderKeys = <String, String>{
  // The HTTP status code of a main-document response plus its host — a
  // status, not an exception (design §2.4 class 5 precedent).
  'loginNetworkError': 'HTTP status and host',
  'backupExported': 'exported file name',
  'muteEmptyHint': 'card menu label of the mute action',
  'backupImportPrompt': 'account name stored in the backup',
  'imageSourceTestOk': 'HTTP status of a successful probe',
  'imageSourceAutoWinner': 'selected mirror host',
  'safStorageSdCard': 'storage volume label',
  'namingTemplateHint': 'naming-template variable tokens',
  'downloadGroupAuthorTitle': 'author name',
  // `reason` is always errorCategoryText output (showErrorSnackBar).
  'errorWithReason': 'localized action and category',
  'rankingLoadFailed': 'localized ranking mode label',
  'searchReverseChallenge': 'search engine name',
  'detailMetaSemantics': 'formatted date and compact counts',
  'detailMetaCountsSemantics': 'compact counts (AppFormat.count)',
  'localNovelsImported': 'novel title',
  'localNovelsDeleteConfirm': 'novel title',
  'localNovelFileEncoding': 'detected charset name',
  'localNovelFileImportedAt': 'formatted date',
  'profileFollowingCount': 'compact count (AppFormat.count)',
  'profileMyPixivCount': 'compact count (AppFormat.count)',
  'profileTagFilter': 'bookmark tag name',
  'searchRangeAtLeast': 'filter label and formatted bound',
  'searchRangeAtMost': 'filter label and formatted bound',
  'searchRangeBetween': 'filter label and formatted bounds',
  'searchDateFrom': 'formatted date',
  'searchDateUntil': 'formatted date',
  'searchDateBetween': 'formatted dates',
  'rankingDateLabel': 'formatted date',
};

const _textTypes = {'String', 'Object'};

/// Top-level keys of an arb file in declaration order. Arb files are flat
/// JSON objects formatted one entry per line, so top-level keys are the
/// lines indented by exactly two spaces.
final _topLevelKey = RegExp(r'^  "([^"]+)"\s*:', multiLine: true);

void main() {
  test('arb files define every key once', () {
    final duplicates = <String>[];
    for (final path in _arbFiles) {
      final seen = <String>{};
      for (final match in _topLevelKey.allMatches(
        File(path).readAsStringSync(),
      )) {
        final key = match[1]!;
        if (!seen.add(key)) duplicates.add('$path: $key');
      }
    }
    expect(
      duplicates,
      isEmpty,
      reason:
          'duplicate arb keys — the last copy silently wins:\n'
          '${duplicates.join('\n')}',
    );
  });

  test('text placeholders are allow-listed with a reason', () {
    final arb =
        jsonDecode(File(_templateArb).readAsStringSync())
            as Map<String, dynamic>;
    final textKeys = <String>{};
    for (final entry in arb.entries) {
      if (!entry.key.startsWith('@')) continue;
      final meta = entry.value;
      if (meta is! Map<String, dynamic>) continue;
      final placeholders = meta['placeholders'];
      if (placeholders is! Map<String, dynamic>) continue;
      final hasText = placeholders.values.any(
        (spec) =>
            spec is! Map<String, dynamic> ||
            _textTypes.contains(spec['type'] ?? 'Object'),
      );
      if (hasText) textKeys.add(entry.key.substring(1));
    }

    final unlisted = textKeys.difference(_textPlaceholderKeys.keys.toSet());
    final stale = _textPlaceholderKeys.keys.toSet().difference(textKeys);
    expect(
      unlisted,
      isEmpty,
      reason:
          'keys with a text placeholder must not carry diagnostics — drop '
          'the placeholder (raw text goes behind ErrorDetails or into '
          'CrashLog) or allow-list the key with its reason:\n'
          '${unlisted.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason: 'allow-list entries without a text placeholder: $stale',
    );
  });
}
