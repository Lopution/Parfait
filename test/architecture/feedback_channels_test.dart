// Single-owner guards for the feedback channels, overlay entries, motion
// durations and the hero tag family (W10 contract C1).
//
// Asserted on the source tree (all paths repo-relative):
//   - bare `SnackBar(` / `showSnackBar(` callsites outside
//     lib/app/widgets/app_snack_bar.dart: zero — callers go through
//     showAppSnackBar / showAppSnackBarOn (the latter's callsites are
//     pinned below)
//   - `HapticFeedback.` callsites outside lib/app/haptics/: zero —
//     AppHaptics and its platform driver are the only owners
//   - raw selection controls (SegmentedButton, ChoiceChip/FilterChip,
//     Slider, Switch/SwitchListTile, Radio) only inside the wrapper that
//     builds their haptic in
//   - navigation chrome (tab bar, bottom nav, root swipe) plays no haptic:
//     switching destinations is navigation, not a state change
//   - `Clipboard.setData` inside lib/app + lib/features: only in
//     lib/app/clipboard.dart (copyToClipboard: write, success haptic, toast)
//   - raw overlay entries (showDialog / showModalBottomSheet / Cupertino
//     variants / showMenu / framework pickers) outside
//     lib/app/motion/app_overlays.dart: zero beyond the pinned
//     framework-picker allow-list
//   - `SystemChrome.` callsites and `SystemUiOverlayStyle(` /
//     `AnnotatedRegion<SystemUiOverlayStyle>` outside
//     lib/app/system_ui.dart: zero — FuncSystemBars, funcSystemBarsStyle
//     and setSystemUiMode are the only way to touch system UI
//   - `Hero(` callsites: exactly the members of the illustHeroTag family —
//     no second tag family may appear
//   - `Duration(milliseconds:` inside lib/app/ + lib/features/: only in
//     motion_tokens.dart plus the pinned non-motion census (per-file counts
//     are asserted so additions get flagged for review)
//   - no merge-conflict markers (`<<<<<<<` / `>>>>>>>`) in lib/, test/ or
//     .trellis/spec/ — `git diff --check` does not catch markers in files
//     that were committed with them

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner file for the SnackBar channel.
const _snackBarOwner = 'lib/app/widgets/app_snack_bar.dart';

/// Owner directory for haptic feedback (AppHaptics + its platform driver).
const _hapticsOwnerDir = 'lib/app/haptics/';

/// Raw selection control → the wrapper files allowed to build it. The
/// wrappers own the control's haptic, so a raw control elsewhere would be
/// a silent one.
final _selectionControlOwners = <RegExp, Set<String>>{
  RegExp(r'(?<![A-Za-z])SegmentedButton<'): {
    'lib/app/widgets/app_segmented_button.dart',
  },
  RegExp(r'(?<![A-Za-z])(?:ChoiceChip|FilterChip)\('): {
    'lib/app/widgets/app_choice_chip.dart',
  },
  RegExp(r'(?<![A-Za-z])Slider(?:\.adaptive)?\('): {
    'lib/app/widgets/app_slider.dart',
  },
  RegExp(r'(?<![A-Za-z])(?:Switch|SwitchListTile)(?:\.adaptive)?\('): {
    'lib/app/widgets/settings/settings_control.dart',
    'lib/app/widgets/replica_switch_tile.dart',
  },
  RegExp(r'(?<![A-Za-z])(?:RadioListTile|Radio)\s*[<(]'): {
    'lib/app/widgets/settings/settings_choice_tile.dart',
  },
};

/// Navigation chrome: switching is navigation, not a state change, so these
/// stay silent (Compose Material 3, Flutter Material and Now in Android do
/// not vibrate on tab or destination switches either).
const _silentNavigationFiles = <String>{
  'lib/app/widgets/app_tab_bar.dart',
  'lib/app/widgets/func_bottom_nav.dart',
  'lib/app/widgets/root_swipe_switcher.dart',
};

/// Owner file for UI clipboard writes. core/ keeps its own platform uses
/// (share fallback, desktop transfer clipboard), which have no UI.
const _clipboardOwner = 'lib/app/clipboard.dart';

/// Owner file for app modal overlays.
const _overlaysOwner = 'lib/app/motion/app_overlays.dart';

/// Owner file for system bar styling: pages reach for FuncSystemBars /
/// funcSystemBarsStyle, never a raw overlay-style widget or constructor.
const _systemUiOwner = 'lib/app/system_ui.dart';

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
  'lib/app/motion/motion_tokens.dart': 19,
  'lib/app/haptics/app_haptics.dart': 3,
  'lib/app/widgets/smooth_wheel_scroll.dart': 2,
  // Show delay of the image progress ring: a debounce, not an animation.
  'lib/app/widgets/image_load_progress.dart': 1,
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

  test('haptics have exactly one owner', () {
    final files = _matches(
      ['lib'],
      RegExp(r"HapticFeedback\.|MethodChannel\('parfait/haptics'\)"),
    ).keys.where((f) => !f.startsWith(_hapticsOwnerDir));
    expect(
      files,
      isEmpty,
      reason:
          'raw haptics outside $_hapticsOwnerDir — '
          'use an AppHaptics role',
    );
  });

  test('selection controls live only in their haptic wrappers', () {
    final violations = <String>[];
    _selectionControlOwners.forEach((pattern, owners) {
      final files = _matches(['lib'], pattern).keys.toSet();
      for (final file in files.difference(owners)) {
        violations.add('$file: ${pattern.pattern}');
      }
    });
    expect(
      violations,
      isEmpty,
      reason:
          'raw selection controls outside their wrappers (use '
          'AppSegmentedButton / AppChoiceChip / AppSlider / SettingsControl / '
          'SettingsChoiceTile):\n${violations.join('\n')}',
    );
  });

  test('navigation chrome stays silent', () {
    final noisy = [
      for (final file in _silentNavigationFiles)
        if (File(file).readAsStringSync().contains('AppHaptics')) file,
    ];
    expect(noisy, isEmpty, reason: 'navigation must not play haptics');
  });

  test('UI clipboard writes go through copyToClipboard', () {
    final files = _matches([
      'lib/app',
      'lib/features',
    ], RegExp(r'Clipboard\.setData')).keys.toSet();
    expect(
      files.difference({_clipboardOwner}),
      isEmpty,
      reason:
          'Clipboard.setData outside $_clipboardOwner — use copyToClipboard',
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

  test('system UI has exactly one owner', () {
    final hits = _matches(
      ['lib'],
      RegExp(
        r'SystemChrome\.|SystemUiOverlayStyle\(|'
        r'AnnotatedRegion\s*<SystemUiOverlayStyle>',
      ),
    );
    expect(
      hits.keys.toSet().difference({_systemUiOwner}),
      isEmpty,
      reason:
          'raw system UI calls outside $_systemUiOwner: '
          '${hits.keys.toSet().difference({_systemUiOwner}).join(', ')} — '
          'use funcSystemBarsStyle / FuncSystemBars / setSystemUiMode',
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

  test('no merge-conflict markers in lib/, test/ or .trellis/spec/', () {
    final marker = RegExp(r'^(<{7}|>{7})', multiLine: true);
    final violations = <String>[];
    for (final root in ['lib', 'test', '.trellis/spec']) {
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
