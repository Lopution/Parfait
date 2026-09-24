// Single-owner guards for the feedback channels, overlay entries, motion
// durations and the hero tag family (W10 contract C1).
//
// Asserted on the source tree (all paths repo-relative):
//   - bare `SnackBar(` / `showSnackBar(` callsites outside
//     lib/app/widgets/app_snack_bar.dart: zero — callers go through
//     showAppSnackBar / showAppSnackBarOn (the latter's callsites are
//     pinned below)
//   - `HapticFeedback.` callsites outside lib/app/haptics/app_haptics.dart:
//     zero — AppHaptics is the only owner
//   - raw overlay entries (showDialog / showModalBottomSheet / Cupertino
//     variants / showMenu / framework pickers) outside
//     lib/app/motion/app_overlays.dart: zero beyond the pinned
//     framework-picker allow-list
//   - `Hero(` callsites: exactly the members of the illustHeroTag family —
//     no second tag family may appear
//   - `Duration(milliseconds:` inside lib/app/ + lib/features/: only in
//     motion_tokens.dart plus the pinned non-motion census (per-file counts
//     are asserted so additions get flagged for review)
//   - no merge-conflict markers (`<<<<<<<` / `>>>>>>>`) in lib/, test/ or
//     .trellis/ — a stray marker once escaped `git diff --check` on
//     .trellis/workspace index files

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner file for the SnackBar channel.
const _snackBarOwner = 'lib/app/widgets/app_snack_bar.dart';

/// Owner file for haptic feedback.
const _hapticsOwner = 'lib/app/haptics/app_haptics.dart';

/// Owner file for app modal overlays.
const _overlaysOwner = 'lib/app/motion/app_overlays.dart';

/// Approved `showAppSnackBarOn` callsites: the root-level presentations that
/// cannot reach a scoped messenger context (root exit hint, app-level update
/// notice). Everything else must use `showAppSnackBar(context, ...)`.
const _snackBarOnCallSites = <String>{
  'lib/app/app.dart',
  'lib/features/home/home_page.dart',
};

/// Raw overlay entries that are intentional framework pickers, not app
/// overlay surfaces — the app overlay contract (MotionTokens.sheet/dialog +
/// reduced-motion gate) does not restyle them.
const _overlayAllowList = <String, Set<String>>{
  'lib/features/settings/pages/about_settings_page.dart': {'showLicensePage'},
  'lib/features/search/search_filter_sheet.dart': {'showDatePicker'},
};

/// Files allowed to contain `Hero(` — the members of the shared
/// `illustHeroTag(scope, id)` tag family. A new file here means a second
/// hero tag family: extend the shared family instead.
const _heroFiles = <String>{
  'lib/app/widgets/feed/illust_card.dart',
  'lib/features/illust/detail/widgets/page_image.dart',
  'lib/features/illust/detail/ugoira_viewer.dart',
  'lib/features/illust/viewer/image_viewer_page.dart',
};

/// Census of `Duration(milliseconds:` inside the UI layers. Every entry is
/// either the canonical token file or a pinned non-motion use (haptic
/// throttle, wheel floor clamp, ugoira frame delay, debug probe poll).
/// Counts are pinned so a new hard-coded animation duration fails here.
const _durationCensus = <String, int>{
  'lib/app/motion/motion_tokens.dart': 18,
  'lib/app/haptics/app_haptics.dart': 3,
  'lib/app/widgets/smooth_wheel_scroll.dart': 2,
  'lib/features/illust/detail/ugoira_viewer.dart': 1,
  'lib/features/settings/pages/frame_probe_page.dart': 1,
};

/// Recursively yields `.dart` files under [dir] as repo-relative paths.
Iterable<String> _dartFiles(String dir) sync* {
  for (final entity in Directory(dir).listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity.path;
    }
  }
}

/// Maps file → matched symbols for [pattern] across [roots].
Map<String, Set<String>> _matches(List<String> roots, RegExp pattern) {
  final hits = <String, Set<String>>{};
  for (final root in roots) {
    for (final file in _dartFiles(root)) {
      final src = File(file).readAsStringSync();
      for (final match in pattern.allMatches(src)) {
        hits
            .putIfAbsent(file, () => {})
            .add(match.groupCount >= 1 ? match.group(1)! : match.group(0)!);
      }
    }
  }
  return hits;
}

void main() {
  test('SnackBar presentation has exactly one owner', () {
    final bareCtor = _matches([
      'lib',
    ], RegExp(r'(?<![A-Za-z])SnackBar\(')).keys.toSet();
    expect(
      bareCtor.difference({_snackBarOwner}),
      isEmpty,
      reason:
          'bare SnackBar( outside $_snackBarOwner: '
          '${bareCtor.difference({_snackBarOwner}).join(', ')}',
    );

    final rawShow = _matches([
      'lib',
    ], RegExp(r'(?<![A-Za-z])showSnackBar\(')).keys.toSet();
    expect(
      rawShow.difference({_snackBarOwner}),
      isEmpty,
      reason: 'showSnackBar( outside $_snackBarOwner',
    );

    // showAppSnackBarOn exists for presentations whose context sits above
    // the branch-scoped messenger; its callsites stay pinned.
    final onCallSites = _matches([
      'lib',
    ], RegExp(r'showAppSnackBarOn\(')).keys.toSet();
    expect(
      onCallSites.difference({..._snackBarOnCallSites, _snackBarOwner}),
      isEmpty,
      reason:
          'unapproved showAppSnackBarOn callsite — '
          'prefer showAppSnackBar(context, ...)',
    );
  });

  test('HapticFeedback has exactly one owner', () {
    final files = _matches(['lib'], RegExp(r'HapticFeedback\.')).keys.toSet();
    expect(
      files.difference({_hapticsOwner}),
      isEmpty,
      reason:
          'raw HapticFeedback. outside $_hapticsOwner — '
          'use AppHaptics select/confirm/success/error roles',
    );
  });

  test('app modal overlays funnel through app_overlays.dart', () {
    final hits = _matches(
      ['lib'],
      RegExp(
        '(?<![A-Za-z])'
        '(showDialog|showModalBottomSheet|showCupertinoDialog|'
        'showCupertinoModalPopup|showGeneralDialog|showMenu|'
        'showLicensePage|showDatePicker|showTimePicker|showSearch)'
        r'\s*[<(]',
      ),
    );
    final violations = <String>[];
    hits.forEach((file, symbols) {
      if (file == _overlaysOwner) return;
      final allowed = _overlayAllowList[file] ?? const <String>{};
      final extra = symbols.difference(allowed);
      if (extra.isNotEmpty) violations.add('$file: ${extra.join(', ')}');
    });
    expect(
      violations,
      isEmpty,
      reason:
          'raw overlay entries outside $_overlaysOwner:\n'
          '${violations.join('\n')}',
    );
  });

  test('Hero uses only the shared illustHeroTag family', () {
    final files = _matches([
      'lib',
    ], RegExp(r'(?<![A-Za-z])Hero\(')).keys.toSet();
    expect(
      files,
      _heroFiles,
      reason: 'Hero callsites must stay in the shared illustHeroTag family',
    );
  });

  test('motion durations live only in MotionTokens (pinned census)', () {
    final counts = <String, int>{};
    for (final root in ['lib/app', 'lib/features']) {
      for (final file in _dartFiles(root)) {
        final src = File(file).readAsStringSync();
        final n = RegExp(r'Duration\(milliseconds').allMatches(src).length;
        if (n > 0) counts[file] = n;
      }
    }
    expect(
      counts,
      _durationCensus,
      reason:
          'hard-coded ms durations outside the census — route animation '
          'durations through MotionTokens or pin the non-motion use here',
    );
  });

  test('no merge-conflict markers in lib/, test/ or .trellis/', () {
    final marker = RegExp(r'^(<{7}|>{7})', multiLine: true);
    final violations = <String>[];
    for (final root in ['lib', 'test', '.trellis']) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart') && !entity.path.endsWith('.md')) {
          continue;
        }
        if (marker.hasMatch(entity.readAsStringSync())) {
          violations.add(entity.path);
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
